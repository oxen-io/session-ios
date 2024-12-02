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
            let sentTimestampMs: UInt64 = message.sentTimestampMs,
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
                displayNameUpdate: .contactUpdate(profile.displayName),
                displayPictureUpdate: {
                    guard
                        let profilePictureUrl: String = profile.profilePictureUrl,
                        let profileKey: Data = profile.profileKey
                    else { return .contactRemove }
                    
                    return .contactUpdateTo(
                        url: profilePictureUrl,
                        key: profileKey,
                        fileName: nil
                    )
                }(),
                blocksCommunityMessageRequests: profile.blocksCommunityMessageRequests,
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
    
    /// This returns the `resultPublisher` for the group poller so can be ignored if we don't need to wait for the first poll to succeed
    internal static func handleNewGroup(
        _ db: Database,
        groupSessionId: String,
        groupIdentityPrivateKey: Data?,
        name: String,
        authData: Data?,
        joinedAt: TimeInterval,
        invited: Bool,
        wasKickedFromGroup: Bool,
        calledFromConfig configTriggeringChange: ConfigDump.Variant?,
        using dependencies: Dependencies
    ) throws {
        // Create the group
        try SessionThread.fetchOrCreate(
            db,
            id: groupSessionId,
            variant: .group,
            creationDateTimestamp: joinedAt,
            shouldBeVisible: true,
            calledFromConfig: configTriggeringChange,
            using: dependencies
        )
        let closedGroup: ClosedGroup = try ClosedGroup(
            threadId: groupSessionId,
            name: name,
            formationTimestamp: joinedAt,
            shouldPoll: false,  // Always false here - will be updated in `approveGroup`
            groupIdentityPrivateKey: groupIdentityPrivateKey,
            authData: authData,
            invited: invited
        ).upserted(db)
        
        if configTriggeringChange != .userGroups {
            // If we had previously been kicked from a group then we need to update the flag in UserGroups
            // so that we don't consider ourselves as kicked anymore
            if wasKickedFromGroup {
                dependencies.mutate(cache: .libSession) { cache in
                    try? cache.markAsInvited(
                        db,
                        groupSessionIds: [groupSessionId],
                        using: dependencies
                    )
                }
            }
            
            // Update libSession
            try? LibSession.add(
                db,
                groupSessionId: groupSessionId,
                groupIdentityPrivateKey: groupIdentityPrivateKey,
                name: name,
                authData: authData,
                joinedAt: joinedAt,
                invited: invited,
                using: dependencies
            )
        }
        
        /// If the group wasn't already approved, is not in the invite state and the user hasn't been kicked from it then handle the approval process
        guard !invited else { return }
        
        try ClosedGroup.approveGroupIfNeeded(
            db,
            group: closedGroup,
            calledFromConfig: configTriggeringChange,
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
            let sentTimestampMs: UInt64 = message.sentTimestampMs,
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
                displayNameUpdate: .contactUpdate(profile.displayName),
                displayPictureUpdate: {
                    guard
                        let profilePictureUrl: String = profile.profilePictureUrl,
                        let profileKey: Data = profile.profileKey
                    else { return .contactRemove }
                    
                    return .contactUpdateTo(
                        url: profilePictureUrl,
                        key: profileKey,
                        fileName: nil
                    )
                }(),
                blocksCommunityMessageRequests: profile.blocksCommunityMessageRequests,
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
        
        // Load the admin key into libSession (the users member role and status will be updated after
        // receiving the GROUP_MEMBERS config message)
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
            let sentTimestampMs: UInt64 = message.sentTimestampMs,
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
                    wasRead: dependencies.mutate(cache: .libSession) { cache in
                        cache.timestampAlreadyRead(
                            threadId: groupSessionId.hexString,
                            threadVariant: .group,
                            timestampMs: Int64(sentTimestampMs),
                            userSessionId: userSessionId,
                            openGroup: nil
                        )
                    },
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
            let sentTimestampMs: UInt64 = message.sentTimestampMs,
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
        let messageContainsCurrentUser: Bool = message.memberSessionIds.contains(userSessionId.hexString)
        let messageInfo: ClosedGroup.MessageInfo = {
            switch message.changeType {
                case .added:
                    return ClosedGroup.MessageInfo.addedUsers(
                        hasCurrentUser: messageContainsCurrentUser,
                        names: names,
                        historyShared: message.historyShared
                    )
                    
                case .removed:
                    return ClosedGroup.MessageInfo.removedUsers(
                        hasCurrentUser: messageContainsCurrentUser,
                        names: names
                    )
                    
                case .promoted:
                    return ClosedGroup.MessageInfo.promotedUsers(
                        hasCurrentUser: messageContainsCurrentUser,
                        names: names
                    )
            }
        }()
        
        /// If the message is about adding the current user then we should remove any existing `infoGroupInfoInvited` interactions
        /// from the group (don't want to have two different messages indicating the current user was added to the group)
        if messageContainsCurrentUser && message.changeType == .added {
            _ = try Interaction
                .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                .filter(Interaction.Columns.variant == Interaction.Variant.infoGroupInfoInvited)
                .deleteAll(db)
        }
        
        switch messageInfo.infoString(using: dependencies) {
            case .none: Log.warn(.messageReceiver, "Failed to encode member change info string.")
            case .some(let messageBody):
                _ = try Interaction(
                    threadId: groupSessionId.hexString,
                    threadVariant: .group,
                    authorId: sender,
                    variant: .infoGroupMembersUpdated,
                    body: messageBody,
                    timestampMs: Int64(sentTimestampMs),
                    using: dependencies
                ).inserted(db)
        }
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
            let sentTimestampMs: UInt64 = message.sentTimestampMs,
            LibSession.isAdmin(groupSessionId: groupSessionId, using: dependencies)
        else { throw MessageReceiverError.invalidMessage }
        
        // Trigger this removal in a separate process because it requires a number of requests to be made
        db.afterNextTransactionNested(using: dependencies) { _ in
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
            let sentTimestampMs: UInt64 = message.sentTimestampMs
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
                    wasCurrentUser: (sender == dependencies[cache: .general].sessionId.hexString),
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
            let sentTimestampMs: UInt64 = message.sentTimestampMs,
            message.isApproved  // Only process the invite response if it was an approval
        else { throw MessageReceiverError.invalidMessage }
        
        // Update profile if needed
        if let profile = message.profile {
            try Profile.updateIfNeeded(
                db,
                publicKey: sender,
                displayNameUpdate: .contactUpdate(profile.displayName),
                displayPictureUpdate: {
                    guard
                        let profilePictureUrl: String = profile.profilePictureUrl,
                        let profileKey: Data = profile.profileKey
                    else { return .contactRemove }
                    
                    return .contactUpdateTo(
                        url: profilePictureUrl,
                        key: profileKey,
                        fileName: nil
                    )
                }(),
                blocksCommunityMessageRequests: profile.blocksCommunityMessageRequests,
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
            profile: message.profile.map { profile in
                profile.displayName.map {
                    Profile(
                        id: sender,
                        name: $0,
                        profilePictureUrl: profile.profilePictureUrl,
                        profileEncryptionKey: profile.profileKey
                    )
                }
            },
            using: dependencies
        )
    }
    
    private static func handleGroupDeleteMemberContent(
        _ db: Database,
        groupSessionId: SessionId,
        message: GroupUpdateDeleteMemberContentMessage,
        using dependencies: Dependencies
    ) throws {
        guard let sentTimestampMs: UInt64 = message.sentTimestampMs else { throw MessageReceiverError.invalidMessage }
        
        let interactionIdsToRemove: [Int64]
        let explicitHashesToRemove: [String]
        let memberSessionIdsContainsSender: Bool = message.memberSessionIds
            .filter { !$0.isEmpty } // Just in case
            .contains(message.sender ?? "")
        
        switch (message.adminSignature, message.sender, memberSessionIdsContainsSender) {
            case (.some(let adminSignature), _, _):
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
                
                /// Find all relevant interactions to remove
                let interactionIdsForRemovedHashes: [Int64] = try Interaction
                    .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                    .filter(message.messageHashes.asSet().contains(Interaction.Columns.serverHash))
                    .filter(Interaction.Columns.timestampMs < sentTimestampMs)
                    .asRequest(of: Int64.self)
                    .fetchAll(db)
                let interactionIdsSentByRemovedSenders: [Int64] = try Interaction
                    .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                    .filter(message.memberSessionIds.asSet().contains(Interaction.Columns.authorId))
                    .filter(Interaction.Columns.timestampMs < sentTimestampMs)
                    .asRequest(of: Int64.self)
                    .fetchAll(db)
                interactionIdsToRemove = interactionIdsForRemovedHashes + interactionIdsSentByRemovedSenders
                explicitHashesToRemove = message.messageHashes
                
            case (.none, .some(let sender), true):
                /// Members can only remove messages they sent so filter the values included to only include values that match the sender
                interactionIdsToRemove = try Interaction
                    .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                    .filter(Interaction.Columns.authorId == sender)
                    .filter(Interaction.Columns.timestampMs < sentTimestampMs)
                    .select(.id)
                    .asRequest(of: Int64.self)
                    .fetchAll(db)
                explicitHashesToRemove = try Interaction
                    .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                    .filter(Interaction.Columns.authorId == sender)
                    .filter(Interaction.Columns.timestampMs < sentTimestampMs)
                    .filter(Interaction.Columns.serverHash != nil)
                    .select(.serverHash)
                    .asRequest(of: String.self)
                    .fetchAll(db)
            
            case (.none, .some(let sender), false):
                /// Members can only remove messages they sent so filter the values included to only include values that match the sender
                interactionIdsToRemove = try Interaction
                    .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                    .filter(Interaction.Columns.authorId == sender)
                    .filter(message.messageHashes.asSet().contains(Interaction.Columns.serverHash))
                    .filter(Interaction.Columns.timestampMs < sentTimestampMs)
                    .select(.id)
                    .asRequest(of: Int64.self)
                    .fetchAll(db)
                explicitHashesToRemove = try Interaction
                    .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                    .filter(Interaction.Columns.authorId == sender)
                    .filter(message.messageHashes.asSet().contains(Interaction.Columns.serverHash))
                    .filter(Interaction.Columns.timestampMs < sentTimestampMs)
                    .filter(Interaction.Columns.serverHash != nil)
                    .select(.serverHash)
                    .asRequest(of: String.self)
                    .fetchAll(db)
                
            case (.none, .none, _): throw MessageReceiverError.invalidMessage
        }
        
        /// Trigger the content deletion
        let hashes: Set<String> = try Interaction.serverHashesForDeletion(
            db,
            interactionIds: Set(interactionIdsToRemove),
            additionalServerHashesToRemove: explicitHashesToRemove
        )
        try Interaction.markAsDeleted(
            db,
            threadId: groupSessionId.hexString,
            threadVariant: .group,
            interactionIds: Set(interactionIdsToRemove),
            localOnly: false,
            using: dependencies
        )
        
        /// If the message wasn't sent by an admin and the current user is an admin then we want to try to delete the
        /// messages from the swarm as well
        guard
            !hashes.isEmpty,
            LibSession.isAdmin(groupSessionId: groupSessionId, using: dependencies),
            let authMethod: AuthenticationMethod = try? Authentication.with(
                db,
                swarmPublicKey: groupSessionId.hexString,
                using: dependencies
            )
        else { return }
        
        try? SnodeAPI
            .preparedDeleteMessages(
                serverHashes: Array(hashes),
                requireSuccessfulDeletion: false,
                authMethod: authMethod,
                using: dependencies
            )
            .send(using: dependencies)
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
        
        /// If we haven't already handled being kicked from the group then update the name of the group in `USER_GROUPS` so
        /// that if the user doesn't delete the group and links a new device, the group will have the same name as on the current device
        if !LibSession.wasKickedFromGroup(groupSessionId: groupSessionId, using: dependencies) {
            dependencies.mutate(cache: .libSession) { cache in
                let groupInfoConfig: LibSession.Config? = cache.config(for: .groupInfo, sessionId: groupSessionId)
                let userGroupsConfig: LibSession.Config? = cache.config(for: .userGroups, sessionId: userSessionId)
                let groupName: String? = try? LibSession.groupName(in: groupInfoConfig)
                
                switch groupName {
                    case .none: Log.warn(.messageReceiver, "Failed to update group name before being kicked.")
                    case .some(let name):
                        try? LibSession.upsert(
                            groups: [
                                LibSession.GroupUpdateInfo(
                                    groupSessionId: groupSessionId.hexString,
                                    name: name
                                )
                            ],
                            in: userGroupsConfig,
                            using: dependencies
                        )
                }
            }
            
            /// Mark the group as kicked in libSession
            try LibSession.markAsKicked(
                db,
                groupSessionIds: [groupSessionId.hexString],
                using: dependencies
            )
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
        try MessageReceiver.handleNewGroup(
            db,
            groupSessionId: groupSessionId.hexString,
            groupIdentityPrivateKey: groupIdentityPrivateKey,
            name: groupName,
            authData: memberAuthData,
            joinedAt: TimeInterval(Double(sentTimestampMs) / 1000),
            invited: !inviteSenderIsApproved,
            wasKickedFromGroup: wasKickedFromGroup,
            calledFromConfig: nil,
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
                db.afterNextTransaction { db in
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
            wasRead: dependencies.mutate(cache: .libSession) { cache in
                cache.timestampAlreadyRead(
                    threadId: groupSessionId.hexString,
                    threadVariant: .group,
                    timestampMs: sentTimestampMs,
                    userSessionId: userSessionId,
                    openGroup: nil
                )
            },
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
                try MessageSender.send(
                    db,
                    message: GroupUpdateInviteResponseMessage(
                        isApproved: true,
                        sentTimestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                    ),
                    interactionId: nil,
                    threadId: groupSessionId.hexString,
                    threadVariant: .group,
                    using: dependencies
                )
                
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
                        creationDateTimestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000),
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
        profile: Profile?,
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
                    profile: profile,
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
        
        // Update the member profile information in the GroupMembers config
        try LibSession.updateMemberProfile(
            db,
            groupSessionId: groupSessionId,
            memberId: senderSessionId,
            profile: profile,
            using: dependencies
        )
    }
}
