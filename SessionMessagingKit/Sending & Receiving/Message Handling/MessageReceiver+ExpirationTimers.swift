// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
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
        
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        
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
        
        let remoteConfig: DisappearingMessagesConfiguration = localConfig.with(
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
            changeTimestampMs: timestampMs
        )
        
        // Only update libSession if we can perform the change
        if canPerformChange {
            // Contacts & legacy closed groups need to update libSession
            switch threadVariant {
                case .contact:
                    try LibSession
                        .update(
                            db,
                            sessionId: threadId,
                            disappearingMessagesConfig: remoteConfig,
                            using: dependencies
                        )
                
                case .legacyGroup:
                    try LibSession
                        .update(
                            db,
                            legacyGroupSessionId: threadId,
                            disappearingConfig: remoteConfig,
                            using: dependencies
                        )
                    
                default: break
            }
        }
        
        // Only save the updated config if we can perform the change
        if canPerformChange {
            // Finally save the changes to the DisappearingMessagesConfiguration (If it's a duplicate
            // then the interaction unique constraint will prevent the code from getting here)
            try remoteConfig.upsert(db)
        }
        
        // Remove previous info messages
        _ = try Interaction
            .filter(Interaction.Columns.threadId == threadId)
            .filter(Interaction.Columns.variant == Interaction.Variant.infoDisappearingMessagesUpdate)
            .deleteAll(db)
        
        // Add an info message for the user
        _ = try Interaction(
            serverHash: nil, // Intentionally null so sync messages are seen as duplicates
            threadId: threadId,
            authorId: sender,
            variant: .infoDisappearingMessagesUpdate,
            body: remoteConfig.messageInfoString(
                with: (sender != userSessionId.hexString ?
                    Profile.displayName(db, id: sender) :
                    nil
                ),
                isPreviousOff: false,
                using: dependencies
            ),
            timestampMs: timestampMs,
            wasRead: LibSession.timestampAlreadyRead(
                threadId: threadId,
                threadVariant: threadVariant,
                timestampMs: (timestampMs * 1000),
                userSessionId: userSessionId,
                openGroup: nil,
                using: dependencies
            ),
            expiresInSeconds: (remoteConfig.isEnabled ? nil : localConfig.durationSeconds)
        ).inserted(db)
    }
    
    internal static func updateDisappearingMessagesConfigurationIfNeeded(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: Message,
        proto: SNProtoContent,
        using dependencies: Dependencies
    ) throws {
        guard let sender: String = message.sender else { return }
        
        // Check the contact's client version based on this received message
        let lastKnownClientVersion: FeatureVersion = (!proto.hasExpirationTimer ?
            .legacyDisappearingMessages :
            .newDisappearingMessages
        )
        _ = try? Contact
            .filter(id: sender)
            .updateAllAndConfig(
                db,
                Contact.Columns.lastKnownClientVersion.set(to: lastKnownClientVersion),
                using: dependencies
            )
        
        guard
            dependencies[feature: .updatedDisappearingMessages],
            proto.hasLastDisappearingMessageChangeTimestamp
        else { return }
        
        let protoLastChangeTimestampMs: Int64 = Int64(proto.lastDisappearingMessageChangeTimestamp)
        let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
            .fetchOne(db, id: threadId)
            .defaulting(to: DisappearingMessagesConfiguration.defaultWith(threadId))
        
        let durationSeconds: TimeInterval = (proto.hasExpirationTimer ? TimeInterval(proto.expirationTimer) : 0)
        let disappearingType: DisappearingMessagesConfiguration.DisappearingMessageType? = (proto.hasExpirationType ?
            .init(protoType: proto.expirationType) :
            .unknown
        )
        let remoteConfig: DisappearingMessagesConfiguration = localConfig.with(
            isEnabled: (durationSeconds != 0),
            durationSeconds: durationSeconds,
            type: disappearingType,
            lastChangeTimestampMs: protoLastChangeTimestampMs
        )
        
        let updateControlMessage: () throws -> () = {
            guard message is ExpirationTimerUpdate else { return }
            
            _ = try Interaction
                .filter(Interaction.Columns.threadId == threadId)
                .filter(Interaction.Columns.variant == Interaction.Variant.infoDisappearingMessagesUpdate)
                .deleteAll(db)

            _ = try Interaction(
                serverHash: message.serverHash,
                threadId: threadId,
                authorId: sender,
                variant: .infoDisappearingMessagesUpdate,
                body: remoteConfig.messageInfoString(
                    with: (sender != getUserSessionId(db, using: dependencies).hexString ?
                        Profile.displayName(db, id: sender) :
                        nil
                    ),
                    isPreviousOff: !localConfig.isEnabled,
                    using: dependencies
                ),
                timestampMs: protoLastChangeTimestampMs,
                expiresInSeconds: (remoteConfig.isEnabled ? remoteConfig.durationSeconds : localConfig.durationSeconds),
                expiresStartedAtMs: (!remoteConfig.isEnabled && localConfig.type == .disappearAfterSend ?
                    Double(protoLastChangeTimestampMs) :
                    nil
                )
            ).inserted(db)
        }
        
        guard let localLastChangeTimestampMs = localConfig.lastChangeTimestampMs else { return }
        
        guard protoLastChangeTimestampMs >= localLastChangeTimestampMs else {
            if (protoLastChangeTimestampMs + Int64(localConfig.durationSeconds * 1000)) > localLastChangeTimestampMs {
                try updateControlMessage()
            }
            return
        }
        
        if localConfig != remoteConfig {
            _ = try remoteConfig.upsert(db)
            
            // Contacts & legacy closed groups need to update libSession
            switch threadVariant {
                case .contact:
                    try LibSession
                        .update(
                            db,
                            sessionId: threadId,
                            disappearingMessagesConfig: remoteConfig,
                            using: dependencies
                        )
                
                case .legacyGroup:
                    try LibSession
                        .update(
                            db,
                            legacyGroupSessionId: threadId,
                            disappearingConfig: remoteConfig,
                            using: dependencies
                        )
                
                // For updated groups we want to only rely on the `GROUP_INFO` config message to
                // control the disappearing messages setting
                case .group, .community: break
            }
        }
        
        try updateControlMessage()
    }
}
