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
        message: ExpirationTimerUpdate,
        serverExpirationTimestamp: TimeInterval?,
        proto: SNProtoContent
    ) throws {
        guard proto.hasExpirationType || proto.hasExpirationTimer else { return }
        guard
            threadVariant != .community,
            let sender: String = message.sender,
            let timestampMs: UInt64 = message.sentTimestamp
        else {
            return
        }
        
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
        
        switch threadVariant {
            case .legacyGroup:
                // Only change the config when it is changed from the admin
                if localConfig != updatedConfig &&
                   GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .filter(GroupMember.Columns.profileId == sender)
                    .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                    .isNotEmpty(db)
                {
                    _ = try updatedConfig.save(db)
                    
                    try LibSession
                        .update(
                            db,
                            groupPublicKey: threadId,
                            disappearingConfig: updatedConfig
                        )
                }
                fallthrough
            case .contact:
                // Handle Note to Self:
                // We sync disappearing messages config through shared config message only.
                // If the updated config from this message is different from local config,
                // this control message should already be removed.
                if threadId == getUserHexEncodedPublicKey(db) && updatedConfig != localConfig {
                    return
                }
                _ = try updatedConfig.insertControlMessage(
                    db,
                    threadVariant: threadVariant,
                    authorId: sender,
                    timestampMs: Int64(timestampMs),
                    serverHash: message.serverHash, 
                    serverExpirationTimestamp: serverExpirationTimestamp
                )
            default:
                 return
        }
    }
    
    public static func updateContactDisappearingMessagesVersionIfNeeded(
        _ db: Database,
        messageVariant: Message.Variant?,
        contactId: String?,
        version: FeatureVersion?
    ) {
        guard
            let messageVariant: Message.Variant = messageVariant,
            let contactId: String = contactId,
            let version: FeatureVersion = version
        else {
            return
        }
        
        guard [ .visibleMessage, .expirationTimerUpdate ].contains(messageVariant) else { return }
        
        _ = try? Contact
            .filter(id: contactId)
            .updateAllAndConfig(
                db,
                Contact.Columns.lastKnownClientVersion.set(to: version)
            )
    }
}
