// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUIKit
import SessionUtilitiesKit

extension MessageReceiver {
    // TODO: Remove this when disappearing messages V2 is up and running
    internal static func handleExpirationTimerUpdate(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: ExpirationTimerUpdate,
        using dependencies: Dependencies
    ) throws {
        guard !dependencies[feature: .updatedDisappearingMessages] else { return }
        guard
            // Only process these for contact and legacy groups (new groups handle it separately)
            (threadVariant == .contact || threadVariant == .legacyGroup),
            let sender: String = message.sender
        else { throw MessageReceiverError.invalidMessage }
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        // Generate an updated configuration
        //
        // Note: Messages which had been sent during the previous configuration will still
        // use it's settings (so if you enable, send a message and then disable disappearing
        // message then the message you had sent will still disappear)
        let maybeDefaultType: DisappearingMessagesConfiguration.DisappearingMessageType? = {
            switch (threadVariant, threadId == userSessionId.hexString) {
                case (.contact, false): return .disappearAfterRead
                case (.legacyGroup, _), (.group, _), (_, true): return .disappearAfterSend
                case (.community, _): return nil // Shouldn't happen
            }
        }()

        guard let defaultType: DisappearingMessagesConfiguration.DisappearingMessageType = maybeDefaultType else { return }
        
        let defaultDuration: DisappearingMessagesConfiguration.DefaultDuration = {
            switch defaultType {
                case .unknown: return .unknown
                case .disappearAfterRead: return .disappearAfterRead
                case .disappearAfterSend: return .disappearAfterSend
            }
        }()
        
        let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
            .filter(id: threadId)
            .fetchOne(db)
            .defaulting(to: DisappearingMessagesConfiguration.defaultWith(threadId))
        
        let updatedConfig: DisappearingMessagesConfiguration = localConfig.with(
            // If there is no duration then we should disable the expiration timer
            isEnabled: ((message.duration ?? 0) > 0),
            durationSeconds: (
                message.duration.map { TimeInterval($0) } ??
                defaultDuration.seconds
            ),
            type: defaultType
        )
        
        let timestampMs: Int64 = Int64(message.sentTimestamp ?? 0) // Default to `0` if not set
        
        // Only actually make the change if LibSession says we can (we always want to insert the info
        // message though)
        let canPerformChange: Bool = LibSession.canPerformChange(
            db,
            threadId: threadId,
            targetConfig: {
                switch threadVariant {
                    case .contact: return (threadId == userSessionId.hexString ? .userProfile : .contacts)
                    default: return .userGroups
                }
            }(),
            changeTimestampMs: timestampMs,
            using: dependencies
        )
        
        // Only update libSession if we can perform the change
        if canPerformChange {
            // Contacts & legacy closed groups need to update the LibSession
            switch threadVariant {
                case .contact:
                    try LibSession
                        .update(
                            db,
                            sessionId: threadId,
                            disappearingMessagesConfig: updatedConfig,
                            using: dependencies
                        )
                
                case .legacyGroup:
                    try LibSession
                        .update(
                            db,
                            legacyGroupSessionId: threadId,
                            disappearingConfig: updatedConfig,
                            using: dependencies
                        )
                    
                default: break
            }
        }
        
        // Only save the updated config if we can perform the change
        if canPerformChange {
            // Finally save the changes to the DisappearingMessagesConfiguration (If it's a duplicate
            // then the interaction unique constraint will prevent the code from getting here)
            try updatedConfig.upsert(db)
        }
        
        // Add an info message for the user
        _ = try Interaction(
            serverHash: nil, // Intentionally null so sync messages are seen as duplicates
            threadId: threadId,
            threadVariant: threadVariant,
            authorId: sender,
            variant: .infoDisappearingMessagesUpdate,
            body: updatedConfig.messageInfoString(
                threadVariant: threadVariant,
                senderName: (sender != userSessionId.hexString ?
                    Profile.displayName(db, id: sender, using: dependencies) :
                    nil
                ),
                using: dependencies
            ),
            timestampMs: timestampMs,
            wasRead: dependencies[cache: .libSession].timestampAlreadyRead(
                threadId: threadId,
                threadVariant: threadVariant,
                timestampMs: (timestampMs * 1000),
                userSessionId: userSessionId,
                openGroup: nil
            ),
            using: dependencies
        ).inserted(db)
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
        else {
            return
        }
        
        guard [ .visibleMessage, .expirationTimerUpdate ].contains(messageVariant) else { return }
        
        _ = try? Contact
            .filter(id: contactId)
            .updateAllAndConfig(
                db,
                Contact.Columns.lastKnownClientVersion.set(to: version),
                calledFromConfig: nil,
                using: dependencies
            )
        
        guard dependencies[feature: .updatedDisappearingMessages] else { return }
        
        if contactId == dependencies[cache: .general].sessionId.hexString {
            switch version {
                case .legacyDisappearingMessages: TopBannerController.show(warning: .outdatedUserConfig)
                case .newDisappearingMessages: TopBannerController.hide()
            }
        }
    }
    
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
            let timestampMs: UInt64 = message.sentTimestamp,
            dependencies[feature: .updatedDisappearingMessages]
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
}
