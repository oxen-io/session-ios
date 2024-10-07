// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

extension MessageReceiver {
    public static func handleUnsendRequest(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: UnsendRequest,
        using dependencies: Dependencies
    ) throws {
        guard
            message.sender == message.author ||
            dependencies[cache: .general].sessionId.hexString == message.sender
        else { return }
        guard let author: String = message.author, let timestampMs: UInt64 = message.timestamp else { return }
        
        let maybeInteraction: Interaction? = try Interaction
            .filter(Interaction.Columns.timestampMs == Int64(timestampMs))
            .filter(Interaction.Columns.authorId == author)
            .fetchOne(db)
        
        guard
            let interactionId: Int64 = maybeInteraction?.id,
            let interaction: Interaction = maybeInteraction
        else { return }
        
        // Mark incoming messages as read and remove any of their notifications
        if interaction.variant == .standardIncoming {
            try Interaction.markAsRead(
                db,
                interactionId: interactionId,
                threadId: interaction.threadId,
                threadVariant: threadVariant,
                includingOlder: false,
                trySendReadReceipt: false,
                using: dependencies
            )
            
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: interaction.notificationIdentifiers)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: interaction.notificationIdentifiers)
        }
        
        if author == message.sender, let serverHash: String = interaction.serverHash {
            dependencies[singleton: .storage]
                .readPublisher { db in
                    try SnodeAPI
                        .preparedDeleteMessages(
                            serverHashes: [serverHash],
                            requireSuccessfulDeletion: false,
                            authMethod: try Authentication.with(
                                db,
                                swarmPublicKey: author,
                                using: dependencies
                            ),
                            using: dependencies
                        )
                }
                .flatMap { $0.send(using: dependencies) }
                .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
                .sinkUntilComplete()
        }
         
        switch (interaction.variant, (author == message.sender)) {
            case (.standardOutgoing, _), (_, false):
                _ = try interaction.delete(db)
                
            case (_, true):
                try interaction
                    .markingAsDeleted(localOnly: false)
                    .upserted(db)
                
                _ = try interaction.attachments
                    .deleteAll(db)
                
                if let serverHash: String = interaction.serverHash {
                    try SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                        db,
                        potentiallyInvalidHashes: [serverHash]
                    )
                }
        }
    }
}
