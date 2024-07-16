// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

extension MessageReceiver {
    public static func handleGroupUpdateMessage(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: Message,
        using dependencies: Dependencies
    ) throws {
        switch (message, try? SessionId(from: threadId)) {
            case (let message as GroupUpdateInviteMessage, _):
                try MessageReceiver.handleGroupInvite(
                    db,
                    message: message,
                    using: dependencies
                )
                
            case (let message as GroupUpdatePromoteMessage, _):
                try MessageReceiver.handleGroupPromotion(
                    db,
                    message: message,
                    using: dependencies
                )
                
            case (let message as GroupUpdateInfoChangeMessage, .some(let sessionId)) where sessionId.prefix == .group:
                try MessageReceiver.handleGroupInfoChanged(
                    db,
                    groupSessionId: sessionId,
                    message: message,
                    using: dependencies
                )
                
            case (let message as GroupUpdateMemberChangeMessage, .some(let sessionId)) where sessionId.prefix == .group:
                try MessageReceiver.handleGroupMemberChanged(
                    db,
                    groupSessionId: sessionId,
                    message: message,
                    using: dependencies
                )
                
            case (let message as GroupUpdateMemberLeftMessage, .some(let sessionId)) where sessionId.prefix == .group:
                try MessageReceiver.handleGroupMemberLeft(
                    db,
                    groupSessionId: sessionId,
                    message: message,
                    using: dependencies
                )
                
            case (let message as GroupUpdateMemberLeftNotificationMessage, .some(let sessionId)) where sessionId.prefix == .group:
                try MessageReceiver.handleGroupMemberLeftNotification(
                    db,
                    groupSessionId: sessionId,
                    message: message,
                    using: dependencies
                )
                
            case (let message as GroupUpdateInviteResponseMessage, .some(let sessionId)) where sessionId.prefix == .group:
                try MessageReceiver.handleGroupInviteResponse(
                    db,
                    groupSessionId: sessionId,
                    message: message,
                    using: dependencies
                )
                
            case (let message as GroupUpdateDeleteMemberContentMessage, .some(let sessionId)) where sessionId.prefix == .group:
                try MessageReceiver.handleGroupDeleteMemberContent(
                    db,
                    groupSessionId: sessionId,
                    message: message,
                    using: dependencies
                )
                
            default: throw MessageReceiverError.invalidMessage
        }
    }
    
    // MARK: - Specific Handling
    
    private static func handleGroupInvite(
        _ db: Database,
        message: GroupUpdateInviteMessage,
        using dependencies: Dependencies
    ) throws {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        guard
            let sender: String = message.sender,
            let sentTimestampMs: UInt64 = message.sentTimestamp,
            Authentication.verify(
                signature: message.adminSignature,
                publicKey: message.groupSessionId.publicKey,
                verificationBytes: GroupUpdateInviteMessage.generateVerificationBytes(
                    inviteeSessionIdHexString: userSessionId.hexString,
                    timestampMs: sentTimestampMs
                ),
                using: dependencies
            ),
            // Somewhat redundant because we know the sender was a group admin but this confirms the
            // authData is valid so protects against invalid invite spam from a group admin
            let userEd25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db),
            dependencies[singleton: .crypto].verify(
                .memberAuthData(
                    groupSessionId: message.groupSessionId,
                    ed25519SecretKey: userEd25519KeyPair.secretKey,
                    memberAuthData: message.memberAuthData
                )
            )
        else { throw MessageReceiverError.invalidMessage }
        
        // Update profile if needed
        if let profile = message.profile {
            try Profile.updateIfNeeded(
                db,
                publicKey: sender,
                name: profile.displayName,
                blocksCommunityMessageRequests: profile.blocksCommunityMessageRequests,
                displayPictureUpdate: {
                    guard
                        let profilePictureUrl: String = profile.profilePictureUrl,
                        let profileKey: Data = profile.profileKey
                    else { return .remove }
                    
                    return .updateTo(
                        url: profilePictureUrl,
                        key: profileKey,
                        fileName: nil
                    )
                }(),
                sentTimestamp: TimeInterval(Double(sentTimestampMs) / 1000),
                calledFromConfig: nil,
                using: dependencies
            )
        }
        
        try processGroupInvite(
            db,
            sender: sender,
            serverHash: message.serverHash,
            sentTimestampMs: Int64(sentTimestampMs),
            groupSessionId: message.groupSessionId,
            groupName: message.groupName,
            memberAuthData: message.memberAuthData,
            groupIdentityPrivateKey: nil,
            using: dependencies
        )
    }
    
    @discardableResult internal static func handleNewGroup(
        _ db: Database,
        groupSessionId: String,
        groupIdentityPrivateKey: Data?,
        name: String,
        authData: Data?,
        joinedAt: TimeInterval,
        invited: Bool,
        calledFromConfig configTriggeringChange: ConfigDump.Variant?,
        cacheToLoadStateInto: LibSessionCacheType?,
        config: LibSession.Config?,
        using dependencies: Dependencies
    ) throws -> AnyPublisher<Poller.PollResult, Never> {
        // Create the group
        try SessionThread.fetchOrCreate(
            db,
            id: groupSessionId,
            variant: .group,
            shouldBeVisible: true,
            calledFromConfig: configTriggeringChange,
            using: dependencies
        )
        let groupAlreadyApproved: Bool = ((try? ClosedGroup.fetchOne(db, id: groupSessionId))?.invited == false)
        let groupInvitedState: Bool = (!groupAlreadyApproved && invited)
        let closedGroup: ClosedGroup = try ClosedGroup(
            threadId: groupSessionId,
            name: name,
            formationTimestamp: joinedAt,
            shouldPoll: false,  // Always false here - will be updated in `approveGroup`
            groupIdentityPrivateKey: groupIdentityPrivateKey,
            authData: authData,
            invited: groupInvitedState
        ).upserted(db)
        
        if configTriggeringChange != .userGroups {
            // Update libSession
            try? LibSession.add(
                db,
                groupSessionId: groupSessionId,
                groupIdentityPrivateKey: groupIdentityPrivateKey,
                name: name,
                authData: authData,
                joinedAt: joinedAt,
                invited: groupInvitedState,
                using: dependencies
            )
        }
        
        let wasKickedFromGroup: Bool = {
            switch (cacheToLoadStateInto, config) {
                case (.some(let cache), .some(let config)):
                    return cache.wasKickedFromGroup(groupSessionId: SessionId(.group, hex: groupSessionId), config: config)
                    
                default:
                    return LibSession.wasKickedFromGroup(groupSessionId: SessionId(.group, hex: groupSessionId), using: dependencies)
            }
        }()
        
        /// If the group wasn't already approved, is not in the invite state and the user hasn't been kicked from it then handle the approval process
        guard !groupAlreadyApproved && !invited && !wasKickedFromGroup else { return Just(([], [])).eraseToAnyPublisher() }
        
        return try ClosedGroup.approveGroup(
            db,
            group: closedGroup,
            calledFromConfig: configTriggeringChange,
            cacheToLoadStateInto: cacheToLoadStateInto,
            using: dependencies
        )
    }
    
    private static func handleGroupPromotion(
        _ db: Database,
        message: GroupUpdatePromoteMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let sender: String = message.sender,
            let sentTimestampMs: UInt64 = message.sentTimestamp,
            let groupIdentityKeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                .ed25519KeyPair(seed: Array(message.groupIdentitySeed))
            )
        else { throw MessageReceiverError.invalidMessage }
        
        let groupSessionId: SessionId = SessionId(.group, publicKey: groupIdentityKeyPair.publicKey)
        
        // Update profile if needed
        if let profile = message.profile {
            try Profile.updateIfNeeded(
                db,
                publicKey: sender,
                name: profile.displayName,
                blocksCommunityMessageRequests: profile.blocksCommunityMessageRequests,
                displayPictureUpdate: {
                    guard
                        let profilePictureUrl: String = profile.profilePictureUrl,
                        let profileKey: Data = profile.profileKey
                    else { return .remove }
                    
                    return .updateTo(
                        url: profilePictureUrl,
                        key: profileKey,
                        fileName: nil
                    )
                }(),
                sentTimestamp: TimeInterval(Double(sentTimestampMs) / 1000),
                calledFromConfig: nil,
                using: dependencies
            )
        }
        
        // Process the promotion as a group invite (if needed)
        try processGroupInvite(
            db,
            sender: sender,
            serverHash: message.serverHash,
            sentTimestampMs: Int64(sentTimestampMs),
            groupSessionId: groupSessionId,
            groupName: message.groupName,
            memberAuthData: nil,
            groupIdentityPrivateKey: Data(groupIdentityKeyPair.secretKey),
            using: dependencies
        )
        
        let groupInInvitedState: Bool = (try? ClosedGroup
            .filter(id: groupSessionId.hexString)
            .select(ClosedGroup.Columns.invited)
            .fetchOne(db))
            .defaulting(to: true)
        
        // If the group is in it's invited state then the admin won't be able to update their admin status
        // so don't bother trying
        guard !groupInInvitedState else { return }
        
        // Actually update the group state to indicate the promotion was accepted
        // Load the admin key into libSession
        try LibSession.loadAdminKey(
            db,
            groupIdentitySeed: message.groupIdentitySeed,
            groupSessionId: groupSessionId,
            using: dependencies
        )
    }
    
    private static func handleGroupInfoChanged(
        _ db: Database,
        groupSessionId: SessionId,
        message: GroupUpdateInfoChangeMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let sender: String = message.sender,
            let sentTimestampMs: UInt64 = message.sentTimestamp,
            Authentication.verify(
                signature: message.adminSignature,
                publicKey: groupSessionId.publicKey,
                verificationBytes: GroupUpdateInfoChangeMessage.generateVerificationBytes(
                    changeType: message.changeType,
                    timestampMs: sentTimestampMs
                ),
                using: dependencies
            )
        else { throw MessageReceiverError.invalidMessage }
        
        // Add a record of the specific change to the conversation (the actual change is handled via
        // config messages so these are only for record purposes)
        switch message.changeType {
            case .name:
                _ = try Interaction(
                    serverHash: message.serverHash,
                    threadId: groupSessionId.hexString,
                    threadVariant: .group,
                    authorId: sender,
                    variant: .infoGroupInfoUpdated,
                    body: message.updatedName
                        .map { ClosedGroup.MessageInfo.updatedName($0) }
                        .defaulting(to: ClosedGroup.MessageInfo.updatedNameFallback)
                        .infoString(using: dependencies),
                    timestampMs: Int64(sentTimestampMs),
                    using: dependencies
                ).inserted(db)
                
            case .avatar:
                _ = try Interaction(
                    serverHash: message.serverHash,
                    threadId: groupSessionId.hexString,
                    threadVariant: .group,
                    authorId: sender,
                    variant: .infoGroupInfoUpdated,
                    body: ClosedGroup.MessageInfo
                        .updatedDisplayPicture
                        .infoString(using: dependencies),
                    timestampMs: Int64(sentTimestampMs),
                    using: dependencies
                ).inserted(db)
                
            case .disappearingMessages:
                /// **Note:** We only create this in order to get the 'messageInfoString' it **should not** be saved as that would
                /// override the correct settings applied by the group config messages
                let userSessionId: SessionId = dependencies[cache: .general].sessionId
                let relevantConfig: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration(
                    threadId: groupSessionId.hexString,
                    isEnabled: ((message.updatedExpiration ?? 0) > 0),
                    durationSeconds: TimeInterval((message.updatedExpiration ?? 0)),
                    type: .disappearAfterSend
                )
                let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
                    .filter(id: groupSessionId.hexString)
                    .fetchOne(db)
                    .defaulting(to: DisappearingMessagesConfiguration.defaultWith(groupSessionId.hexString))
                
                _ = try Interaction(
                    serverHash: message.serverHash,
                    threadId: groupSessionId.hexString,
                    threadVariant: .group,
                    authorId: sender,
                    variant: .infoDisappearingMessagesUpdate,
                    body: relevantConfig.messageInfoString(
                        threadVariant: .group,
                        senderName: (sender != userSessionId.hexString ?
                            Profile.displayName(db, id: sender, using: dependencies) :
                            nil
                        ),
                        using: dependencies
                    ),
                    timestampMs: Int64(sentTimestampMs),
                    wasRead: dependencies[cache: .libSession].timestampAlreadyRead(
                        threadId: groupSessionId.hexString,
                        threadVariant: .group,
                        timestampMs: Int64(sentTimestampMs),
                        userSessionId: userSessionId,
                        openGroup: nil
                    ),
                    expiresInSeconds: (relevantConfig.isEnabled ? nil : localConfig.durationSeconds),
                    using: dependencies
                ).inserted(db)
        }
    }
    
    private static func handleGroupMemberChanged(
        _ db: Database,
        groupSessionId: SessionId,
        message: GroupUpdateMemberChangeMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let sender: String = message.sender,
            let sentTimestampMs: UInt64 = message.sentTimestamp,
            Authentication.verify(
                signature: message.adminSignature,
                publicKey: groupSessionId.publicKey,
                verificationBytes: GroupUpdateMemberChangeMessage.generateVerificationBytes(
                    changeType: message.changeType,
                    timestampMs: sentTimestampMs
                ),
                using: dependencies
            )
        else { throw MessageReceiverError.invalidMessage }
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let profiles: [String: Profile] = (try? Profile
            .filter(ids: message.memberSessionIds)
            .fetchAll(db))
            .defaulting(to: [])
            .reduce(into: [:]) { result, next in result[next.id] = next }
        let names: [String] = message.memberSessionIds
            .sorted { lhs, rhs in lhs == userSessionId.hexString }
            .map { id in
                profiles[id]?.displayName(for: .group) ??
                Profile.truncated(id: id, truncating: .middle)
            }
        
        // Add a record of the specific change to the conversation (the actual change is handled via
        // config messages so these are only for record purposes)
        _ = try Interaction(
            threadId: groupSessionId.hexString,
            threadVariant: .group,
            authorId: sender,
            variant: .infoGroupMembersUpdated,
            body: {
                switch message.changeType {
                    case .added:
                        return ClosedGroup.MessageInfo
                            .addedUsers(
                                hasCurrentUser: message.memberSessionIds.contains(userSessionId.hexString),
                                names: names,
                                historyShared: message.historyShared
                            )
                            .infoString(using: dependencies)
                        
                    case .removed:
                        return ClosedGroup.MessageInfo
                            .removedUsers(names: names)
                            .infoString(using: dependencies)
                        
                    case .promoted:
                        return ClosedGroup.MessageInfo
                            .promotedUsers(names: names)
                            .infoString(using: dependencies)
                }
            }(),
            timestampMs: Int64(sentTimestampMs),
            using: dependencies
        ).inserted(db)
    }
    
    private static func handleGroupMemberLeft(
        _ db: Database,
        groupSessionId: SessionId,
        message: GroupUpdateMemberLeftMessage,
        using dependencies: Dependencies
    ) throws {
        // If the user is a group admin then we need to remove the member from the group, we already have a
        // "member left" message so `sendMemberChangedMessage` should be `false`
        guard
            let sender: String = message.sender,
            let sentTimestampMs: UInt64 = message.sentTimestamp,
            (try? ClosedGroup
                .filter(id: groupSessionId.hexString)
                .select(.groupIdentityPrivateKey)
                .asRequest(of: Data.self)
                .fetchOne(db)) != nil
        else { throw MessageReceiverError.invalidMessage }
        
        // Trigger this removal in a separate process because it requires a number of requests to be made
        db.afterNextTransactionNested { _ in
            MessageSender
                .removeGroupMembers(
                    groupSessionId: groupSessionId.hexString,
                    memberIds: [sender],
                    removeTheirMessages: false,
                    sendMemberChangedMessage: false,
                    changeTimestampMs: Int64(sentTimestampMs),
                    using: dependencies
                )
                .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
                .sinkUntilComplete()
        }
    }
    
    private static func handleGroupMemberLeftNotification(
        _ db: Database,
        groupSessionId: SessionId,
        message: GroupUpdateMemberLeftNotificationMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let sender: String = message.sender,
            let sentTimestampMs: UInt64 = message.sentTimestamp
        else { throw MessageReceiverError.invalidMessage }
        
        // Add a record of the specific change to the conversation (the actual change is handled via
        // config messages so these are only for record purposes)
        _ = try Interaction(
            threadId: groupSessionId.hexString,
            threadVariant: .group,
            authorId: sender,
            variant: .infoGroupMembersUpdated,
            body: ClosedGroup.MessageInfo
                .memberLeft(
                    name: (
                        (try? Profile.fetchOne(db, id: sender)?.displayName(for: .group)) ??
                        Profile.truncated(id: sender, truncating: .middle)
                    )
                )
                .infoString(using: dependencies),
            timestampMs: Int64(sentTimestampMs),
            using: dependencies
        ).inserted(db)
    }
    
    private static func handleGroupInviteResponse(
        _ db: Database,
        groupSessionId: SessionId,
        message: GroupUpdateInviteResponseMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let sender: String = message.sender,
            let sentTimestampMs: UInt64 = message.sentTimestamp,
            message.isApproved  // Only process the invite response if it was an approval
        else { throw MessageReceiverError.invalidMessage }
        
        // Update profile if needed
        if let profile = message.profile {
            try Profile.updateIfNeeded(
                db,
                publicKey: sender,
                name: profile.displayName,
                blocksCommunityMessageRequests: profile.blocksCommunityMessageRequests,
                displayPictureUpdate: {
                    guard
                        let profilePictureUrl: String = profile.profilePictureUrl,
                        let profileKey: Data = profile.profileKey
                    else { return .remove }
                    
                    return .updateTo(
                        url: profilePictureUrl,
                        key: profileKey,
                        fileName: nil
                    )
                }(),
                sentTimestamp: TimeInterval(Double(sentTimestampMs) / 1000),
                calledFromConfig: nil,
                using: dependencies
            )
        }
        
        // Update the member approval state
        try MessageReceiver.updateMemberApprovalStatusIfNeeded(
            db,
            senderSessionId: sender,
            groupSessionIdHexString: groupSessionId.hexString,
            using: dependencies
        )
    }
    
    private static func handleGroupDeleteMemberContent(
        _ db: Database,
        groupSessionId: SessionId,
        message: GroupUpdateDeleteMemberContentMessage,
        using dependencies: Dependencies
    ) throws {
        guard let sentTimestampMs: UInt64 = message.sentTimestamp else { throw MessageReceiverError.invalidMessage }
        
        let memberSessionIdsToRemove: [String]
        let messageHashesToRemove: [String]
        let messageHashesToDeleteFromServer: [String]
        
        switch (message.adminSignature, message.sender) {
            case (.some(let adminSignature), _):
                guard
                    Authentication.verify(
                        signature: adminSignature,
                        publicKey: groupSessionId.publicKey,
                        verificationBytes: GroupUpdateDeleteMemberContentMessage.generateVerificationBytes(
                            memberSessionIds: message.memberSessionIds,
                            messageHashes: message.messageHashes,
                            timestampMs: sentTimestampMs
                        ),
                        using: dependencies
                    )
                else { throw MessageReceiverError.invalidMessage }
                
                /// Admins can remove anything so just use the values included in the message, they will have already deleted the messages
                /// from the server as well so we can just leave that empty
                memberSessionIdsToRemove = message.memberSessionIds
                messageHashesToRemove = message.messageHashes
                messageHashesToDeleteFromServer = []
                
            case (.none, .some(let sender)):
                /// Members can only remove messages they sent so filter the values included to only include values that match the sender
                memberSessionIdsToRemove = message.memberSessionIds.filter { $0 == sender }
                messageHashesToRemove = try Interaction
                    .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                    .filter(Interaction.Columns.authorId == sender)
                    .filter(message.messageHashes.asSet().contains(Interaction.Columns.serverHash))
                    .filter(Interaction.Columns.timestampMs < sentTimestampMs)
                    .select(.serverHash)
                    .asRequest(of: String.self)
                    .fetchAll(db)
                messageHashesToDeleteFromServer = try Interaction
                    .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                    .filter(memberSessionIdsToRemove.asSet().contains(Interaction.Columns.authorId))
                    .filter(Interaction.Columns.timestampMs < sentTimestampMs)
                    .select(.serverHash)
                    .asRequest(of: String.self)
                    .fetchAll(db)
                    .appending(contentsOf: messageHashesToRemove)
                
            case (.none, .none): throw MessageReceiverError.invalidMessage
        }
        
        /// Remove all messages sent but any of the `memberSessionIds`
        if !memberSessionIdsToRemove.isEmpty {
            try Interaction
                .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                .filter(memberSessionIdsToRemove.asSet().contains(Interaction.Columns.authorId))
                .filter(Interaction.Columns.timestampMs < sentTimestampMs)
                .deleteAll(db)
        }
        
        /// Remove all messages in the `messageHashes`
        if !messageHashesToRemove.isEmpty {
            try Interaction
                .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                .filter(messageHashesToRemove.asSet().contains(Interaction.Columns.serverHash))
                .filter(Interaction.Columns.timestampMs < sentTimestampMs)
                .deleteAll(db)
        }
        
        /// If the message wasn't sent by an admin and the current user is an admin then we want to try to delete the
        /// messages from the swarm as well
        guard
            !messageHashesToDeleteFromServer.isEmpty,
            LibSession.isAdmin(groupSessionId: groupSessionId, using: dependencies),
            let authMethod: AuthenticationMethod = try? Authentication.with(
                db,
                swarmPublicKey: groupSessionId.hexString,
                using: dependencies
            )
        else { return }
        
        try? SnodeAPI
            .preparedDeleteMessages(
                serverHashes: messageHashesToDeleteFromServer,
                requireSuccessfulDeletion: false,
                authMethod: authMethod,
                using: dependencies
            )
            .send(using: dependencies)
            .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
            .sinkUntilComplete()
    }
    
    // MARK: - LibSession Encrypted Messages
    
    /// Logic for handling the `groupKicked` `LibSessionMessage`, this message should only be processed if it was
    /// sent after the user joined the group (while unlikely, it's possible to receive this message when re-joining a group after
    /// previously being kicked in which case we don't want to delete the data)
    ///
    /// **Note:** Admins can't be removed from a group so this only clears the `authData`
    internal static func handleGroupDelete(
        _ db: Database,
        groupSessionId: SessionId,
        plaintext: Data,
        using dependencies: Dependencies
    ) throws {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        /// Ignore the message if the `memberSessionIds` doesn't contain the current users session id,
        /// it was sent before the user joined the group or if the `adminSignature` isn't valid
        guard
            let (memberId, keysGen): (SessionId, Int) = try? LibSessionMessage.groupKicked(plaintext: plaintext),
            let currentKeysGen: Int = try? LibSession.currentGeneration(
                groupSessionId: groupSessionId,
                using: dependencies
            ),
            memberId == userSessionId,
            keysGen >= currentKeysGen
        else { throw MessageReceiverError.invalidMessage }
        
        /// Update the name of the group in `USER_GROUPS` so that if the user doesn't delete the group and links a new device, the group will have
        /// the same name as on the current device
        let groupName: String? = try? dependencies[cache: .libSession]
            .config(for: .groupInfo, sessionId: groupSessionId)
            .wrappedValue
            .map { config in try LibSession.groupName(in: config) }
        
        switch groupName {
            case .none: Log.warn("[MessageReceiver] Failed to update group name before being kicked.")
            case .some(let name):
                try dependencies[cache: .libSession]
                    .config(for: .userGroups, sessionId: userSessionId)
                    .wrappedValue
                    .map { config in
                        try LibSession.upsert(
                            groups: [
                                LibSession.GroupUpdateInfo(
                                    groupSessionId: groupSessionId.hexString,
                                    name: name
                                )
                            ],
                            in: config,
                            using: dependencies
                        )
                    }
        }
        
        /// Delete the group data (if the group is a message request then delete it entirely, otherwise we want to keep a shell of group around because
        /// the UX of conversations randomly disappearing isn't great)
        let isInvite: Bool = (try? ClosedGroup
            .filter(id: groupSessionId.hexString)
            .select(ClosedGroup.Columns.invited)
            .asRequest(of: Bool.self)
            .fetchOne(db))
            .defaulting(to: false)
        
        try ClosedGroup.removeData(
            db,
            threadIds: [groupSessionId.hexString],
            dataToRemove: {
                guard !isInvite else { return .allData }
                
                return [
                    .poller, .pushNotifications, .messages, .members,
                    .encryptionKeys, .authDetails, .libSessionState
                ]
            }(),
            calledFromConfig: nil,
            cacheToRemoveStateFrom: nil,
            using: dependencies
        )
    }
    
    // MARK: - Shared
    
    internal static func processGroupInvite(
        _ db: Database,
        sender: String,
        serverHash: String?,
        sentTimestampMs: Int64,
        groupSessionId: SessionId,
        groupName: String,
        memberAuthData: Data?,
        groupIdentityPrivateKey: Data?,
        using dependencies: Dependencies
    ) throws {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        /// With updated groups they should be considered message requests (`invited: true`) unless person sending the invitation is
        /// an approved contact of the user, this is designed to reduce spam via groups getting around message requests if users are on old
        /// or modified clients
        let inviteSenderIsApproved: Bool = {
            guard !dependencies[feature: .updatedGroupsDisableAutoApprove] else { return false }
            
            return ((try? Contact.fetchOne(db, id: sender))?.isApproved == true)
        }()
        let threadAlreadyExisted: Bool = ((try? SessionThread.exists(db, id: groupSessionId.hexString)) ?? false)
        let wasKickedFromGroup: Bool = LibSession.wasKickedFromGroup(
            groupSessionId: groupSessionId,
            using: dependencies
        )
        let initialPollPublisher: AnyPublisher<Poller.PollResult, Never> = try MessageReceiver.handleNewGroup(
            db,
            groupSessionId: groupSessionId.hexString,
            groupIdentityPrivateKey: groupIdentityPrivateKey,
            name: groupName,
            authData: memberAuthData,
            joinedAt: TimeInterval(Double(sentTimestampMs) / 1000),
            invited: !inviteSenderIsApproved,
            calledFromConfig: nil,
            cacheToLoadStateInto: nil,
            config: nil,
            using: dependencies
        )
        
        /// Add the sender as a group admin (so we can retrieve their profile details for Group Message Request UI)
        try GroupMember(
            groupId: groupSessionId.hexString,
            profileId: sender,
            role: .admin,
            roleStatus: .accepted,
            isHidden: false
        ).upsert(db)
        
        /// Now that we've added the group info into the `USER_GROUPS` config we should try to delete the original invitation/promotion
        /// from the swarm so we don't need to worry about it being reprocessed on another device if the user happens to leave or get
        /// removed from the group before another device has received it (ie. stop the group from incorrectly reappearing)
        switch serverHash {
            case .none: break
            case .some(let serverHash):
                try? SnodeAPI
                    .preparedDeleteMessages(
                        serverHashes: [serverHash],
                        requireSuccessfulDeletion: false,
                        authMethod: try Authentication.with(
                            db,
                            swarmPublicKey: userSessionId.hexString,
                            using: dependencies
                        ),
                        using: dependencies
                    )
                    .send(using: dependencies)
                    .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
                    .sinkUntilComplete()
        }
        
        /// If the thread didn't already exist, or the user had previously been kicked but has since been re-added to the group, then insert
        /// an 'invited' info message
        guard !threadAlreadyExisted || wasKickedFromGroup else { return }
        
        /// Remove any existing `infoGroupInfoInvited` interactions from the group (don't want to have a duplicate one in case
        /// the group was created via a `USER_GROUPS` config when syncing a new device)
        _ = try Interaction
            .filter(Interaction.Columns.threadId == groupSessionId.hexString)
            .filter(Interaction.Columns.variant == Interaction.Variant.infoGroupInfoInvited)
            .deleteAll(db)
        
        let interaction: Interaction = try Interaction(
            threadId: groupSessionId.hexString,
            threadVariant: .group,
            authorId: sender,
            variant: .infoGroupInfoInvited,
            body: {
                switch groupIdentityPrivateKey {
                    case .none:
                        return ClosedGroup.MessageInfo
                            .invited(
                                (try? Profile.fetchOne(db, id: sender)?.displayName(for: .group))
                                    .defaulting(to: Profile.truncated(id: sender, threadVariant: .group)),
                                groupName
                            )
                            .infoString(using: dependencies)
                    
                    case .some:
                        return ClosedGroup.MessageInfo
                            .invitedAdmin(
                                (try? Profile.fetchOne(db, id: sender)?.displayName(for: .group))
                                    .defaulting(to: Profile.truncated(id: sender, threadVariant: .group)),
                                groupName
                            )
                            .infoString(using: dependencies)
                }
            }(),
            timestampMs: sentTimestampMs,
            wasRead: dependencies[cache: .libSession].timestampAlreadyRead(
                threadId: groupSessionId.hexString,
                threadVariant: .group,
                timestampMs: sentTimestampMs,
                userSessionId: userSessionId,
                openGroup: nil
            ),
            using: dependencies
        ).inserted(db)
        
        /// Notify the user about the group message request if needed
        switch (inviteSenderIsApproved, groupIdentityPrivateKey == nil) {
            /// If the sender was approved then this group will be auto-accepted and we should send the
            /// `GroupUpdateInviteResponseMessage` to the group
            case (true, true):
                /// If we aren't creating a new thread (ie. sending a message request) then send a
                /// `GroupUpdateInviteResponseMessage` to the group (this allows other members
                /// to know that the user has joined the group)
                db.afterNextTransactionNested { _ in
                    initialPollPublisher
                        .first()
                        .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
                        .sinkUntilComplete(
                            receiveCompletion: { _ in
                                dependencies[singleton: .storage].write { db in
                                    try MessageSender.send(
                                        db,
                                        message: GroupUpdateInviteResponseMessage(
                                            isApproved: true,
                                            sentTimestamp: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                                        ),
                                        interactionId: nil,
                                        threadId: groupSessionId.hexString,
                                        threadVariant: .group,
                                        using: dependencies
                                    )
                                }
                            }
                        )
                }
                
            /// If the sender wasn't approved this is a message request so we should notify the user about the invite
            case (false, _):
                let isMainAppActive: Bool = dependencies[defaults: .appGroup, key: .isMainAppActive]
                dependencies[singleton: .notificationsManager].notifyUser(
                    db,
                    for: interaction,
                    in: try SessionThread.fetchOrCreate(
                        db,
                        id: groupSessionId.hexString,
                        variant: .group,
                        shouldBeVisible: nil,
                        calledFromConfig: nil,
                        using: dependencies
                    ),
                    applicationState: (isMainAppActive ? .active : .background)
                )
            
            /// If the sender is approved and this was an admin invitation then do nothing
            case (true, false): break
        }
    }
    
    internal static func updateMemberApprovalStatusIfNeeded(
        _ db: Database,
        senderSessionId: String,
        groupSessionIdHexString: String?,
        using dependencies: Dependencies
    ) throws {
        // Only group admins can update the member approval state
        guard
            let groupSessionId: SessionId = try? SessionId(from: groupSessionIdHexString),
            (try? ClosedGroup
                .filter(id: groupSessionId.hexString)
                .select(.groupIdentityPrivateKey)
                .asRequest(of: Data.self)
                .fetchOne(db)) != nil
        else { return }
        
        let existingMember: GroupMember? = try GroupMember
            .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
            .filter(GroupMember.Columns.profileId == senderSessionId)
            .fetchOne(db)
        
        switch existingMember?.role {
            case .none, .admin:
                // If the 'GroupMember' entry in the database doesn't exist or is an admin then
                // don't change the database as we assume it's state is correct, just update `libSession`
                // in case it didn't have the correct `invited` state (if this triggers a GROUP_MEMBERS
                // update then the database will eventually get back to a valid state)
                try LibSession.updateMemberStatus(
                    db,
                    groupSessionId: groupSessionId,
                    memberId: senderSessionId,
                    role: .standard,
                    status: .accepted,
                    using: dependencies
                )
                
            case .standard:
                guard existingMember?.roleStatus != .accepted else { return }
                
                try GroupMember
                    .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
                    .filter(GroupMember.Columns.profileId == senderSessionId)
                    .updateAllAndConfig(
                        db,
                        GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.accepted),
                        calledFromConfig: nil,
                        using: dependencies
                    )
                
            default: break  // Invalid cases
        }
    }
}
