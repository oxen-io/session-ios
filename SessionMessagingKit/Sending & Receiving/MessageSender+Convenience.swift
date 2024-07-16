// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

extension MessageSender {
    // MARK: - Durable
    
    public static func send(
        _ db: Database,
        interaction: Interaction,
        threadId: String,
        threadVariant: SessionThread.Variant,
        isSyncMessage: Bool = false,
        using dependencies: Dependencies
    ) throws {
        // Only 'VisibleMessage' types can be sent via this method
        guard interaction.variant == .standardOutgoing else { throw MessageSenderError.invalidMessage }
        guard let interactionId: Int64 = interaction.id else { throw StorageError.objectNotSaved }
        
        send(
            db,
            message: VisibleMessage.from(db, interaction: interaction),
            threadId: threadId,
            interactionId: interactionId,
            to: try Message.Destination.from(db, threadId: threadId, threadVariant: threadVariant),
            isSyncMessage: isSyncMessage,
            using: dependencies
        )
    }
    
    public static func send(
        _ db: Database,
        message: Message,
        interactionId: Int64?,
        threadId: String,
        threadVariant: SessionThread.Variant,
        after blockingJob: Job? = nil,
        isSyncMessage: Bool = false,
        using dependencies: Dependencies
    ) throws {
        send(
            db,
            message: message,
            threadId: threadId,
            interactionId: interactionId,
            to: try Message.Destination.from(db, threadId: threadId, threadVariant: threadVariant),
            isSyncMessage: isSyncMessage,
            using: dependencies
        )
    }
    
    public static func send(
        _ db: Database,
        message: Message,
        threadId: String?,
        interactionId: Int64?,
        to destination: Message.Destination,
        isSyncMessage: Bool = false,
        using dependencies: Dependencies
    ) {
        // If it's a sync message then we need to make some slight tweaks before sending so use the proper
        // sync message sending process instead of the standard process
        guard !isSyncMessage else {
            scheduleSyncMessageIfNeeded(
                db,
                message: message,
                destination: destination,
                threadId: threadId,
                interactionId: interactionId,
                using: dependencies
            )
            return
        }
        
        dependencies[singleton: .jobRunner].add(
            db,
            job: Job(
                variant: .messageSend,
                threadId: threadId,
                interactionId: interactionId,
                details: MessageSendJob.Details(
                    destination: destination,
                    message: message
                )
            ),
            canStartJob: true
        )
    }

    // MARK: - Non-Durable
    
    public static func preparedSend(
        _ db: Database,
        interaction: Interaction,
        fileIds: [String],
        threadId: String,
        threadVariant: SessionThread.Variant,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Void> {
        // Only 'VisibleMessage' types can be sent via this method
        guard interaction.variant == .standardOutgoing else { throw MessageSenderError.invalidMessage }
        guard let interactionId: Int64 = interaction.id else { throw StorageError.objectNotSaved }

        return try MessageSender.preparedSend(
            db,
            message: VisibleMessage.from(db, interaction: interaction),
            to: try Message.Destination.from(db, threadId: threadId, threadVariant: threadVariant),
            namespace: try Message.Destination
                .from(db, threadId: threadId, threadVariant: threadVariant)
                .defaultNamespace,
            interactionId: interactionId,
            fileIds: fileIds,
            using: dependencies
        )
    }
}
