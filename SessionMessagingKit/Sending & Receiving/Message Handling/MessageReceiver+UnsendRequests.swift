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
        let senderIsLegacyGroupAdmin: Bool = {
            switch (message.sender, threadVariant) {
                case (.some(let sender), .legacyGroup):
                    return GroupMember
                        .filter(GroupMember.Columns.groupId == threadId)
                        .filter(GroupMember.Columns.profileId == sender)
                        .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                        .isNotEmpty(db)
                    
                default: return false
            }
        }()
        
        guard
            senderIsLegacyGroupAdmin ||
            message.sender == message.author ||
            dependencies[cache: .general].sessionId.hexString == message.sender
        else { return }
        guard let author: String = message.author, let timestampMs: UInt64 = message.timestamp else { return }
        
        let maybeInteractionId: Int64? = try Interaction
            .filter(Interaction.Columns.timestampMs == Int64(timestampMs))
            .filter(Interaction.Columns.authorId == author)
            .select(.id)
            .asRequest(of: Int64.self)
            .fetchOne(db)
        
        guard let interactionId: Int64 = maybeInteractionId else { return }
        
        /// Retrieve the hashes which should be deleted first (these will be removed by marking the message as deleted)
        let hashes: Set<String> = try Interaction.serverHashesForDeletion(
            db,
            interactionIds: [interactionId]
        )
        try Interaction.markAsDeleted(
            db,
            threadId: threadId,
            threadVariant: threadVariant,
            interactionIds: [interactionId],
            localOnly: false,
            using: dependencies
        )
        
        /// Can't delete from the legacy group swarm so only bother for contact conversations
        switch threadVariant {
            case .legacyGroup, .group, .community: break
            case .contact:
                dependencies[singleton: .storage]
                    .readPublisher { db in
                        try SnodeAPI.preparedDeleteMessages(
                            serverHashes: Array(hashes),
                            requireSuccessfulDeletion: false,
                            authMethod: try Authentication.with(
                                db,
                                swarmPublicKey: dependencies[cache: .general].sessionId.hexString,
                                using: dependencies
                            ),
                            using: dependencies
                        )
                    }
                    .flatMap { $0.send(using: dependencies) }
                    .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
                    .sinkUntilComplete(
                        receiveCompletion: { result in
                            switch result {
                                case .failure: break
                                case .finished:
                                    /// Since the server deletion was successful we should also remove the `SnodeReceivedMessageInfo`
                                    /// entries for the hashes (otherwise we might try to poll for a hash which no longer exists, resulting in fetching
                                    /// the last 14 days of messages)
                                    dependencies[singleton: .storage].writeAsync { db in
                                        try SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                                            db,
                                            potentiallyInvalidHashes: Array(hashes)
                                        )
                                    }
                            }
                        }
                    )
        }
    }
}
