// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUIKit
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func handleExpirationTimerUpdate(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: Message,
        serverExpirationTimestamp: TimeInterval?,
        proto: SNProtoContent,
        using dependencies: Dependencies
    ) throws {
        guard proto.hasExpirationType || proto.hasExpirationTimer else { return }
        guard
            threadVariant != .community,
            let sender: String = message.sender,
            let timestampMs: UInt64 = message.sentTimestampMs
        else { return }
        
        let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
            .fetchOne(db, id: threadId)
            .defaulting(to: DisappearingMessagesConfiguration.defaultWith(threadId))
        
        let durationSeconds: TimeInterval = (proto.hasExpirationTimer ? TimeInterval(proto.expirationTimer) : 0)
        let disappearingType: DisappearingMessagesConfiguration.DisappearingMessageType? = (proto.hasExpirationType ?
            .init(protoType: proto.expirationType) :
            .unknown
        )
        let updatedConfig: DisappearingMessagesConfiguration = localConfig.with(
            isEnabled: (durationSeconds != 0),
            durationSeconds: durationSeconds,
            type: disappearingType
        )
        
        // Contacts & legacy closed groups need to update the SessionUtil
        switch threadVariant {
            case .legacyGroup:
                // Only change the config when it is changed from the admin
                if
                    localConfig != updatedConfig &&
                    GroupMember
                        .filter(GroupMember.Columns.groupId == threadId)
                        .filter(GroupMember.Columns.profileId == sender)
                        .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                        .isNotEmpty(db)
                {
                    _ = try updatedConfig.upsert(db)
                    
                    try LibSession
                        .update(
                            db,
                            legacyGroupSessionId: threadId,
                            disappearingConfig: updatedConfig,
                            using: dependencies
                        )
                }
                fallthrough // Fallthrough to insert the control message
                
            case .contact:
                // Handle Note to Self:
                // We sync disappearing messages config through shared config message only.
                // If the updated config from this message is different from local config,
                // this control message should already be removed.
                if threadId == dependencies[cache: .general].sessionId.hexString && updatedConfig != localConfig {
                    return
                }
                
                _ = try updatedConfig.insertControlMessage(
                    db,
                    threadVariant: threadVariant,
                    authorId: sender,
                    timestampMs: Int64(timestampMs),
                    serverHash: message.serverHash,
                    serverExpirationTimestamp: serverExpirationTimestamp,
                    using: dependencies
                )
            
            // For updated groups we want to only rely on the `GROUP_INFO` config message to
            // control the disappearing messages setting
            case .group, .community: break
        }
    }
    
    public static func updateContactDisappearingMessagesVersionIfNeeded(
        _ db: Database,
        messageVariant: Message.Variant?,
        contactId: String?,
        version: FeatureVersion?,
        using dependencies: Dependencies
    ) {
        guard
            let messageVariant: Message.Variant = messageVariant,
            let contactId: String = contactId,
            let version: FeatureVersion = version
        else { return }
        
        guard [ .visibleMessage, .expirationTimerUpdate ].contains(messageVariant) else { return }
        
        _ = try? Contact
            .filter(id: contactId)
            .updateAllAndConfig(
                db,
                Contact.Columns.lastKnownClientVersion.set(to: version),
                calledFromConfig: nil,
                using: dependencies
            )
    }
}
