// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit
import Sodium

public final class MessageSender {
    // MARK: - Message Preparation
    
    public struct PreparedSendData {
        let shouldSend: Bool
        let destination: Message.Destination
        let namespace: SnodeAPI.Namespace?
        
        let message: Message?
        let interactionId: Int64?
        let isSyncMessage: Bool?
        let totalAttachmentsUploaded: Int
        
        let snodeMessage: SnodeMessage?
        let plaintext: Data?
        let ciphertext: Data?
        
        private init(
            shouldSend: Bool,
            message: Message?,
            destination: Message.Destination,
            namespace: SnodeAPI.Namespace?,
            interactionId: Int64?,
            isSyncMessage: Bool?,
            totalAttachmentsUploaded: Int = 0,
            snodeMessage: SnodeMessage?,
            plaintext: Data?,
            ciphertext: Data?
        ) {
            self.shouldSend = shouldSend
            
            self.message = message
            self.destination = destination
            self.namespace = namespace
            self.interactionId = interactionId
            self.isSyncMessage = isSyncMessage
            self.totalAttachmentsUploaded = totalAttachmentsUploaded
            
            self.snodeMessage = snodeMessage
            self.plaintext = plaintext
            self.ciphertext = ciphertext
        }
        
        /// This should be used to send a message to one-to-one or closed group conversations
        fileprivate init(
            message: Message,
            destination: Message.Destination,
            namespace: SnodeAPI.Namespace,
            interactionId: Int64?,
            isSyncMessage: Bool?,
            snodeMessage: SnodeMessage
        ) {
            self.shouldSend = true
            
            self.message = message
            self.destination = destination
            self.namespace = namespace
            self.interactionId = interactionId
            self.isSyncMessage = isSyncMessage
            self.totalAttachmentsUploaded = 0
            
            self.snodeMessage = snodeMessage
            self.plaintext = nil
            self.ciphertext = nil
        }
        
        /// This should be used to send a message to open group conversations
        fileprivate init(
            message: Message,
            destination: Message.Destination,
            interactionId: Int64?,
            plaintext: Data
        ) {
            self.shouldSend = true
            
            self.message = message
            self.destination = destination
            self.namespace = nil
            self.interactionId = interactionId
            self.isSyncMessage = false
            self.totalAttachmentsUploaded = 0
            
            self.snodeMessage = nil
            self.plaintext = plaintext
            self.ciphertext = nil
        }
        
        /// This should be used to send a message to an open group inbox
        fileprivate init(
            message: Message,
            destination: Message.Destination,
            interactionId: Int64?,
            ciphertext: Data
        ) {
            self.shouldSend = true
            
            self.message = message
            self.destination = destination
            self.namespace = nil
            self.interactionId = interactionId
            self.isSyncMessage = false
            self.totalAttachmentsUploaded = 0
            
            self.snodeMessage = nil
            self.plaintext = nil
            self.ciphertext = ciphertext
        }
        
        // MARK: - Mutation
        
        internal func with(fileIds: [String]) -> PreparedSendData {
            return PreparedSendData(
                shouldSend: shouldSend,
                message: message,
                destination: destination.with(fileIds: fileIds),
                namespace: namespace,
                interactionId: interactionId,
                isSyncMessage: isSyncMessage,
                totalAttachmentsUploaded: fileIds.count,
                snodeMessage: snodeMessage,
                plaintext: plaintext,
                ciphertext: ciphertext
            )
        }
    }
    
    public static func preparedSendData(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        namespace: SnodeAPI.Namespace?,
        interactionId: Int64?,
        isSyncMessage: Bool = false,
        using dependencies: Dependencies = Dependencies()
    ) throws -> PreparedSendData {
        // Common logic for all destinations
        let currentUserPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
        let messageSendTimestamp: Int64 = SnodeAPI.currentOffsetTimestampMs()
        let updatedMessage: Message = message
        
        // Set the message 'sentTimestamp' (Visible messages will already have their sent timestamp set)
        updatedMessage.sentTimestamp = (
            updatedMessage.sentTimestamp ??
            UInt64(messageSendTimestamp)
        )
        
        switch destination {
            case .contact, .closedGroup:
                return try prepareSendToSnodeDestination(
                    db,
                    message: updatedMessage,
                    to: destination,
                    namespace: namespace,
                    interactionId: interactionId,
                    userPublicKey: currentUserPublicKey,
                    messageSendTimestamp: messageSendTimestamp,
                    isSyncMessage: isSyncMessage,
                    using: dependencies
                )

            case .openGroup:
                return try prepareSendToOpenGroupDestination(
                    db,
                    message: updatedMessage,
                    to: destination,
                    interactionId: interactionId,
                    messageSendTimestamp: messageSendTimestamp,
                    using: dependencies
                )
                
            case .openGroupInbox:
                return try prepareSendToOpenGroupInboxDestination(
                    db,
                    message: message,
                    to: destination,
                    interactionId: interactionId,
                    userPublicKey: currentUserPublicKey,
                    messageSendTimestamp: messageSendTimestamp,
                    using: dependencies
                )
        }
    }
    
    internal static func prepareSendToSnodeDestination(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        namespace: SnodeAPI.Namespace?,
        interactionId: Int64?,
        userPublicKey: String,
        messageSendTimestamp: Int64,
        isSyncMessage: Bool = false,
        using dependencies: Dependencies
    ) throws -> PreparedSendData {
        message.sender = userPublicKey
        message.recipient = {
            switch destination {
                case .contact(let publicKey): return publicKey
                case .closedGroup(let groupPublicKey): return groupPublicKey
                case .openGroup, .openGroupInbox: preconditionFailure()
            }
        }()
        
        // Validate the message
        guard message.isValid, let namespace: SnodeAPI.Namespace = namespace else {
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .invalidMessage,
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Attach the user's profile if needed (no need to do so for 'Note to Self' or sync
        // messages as they will be managed by the user config handling
        let isSelfSend: Bool = (message.recipient == userPublicKey)

        if !isSelfSend, !isSyncMessage, var messageWithProfile: MessageWithProfile = message as? MessageWithProfile {
            let profile: Profile = Profile.fetchOrCreateCurrentUser(db)
            
            if let profileKey: Data = profile.profileEncryptionKey, let profilePictureUrl: String = profile.profilePictureUrl {
                messageWithProfile.profile = VisibleMessage.VMProfile(
                    displayName: profile.name,
                    profileKey: profileKey,
                    profilePictureUrl: profilePictureUrl
                )
            }
            else {
                messageWithProfile.profile = VisibleMessage.VMProfile(displayName: profile.name)
            }
        }
        
        // Perform any pre-send actions
        handleMessageWillSend(db, message: message, interactionId: interactionId, isSyncMessage: isSyncMessage)
        
        // Convert it to protobuf
        let threadId: String = Message.threadId(forMessage: message, destination: destination)
        
        guard let proto = message.toProto(db, threadId: threadId) else {
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .protoConversionFailed,
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Serialize the protobuf
        let plaintext: Data
        
        do {
            plaintext = try proto.serializedData().paddedMessageBody()
        }
        catch {
            SNLog("Couldn't serialize proto due to error: \(error).")
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .other(error),
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Encrypt the serialized protobuf
        let ciphertext: Data
        do {
            switch destination {
                case .contact(let publicKey):
                    ciphertext = try encryptWithSessionProtocol(db, plaintext: plaintext, for: publicKey, using: dependencies)
                    
                case .closedGroup(let groupPublicKey):
                    guard let encryptionKeyPair: ClosedGroupKeyPair = try? ClosedGroupKeyPair.fetchLatestKeyPair(db, threadId: groupPublicKey) else {
                        throw MessageSenderError.noKeyPair
                    }
                    
                    ciphertext = try encryptWithSessionProtocol(
                        db,
                        plaintext: plaintext,
                        for: SessionId(.standard, publicKey: encryptionKeyPair.publicKey.bytes).hexString,
                        using: dependencies
                    )
                    
                case .openGroup, .openGroupInbox: preconditionFailure()
            }
        }
        catch {
            SNLog("Couldn't encrypt message for destination: \(destination) due to error: \(error).")
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .other(error),
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Wrap the result
        let kind: SNProtoEnvelope.SNProtoEnvelopeType
        let senderPublicKey: String
        
        switch destination {
            case .contact:
                kind = .sessionMessage
                senderPublicKey = ""
                
            case .closedGroup(let groupPublicKey):
                kind = .closedGroupMessage
                senderPublicKey = groupPublicKey
            
            case .openGroup, .openGroupInbox: preconditionFailure()
        }
        
        let wrappedMessage: Data
        do {
            wrappedMessage = try MessageWrapper.wrap(
                type: kind,
                timestamp: message.sentTimestamp!,
                senderPublicKey: senderPublicKey,
                base64EncodedContent: ciphertext.base64EncodedString()
            )
        }
        catch {
            SNLog("Couldn't wrap message due to error: \(error).")
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .other(error),
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Send the result
        let base64EncodedData = wrappedMessage.base64EncodedString()
        
        let snodeMessage = SnodeMessage(
            recipient: message.recipient!,
            data: base64EncodedData,
            ttl: Message.getSpecifiedTTL(
                message: message,
                isGroupMessage: {
                    switch destination {
                        case .closedGroup: return true
                        default: return false
                    }
                }(),
                isSyncMessage: isSyncMessage
            ),
            timestampMs: UInt64(messageSendTimestamp)
        )
        
        return PreparedSendData(
            message: message,
            destination: destination,
            namespace: namespace,
            interactionId: interactionId,
            isSyncMessage: isSyncMessage,
            snodeMessage: snodeMessage
        )
    }
    
    internal static func prepareSendToOpenGroupDestination(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        messageSendTimestamp: Int64,
        using dependencies: Dependencies
    ) throws -> PreparedSendData {
        let threadId: String
        
        switch destination {
            case .contact, .closedGroup, .openGroupInbox: preconditionFailure()
            case .openGroup(let roomToken, let server, let whisperTo, let whisperMods, _):
                threadId = OpenGroup.idFor(roomToken: roomToken, server: server)
                message.recipient = [
                    server,
                    roomToken,
                    whisperTo,
                    (whisperMods ? "mods" : nil)
                ]
                .compactMap { $0 }
                .joined(separator: ".")
        }
        
        // Note: It's possible to send a message and then delete the open group you sent the message to
        // which would go into this case, so rather than handling it as an invalid state we just want to
        // error in a non-retryable way
        guard
            let openGroup: OpenGroup = try? OpenGroup.fetchOne(db, id: threadId),
            let userEdKeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db),
            case .openGroup(_, let server, _, _, _) = destination
        else {
            throw MessageSenderError.invalidMessage
        }
        
        message.sender = try {
            let capabilities: [Capability.Variant] = (try? Capability
                .select(.variant)
                .filter(Capability.Columns.openGroupServer == server)
                .filter(Capability.Columns.isMissing == false)
                .asRequest(of: Capability.Variant.self)
                .fetchAll(db))
                .defaulting(to: [])
            
            // If the server doesn't support blinding then go with an unblinded id
            guard capabilities.isEmpty || capabilities.contains(.blind) else {
                return SessionId(.unblinded, publicKey: userEdKeyPair.publicKey).hexString
            }
            guard
                let blindedKeyPair: KeyPair = dependencies.crypto.generate(
                    .blindedKeyPair(serverPublicKey: openGroup.publicKey, edKeyPair: userEdKeyPair, using: dependencies)
                )
            else { throw MessageSenderError.signingFailed }
            
            return SessionId(.blinded15, publicKey: blindedKeyPair.publicKey).hexString
        }()
        
        // Validate the message
        guard
            let message = message as? VisibleMessage,
            message.isValid
        else {
            #if DEBUG
            if (message as? VisibleMessage) == nil { preconditionFailure() }
            #endif
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .invalidMessage,
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Attach the user's profile
        message.profile = VisibleMessage.VMProfile(
            profile: Profile.fetchOrCreateCurrentUser(db),
            blocksCommunityMessageRequests: !db[.checkForCommunityMessageRequests]
        )

        if (message.profile?.displayName ?? "").isEmpty {
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .noUsername,
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Perform any pre-send actions
        handleMessageWillSend(db, message: message, interactionId: interactionId)
        
        // Convert it to protobuf
        guard let proto = message.toProto(db, threadId: threadId) else {
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .protoConversionFailed,
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Serialize the protobuf
        let plaintext: Data
        
        do {
            plaintext = try proto.serializedData().paddedMessageBody()
        }
        catch {
            SNLog("Couldn't serialize proto due to error: \(error).")
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .other(error),
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        return PreparedSendData(
            message: message,
            destination: destination,
            interactionId: interactionId,
            plaintext: plaintext
        )
    }
    
    internal static func prepareSendToOpenGroupInboxDestination(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        userPublicKey: String,
        messageSendTimestamp: Int64,
        using dependencies: Dependencies
    ) throws -> PreparedSendData {
        guard case .openGroupInbox(_, let openGroupPublicKey, let recipientBlindedPublicKey) = destination else {
            throw MessageSenderError.invalidMessage
        }
        
        message.sender = userPublicKey
        message.recipient = recipientBlindedPublicKey
        
        // Attach the user's profile if needed
        if let message: VisibleMessage = message as? VisibleMessage {
            let profile: Profile = Profile.fetchOrCreateCurrentUser(db)
            
            if let profileKey: Data = profile.profileEncryptionKey, let profilePictureUrl: String = profile.profilePictureUrl {
                message.profile = VisibleMessage.VMProfile(
                    displayName: profile.name,
                    profileKey: profileKey,
                    profilePictureUrl: profilePictureUrl
                )
            }
            else {
                message.profile = VisibleMessage.VMProfile(displayName: profile.name)
            }
        }
        
        // Perform any pre-send actions
        handleMessageWillSend(db, message: message, interactionId: interactionId)
        
        // Convert it to protobuf
        guard let proto = message.toProto(db, threadId: recipientBlindedPublicKey) else {
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .protoConversionFailed,
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Serialize the protobuf
        let plaintext: Data
        
        do {
            plaintext = try proto.serializedData().paddedMessageBody()
        }
        catch {
            SNLog("Couldn't serialize proto due to error: \(error).")
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .other(error),
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        // Encrypt the serialized protobuf
        let ciphertext: Data
        
        do {
            ciphertext = try encryptWithSessionBlindingProtocol(
                db,
                plaintext: plaintext,
                for: recipientBlindedPublicKey,
                openGroupPublicKey: openGroupPublicKey,
                using: dependencies
            )
        }
        catch {
            SNLog("Couldn't encrypt message for destination: \(destination) due to error: \(error).")
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                with: .other(error),
                interactionId: interactionId,
                using: dependencies
            )
        }
        
        return PreparedSendData(
            message: message,
            destination: destination,
            interactionId: interactionId,
            ciphertext: ciphertext
        )
    }
    
    // MARK: - Sending
    
    public static func sendImmediate(
        data: PreparedSendData,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        guard data.shouldSend else {
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        // We now allow the creation of message data without validating it's attachments have finished
        // uploading first, this is here to ensure we don't send a message which should have uploaded
        // files
        //
        // If you see this error then you need to call
        // `MessageSender.performUploadsIfNeeded(queue:preparedSendData:)` before calling this function
        switch data.message {
            case let visibleMessage as VisibleMessage:
                let expectedAttachmentUploadCount: Int = (
                    visibleMessage.attachmentIds.count +
                    (visibleMessage.linkPreview?.attachmentId != nil ? 1 : 0) +
                    (visibleMessage.quote?.attachmentId != nil ? 1 : 0)
                )
                
                guard expectedAttachmentUploadCount == data.totalAttachmentsUploaded else {
                    // Make sure to actually handle this as a failure (if we don't then the message
                    // won't go into an error state correctly)
                    if let message: Message = data.message {
                        dependencies.storage.read { db in
                            MessageSender.handleFailedMessageSend(
                                db,
                                message: message,
                                with: .attachmentsNotUploaded,
                                interactionId: data.interactionId,
                                isSyncMessage: (data.isSyncMessage == true),
                                using: dependencies
                            )
                        }
                    }
                    
                    return Fail(error: MessageSenderError.attachmentsNotUploaded)
                        .eraseToAnyPublisher()
                }
                
                break
                
            default: break
        }
        
        switch data.destination {
            case .contact, .closedGroup: return sendToSnodeDestination(data: data, using: dependencies)
            case .openGroup: return sendToOpenGroupDestination(data: data, using: dependencies)
            case .openGroupInbox: return sendToOpenGroupInbox(data: data, using: dependencies)
        }
    }
    
    // MARK: - One-to-One
    
    private static func sendToSnodeDestination(
        data: PreparedSendData,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        guard
            let message: Message = data.message,
            let namespace: SnodeAPI.Namespace = data.namespace,
            let isSyncMessage: Bool = data.isSyncMessage,
            let snodeMessage: SnodeMessage = data.snodeMessage
        else {
            return Fail(error: MessageSenderError.invalidMessage)
                .eraseToAnyPublisher()
        }
        
        return dependencies.network
            .send(.message(snodeMessage, in: namespace, using: dependencies))
            .flatMap { info, response -> AnyPublisher<Void, Error> in
                let updatedMessage: Message = message
                updatedMessage.serverHash = response.hash

                let job: Job? = Job(
                    variant: .notifyPushServer,
                    behaviour: .runOnce,
                    details: NotifyPushServerJob.Details(message: snodeMessage)
                )
                let shouldNotify: Bool = {
                    switch updatedMessage {
                        case is VisibleMessage, is UnsendRequest: return !isSyncMessage
                        case let callMessage as CallMessage:
                            // Note: Other 'CallMessage' types are too big to send as push notifications
                            // so only send the 'preOffer' message as a notification
                            switch callMessage.kind {
                                case .preOffer: return true
                                default: return false
                            }

                        default: return false
                    }
                }()

                return dependencies.storage
                    .writePublisher { db -> Void in
                        try MessageSender.handleSuccessfulMessageSend(
                            db,
                            message: updatedMessage,
                            to: data.destination,
                            interactionId: data.interactionId,
                            isSyncMessage: isSyncMessage,
                            using: dependencies
                        )

                        guard shouldNotify else { return () }

                        dependencies.jobRunner.add(db, job: job, canStartJob: true, using: dependencies)
                        return ()
                    }
                    .flatMap { _ -> AnyPublisher<Void, Error> in
                        let isMainAppActive: Bool = (UserDefaults.sharedLokiProject?[.isMainAppActive])
                            .defaulting(to: false)
                        
                        guard shouldNotify && !isMainAppActive else {
                            return Just(())
                                .setFailureType(to: Error.self)
                                .eraseToAnyPublisher()
                        }
                        guard let job: Job = job else {
                            return Just(())
                                .setFailureType(to: Error.self)
                                .eraseToAnyPublisher()
                        }

                        return Deferred {
                            Future<Void, Error> { resolver in
                                NotifyPushServerJob.run(
                                    job,
                                    queue: .global(qos: .default),
                                    success: { _, _, _ in resolver(Result.success(())) },
                                    failure: { _, _, _, _ in
                                        // Always fulfill because the notify PN server job isn't critical.
                                        resolver(Result.success(()))
                                    },
                                    deferred: { _, _ in
                                        // Always fulfill because the notify PN server job isn't critical.
                                        resolver(Result.success(()))
                                    },
                                    using: dependencies
                                )
                            }
                        }
                        .eraseToAnyPublisher()
                    }
                    .eraseToAnyPublisher()
            }
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            SNLog("Couldn't send message due to error: \(error).")

                            dependencies.storage.read { db in
                                MessageSender.handleFailedMessageSend(
                                    db,
                                    message: message,
                                    with: .other(error),
                                    interactionId: data.interactionId,
                                    using: dependencies
                                )
                            }
                    }
                }
            )
            .map { _ in () }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Open Groups
    
    private static func sendToOpenGroupDestination(
        data: PreparedSendData,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        guard
            let message: Message = data.message,
            case .openGroup(let roomToken, let server, let whisperTo, let whisperMods, let fileIds) = data.destination,
            let plaintext: Data = data.plaintext
        else {
            return Fail(error: MessageSenderError.invalidMessage)
                .eraseToAnyPublisher()
        }
        
        // Send the result
        return dependencies.storage
            .readPublisher { db in
                try OpenGroupAPI
                    .preparedSend(
                        db,
                        plaintext: plaintext,
                        to: roomToken,
                        on: server,
                        whisperTo: whisperTo,
                        whisperMods: whisperMods,
                        fileIds: fileIds,
                        using: dependencies
                    )
            }
            .flatMap { OpenGroupAPI.send(data: $0, using: dependencies) }
            .flatMap { (responseInfo, responseData) -> AnyPublisher<Void, Error> in
                let serverTimestampMs: UInt64? = responseData.posted.map { UInt64(floor($0 * 1000)) }
                let updatedMessage: Message = message
                updatedMessage.openGroupServerMessageId = UInt64(responseData.id)
                
                return dependencies.storage.writePublisher { db in
                    // The `posted` value is in seconds but we sent it in ms so need that for de-duping
                    try MessageSender.handleSuccessfulMessageSend(
                        db,
                        message: updatedMessage,
                        to: data.destination,
                        interactionId: data.interactionId,
                        serverTimestampMs: serverTimestampMs,
                        using: dependencies
                    )
                    
                    return ()
                }
            }
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            dependencies.storage.read { db in
                                MessageSender.handleFailedMessageSend(
                                    db,
                                    message: message,
                                    with: .other(error),
                                    interactionId: data.interactionId,
                                    using: dependencies
                                )
                            }
                    }
                }
            )
            .eraseToAnyPublisher()
    }
    
    private static func sendToOpenGroupInbox(
        data: PreparedSendData,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        guard
            let message: Message = data.message,
            case .openGroupInbox(let server, _, let recipientBlindedPublicKey) = data.destination,
            let ciphertext: Data = data.ciphertext
        else {
            return Fail(error: MessageSenderError.invalidMessage)
                .eraseToAnyPublisher()
        }
        
        // Send the result
        return dependencies.storage
            .readPublisher { db in
                try OpenGroupAPI
                    .preparedSend(
                        db,
                        ciphertext: ciphertext,
                        toInboxFor: recipientBlindedPublicKey,
                        on: server,
                        using: dependencies
                    )
            }
            .flatMap { OpenGroupAPI.send(data: $0, using: dependencies) }
            .flatMap { (responseInfo, responseData) -> AnyPublisher<Void, Error> in
                let updatedMessage: Message = message
                updatedMessage.openGroupServerMessageId = UInt64(responseData.id)
                
                return dependencies.storage.writePublisher { db in
                    // The `posted` value is in seconds but we sent it in ms so need that for de-duping
                    try MessageSender.handleSuccessfulMessageSend(
                        db,
                        message: updatedMessage,
                        to: data.destination,
                        interactionId: data.interactionId,
                        serverTimestampMs: UInt64(floor(responseData.posted * 1000)),
                        using: dependencies
                    )

                    return ()
                }
            }
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            dependencies.storage.read { db in
                                MessageSender.handleFailedMessageSend(
                                    db,
                                    message: message,
                                    with: .other(error),
                                    interactionId: data.interactionId,
                                    using: dependencies
                                )
                            }
                    }
                }
            )
            .eraseToAnyPublisher()
    }

    // MARK: Success & Failure Handling
    
    public static func handleMessageWillSend(
        _ db: Database,
        message: Message,
        interactionId: Int64?,
        isSyncMessage: Bool = false
    ) {
        // If the message was a reaction then we don't want to do anything to the original
        // interaction (which the 'interactionId' is pointing to
        guard (message as? VisibleMessage)?.reaction == nil else { return }
        
        // Mark messages as "sending"/"syncing" if needed (this is for retries)
        _ = try? RecipientState
            .filter(RecipientState.Columns.interactionId == interactionId)
            .filter(isSyncMessage ?
                RecipientState.Columns.state == RecipientState.State.failedToSync :
                RecipientState.Columns.state == RecipientState.State.failed
            )
            .updateAll(
                db,
                RecipientState.Columns.state.set(to: isSyncMessage ?
                    RecipientState.State.syncing :
                    RecipientState.State.sending
                )
            )
    }
    
    private static func handleSuccessfulMessageSend(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        serverTimestampMs: UInt64? = nil,
        isSyncMessage: Bool = false,
        using dependencies: Dependencies
    ) throws {
        // If the message was a reaction then we want to update the reaction instead of the original
        // interaction (which the 'interactionId' is pointing to
        if let visibleMessage: VisibleMessage = message as? VisibleMessage, let reaction: VisibleMessage.VMReaction = visibleMessage.reaction {
            try Reaction
                .filter(Reaction.Columns.interactionId == interactionId)
                .filter(Reaction.Columns.authorId == reaction.publicKey)
                .filter(Reaction.Columns.emoji == reaction.emoji)
                .updateAll(db, Reaction.Columns.serverHash.set(to: message.serverHash))
        }
        else {
            // Otherwise we do want to try and update the referenced interaction
            let interaction: Interaction? = try interaction(db, for: message, interactionId: interactionId)
            
            // Get the visible message if possible
            if let interaction: Interaction = interaction {
                // Only store the server hash of a sync message if the message is self send valid
                if (message.isSelfSendValid && isSyncMessage || !isSyncMessage) {
                    try interaction.with(
                        serverHash: message.serverHash,
                        // Track the open group server message ID and update server timestamp (use server
                        // timestamp for open group messages otherwise the quote messages may not be able
                        // to be found by the timestamp on other devices
                        timestampMs: (message.openGroupServerMessageId == nil ?
                            nil :
                            serverTimestampMs.map { Int64($0) }
                        ),
                        openGroupServerMessageId: message.openGroupServerMessageId.map { Int64($0) }
                    ).update(db)
                    
                    if interaction.isExpiringMessage {
                        // Start disappearing messages job after a message is successfully sent.
                        // For DAR and DAS outgoing messages, the expiration start time are the
                        // same as message sentTimestamp. So do this once, DAR and DAS messages
                        // should all be covered.
                        dependencies.jobRunner.upsert(
                            db,
                            job: DisappearingMessagesJob.updateNextRunIfNeeded(
                                db,
                                interaction: interaction,
                                startedAtMs: Double(interaction.timestampMs)
                            ),
                            canStartJob: true,
                            using: dependencies
                        )
                        
                        if
                            isSyncMessage,
                            let startedAtMs: Double = interaction.expiresStartedAtMs,
                            let expiresInSeconds: TimeInterval = interaction.expiresInSeconds,
                            let serverHash: String = message.serverHash
                        {
                            let expirationTimestampMs: Int64 = Int64(startedAtMs + expiresInSeconds * 1000)
                            dependencies.jobRunner.add(
                                db,
                                job: Job(
                                    variant: .expirationUpdate,
                                    behaviour: .runOnce,
                                    threadId: interaction.threadId,
                                    details: ExpirationUpdateJob.Details(
                                        serverHashes: [serverHash],
                                        expirationTimestampMs: expirationTimestampMs
                                    )
                                ),
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                    }
                }
                
                // Mark the message as sent
                try interaction.recipientStates
                    .filter(RecipientState.Columns.state != RecipientState.State.sent)
                    .updateAll(db, RecipientState.Columns.state.set(to: RecipientState.State.sent))
            }
        }
        
        // Extract the threadId from the message
        let threadId: String = Message.threadId(forMessage: message, destination: destination)
        
        // Prevent ControlMessages from being handled multiple times if not supported
        try? ControlMessageProcessRecord(
            threadId: threadId,
            message: message,
            serverExpirationTimestamp: (
                (TimeInterval(SnodeAPI.currentOffsetTimestampMs()) / 1000) +
                ControlMessageProcessRecord.defaultExpirationSeconds
            )
        )?.insert(db)

        // Sync the message if needed
        scheduleSyncMessageIfNeeded(
            db,
            message: message,
            destination: destination,
            threadId: threadId,
            interactionId: interactionId,
            isAlreadySyncMessage: isSyncMessage,
            using: dependencies
        )
    }

    @discardableResult internal static func handleFailedMessageSend(
        _ db: Database,
        message: Message,
        with error: MessageSenderError,
        interactionId: Int64?,
        isSyncMessage: Bool = false,
        using dependencies: Dependencies
    ) -> Error {
        // If the message was a reaction then we don't want to do anything to the original
        // interaciton (which the 'interactionId' is pointing to
        guard (message as? VisibleMessage)?.reaction == nil else { return error }
        
        // Check if we need to mark any "sending" recipients as "failed"
        //
        // Note: The 'db' could be either read-only or writeable so we determine
        // if a change is required, and if so dispatch to a separate queue for the
        // actual write
        let rowIds: [Int64] = (try? RecipientState
            .select(Column.rowID)
            .filter(RecipientState.Columns.interactionId == interactionId)
            .filter(!isSyncMessage ?
                RecipientState.Columns.state == RecipientState.State.sending : (
                    RecipientState.Columns.state == RecipientState.State.syncing ||
                    RecipientState.Columns.state == RecipientState.State.sent
                )
            )
            .asRequest(of: Int64.self)
            .fetchAll(db))
            .defaulting(to: [])
        
        guard !rowIds.isEmpty else { return error }
        
        // Need to dispatch to a different thread to prevent a potential db re-entrancy
        // issue from occuring in some cases
        DispatchQueue.global(qos: .background).async {
            dependencies.storage.write { db in
                try RecipientState
                    .filter(rowIds.contains(Column.rowID))
                    .updateAll(
                        db,
                        RecipientState.Columns.state.set(
                            to: (isSyncMessage ? RecipientState.State.failedToSync : RecipientState.State.failed)
                        ),
                        RecipientState.Columns.mostRecentFailureText.set(to: error.localizedDescription)
                    )
            }
        }
        
        return error
    }
    
    // MARK: - Convenience
    
    private static func interaction(_ db: Database, for message: Message, interactionId: Int64?) throws -> Interaction? {
        if let interactionId: Int64 = interactionId {
            return try Interaction.fetchOne(db, id: interactionId)
        }
        
        if let sentTimestamp: Double = message.sentTimestamp.map({ Double($0) }) {
            return try Interaction
                .filter(Interaction.Columns.timestampMs == sentTimestamp)
                .fetchOne(db)
        }
        
        return nil
    }
    
    public static func scheduleSyncMessageIfNeeded(
        _ db: Database,
        message: Message,
        destination: Message.Destination,
        threadId: String?,
        interactionId: Int64?,
        isAlreadySyncMessage: Bool,
        using dependencies: Dependencies
    ) {
        // Sync the message if it's not a sync message, wasn't already sent to the current user and
        // it's a message type which should be synced
        let currentUserPublicKey = getUserHexEncodedPublicKey(db, using: dependencies)
        
        if
            case .contact(let publicKey) = destination,
            !isAlreadySyncMessage,
            publicKey != currentUserPublicKey,
            Message.shouldSync(message: message)
        {
            if let message = message as? VisibleMessage { message.syncTarget = publicKey }
            
            dependencies.jobRunner.add(
                db,
                job: Job(
                    variant: .messageSend,
                    threadId: threadId,
                    interactionId: interactionId,
                    details: MessageSendJob.Details(
                        destination: .contact(publicKey: currentUserPublicKey),
                        message: message,
                        isSyncMessage: true
                    )
                ),
                canStartJob: true,
                using: dependencies
            )
        }
    }
}
