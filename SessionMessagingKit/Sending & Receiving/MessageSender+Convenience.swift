// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import PromiseKit
import SessionUtilitiesKit

extension MessageSender {
    
    // MARK: - Durable
    
    public static func send(_ db: Database, interaction: Interaction, with attachments: [SignalAttachment], in thread: SessionThread) throws {
        guard let interactionId: Int64 = interaction.id else { throw GRDBStorageError.objectNotSaved }
        
        try prep(db, signalAttachments: attachments, for: interactionId)
        send(
            db,
            message: VisibleMessage.from(db, interaction: interaction),
            threadId: thread.id,
            interactionId: interactionId,
            to: try Message.Destination.from(db, thread: thread)
        )
    }
    
    public static func send(_ db: Database, interaction: Interaction, in thread: SessionThread) throws {
        // Only 'VisibleMessage' types can be sent via this method
        guard interaction.variant == .standardOutgoing else { throw MessageSenderError.invalidMessage }
        guard let interactionId: Int64 = interaction.id else { throw GRDBStorageError.objectNotSaved }
        
        send(
            db,
            message: VisibleMessage.from(db, interaction: interaction),
            threadId: thread.id,
            interactionId: interactionId,
            to: try Message.Destination.from(db, thread: thread)
        )
    }
    
    public static func send(_ db: Database, message: Message, interactionId: Int64?, in thread: SessionThread) throws {
        send(
            db,
            message: message,
            threadId: thread.id,
            interactionId: interactionId,
            to: try Message.Destination.from(db, thread: thread)
        )
    }
    
    public static func send(_ db: Database, message: Message, threadId: String?, interactionId: Int64?, to destination: Message.Destination) {
        JobRunner.add(
            db,
            job: Job(
                variant: .messageSend,
                threadId: threadId,
                interactionId: interactionId,
                details: MessageSendJob.Details(
                    destination: destination,
                    message: message
                )
            )
        )
    }

    // MARK: - Non-Durable
    
    public static func sendNonDurably(_ db: Database, interaction: Interaction, with attachments: [SignalAttachment], in thread: SessionThread) throws -> Promise<Void> {
        guard let interactionId: Int64 = interaction.id else { return Promise(error: GRDBStorageError.objectNotSaved) }
        
        try prep(db, signalAttachments: attachments, for: interactionId)
        
        return sendNonDurably(
            db,
            message: VisibleMessage.from(db, interaction: interaction),
            interactionId: interactionId,
            to: try Message.Destination.from(db, thread: thread)
        )
    }
    
    
    public static func sendNonDurably(_ db: Database, interaction: Interaction, in thread: SessionThread) throws -> Promise<Void> {
        // Only 'VisibleMessage' types can be sent via this method
        guard interaction.variant == .standardOutgoing else { throw MessageSenderError.invalidMessage }
        guard let interactionId: Int64 = interaction.id else { throw GRDBStorageError.objectNotSaved }
        
        return sendNonDurably(
            db,
            message: VisibleMessage.from(db, interaction: interaction),
            interactionId: interactionId,
            to: try Message.Destination.from(db, thread: thread)
        )
    }
    
    public static func sendNonDurably(_ db: Database, message: Message, interactionId: Int64?, in thread: SessionThread) throws -> Promise<Void> {
        return sendNonDurably(
            db,
            message: message,
            interactionId: interactionId,
            to: try Message.Destination.from(db, thread: thread)
        )
    }
    
    public static func sendNonDurably(_ db: Database, message: Message, interactionId: Int64?, to destination: Message.Destination) -> Promise<Void> {
        var attachmentUploadPromises: [Promise<Void>] = [Promise.value(())]
        
        // If we have an interactionId then check if it has any attachments and process them first
        if let interactionId: Int64 = interactionId {
            let threadId: String = {
                switch destination {
                    case .contact(let publicKey): return publicKey
                    case .closedGroup(let groupPublicKey): return groupPublicKey
                    case .openGroupV2(let room, let server):
                        return OpenGroup.idFor(room: room, server: server)
                    
                    case .openGroup: return ""
                }
            }()
            let openGroup: OpenGroup? = try? OpenGroup.fetchOne(db, id: threadId)
            let attachmentStateInfo: [Attachment.StateInfo] = (try? Attachment
                .stateInfo(interactionId: interactionId, state: .uploading)
                .fetchAll(db))
                .defaulting(to: [])
            
            attachmentUploadPromises = (try? Attachment
                .filter(ids: attachmentStateInfo.map { $0.attachmentId })
                .fetchAll(db))
                .defaulting(to: [])
                .map { attachment -> Promise<Void> in
                    let (promise, seal) = Promise<Void>.pending()
    
                    attachment.upload(
                        db,
                        using: { data in
                            if let openGroup: OpenGroup = openGroup {
                                return OpenGroupAPIV2.upload(data, to: openGroup.room, on: openGroup.server)
                            }
    
                            return FileServerAPIV2.upload(data)
                        },
                        encrypt: (openGroup == nil),
                        success: { seal.fulfill(()) },
                        failure: { seal.reject($0) }
                    )
    
                    return promise
                }
        }

        // Once the attachments are processed then send the message
        return when(resolved: attachmentUploadPromises)
            .then { results -> Promise<Void> in
                let errors: [Error] = results
                    .compactMap { result -> Error? in
                        if case .rejected(let error) = result { return error }

                        return nil
                    }

                if let error: Error = errors.first { return Promise(error: error) }
                
                return GRDBStorage.shared.write { db in
                    try MessageSender.sendImmediate(
                        db,
                        message: message,
                        to: destination,
                        interactionId: interactionId
                    )
                }
            }
    }
    
    /// This method requires the `db` value to be passed in because if it's called within a `writeAsync` completion block
    /// it will throw a "re-entrant" fatal error when attempting to write again
    public static func syncConfiguration(_ db: Database, forceSyncNow: Bool = true) throws -> Promise<Void> {
        // If we don't have a userKeyPair yet then there is no need to sync the configuration
        // as the user doesn't exist yet (this will get triggered on the first launch of a
        // fresh install due to the migrations getting run)
        guard Identity.userExists(db) else {
            return Promise(error: GRDBStorageError.generic)
        }
        
        let destination: Message.Destination = Message.Destination.contact(
            publicKey: getUserHexEncodedPublicKey(db)
        )
        let configurationMessage = try ConfigurationMessage.getCurrent(db)
        let (promise, seal) = Promise<Void>.pending()
        
        if forceSyncNow {
            try MessageSender
                .sendImmediate(db, message: configurationMessage, to: destination, interactionId: nil)
                .done { seal.fulfill(()) }
                .catch { _ in seal.reject(GRDBStorageError.generic) }
                .retainUntilComplete()
        }
        else {
            JobRunner.add(
                db,
                job: Job(
                    variant: .messageSend,
                    details: MessageSendJob.Details(
                        destination: destination,
                        message: configurationMessage
                    )
                )
            )
            seal.fulfill(())
        }
        
        return promise
    }
}