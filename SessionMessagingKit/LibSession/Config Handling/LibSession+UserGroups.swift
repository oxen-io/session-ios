// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Sodium
import SessionUtil
import SessionUtilitiesKit
import SessionSnodeKit

// MARK: - Size Restrictions

public extension LibSession {
    static var libSessionMaxGroupNameByteLength: Int { GROUP_NAME_MAX_LENGTH }
    static var libSessionMaxGroupBaseUrlByteLength: Int { COMMUNITY_BASE_URL_MAX_LENGTH }
    static var libSessionMaxGroupFullUrlByteLength: Int { COMMUNITY_FULL_URL_MAX_LENGTH }
    static var libSessionMaxCommunityRoomByteLength: Int { COMMUNITY_ROOM_MAX_LENGTH }
}

// MARK: - UserGroups Handling

internal extension LibSession {
    static let columnsRelatedToUserGroups: [ColumnExpression] = [
        ClosedGroup.Columns.name
    ]
    
    // MARK: - Incoming Changes
    
    static func handleGroupsUpdate(
        _ db: Database,
        in conf: UnsafeMutablePointer<config_object>?,
        mergeNeedsDump: Bool,
        latestConfigSentTimestampMs: Int64,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        guard mergeNeedsDump else { return }
        guard conf != nil else { throw LibSessionError.nilConfigObject }
        
        var infiniteLoopGuard: Int = 0
        var communities: [PrioritisedData<OpenGroupUrlInfo>] = []
        var legacyGroups: [LegacyGroupInfo] = []
        var community: ugroups_community_info = ugroups_community_info()
        var legacyGroup: ugroups_legacy_group_info = ugroups_legacy_group_info()
        let groupsIterator: OpaquePointer = user_groups_iterator_new(conf)
        
        while !user_groups_iterator_done(groupsIterator) {
            try LibSession.checkLoopLimitReached(&infiniteLoopGuard, for: .userGroups)
            
            if user_groups_it_is_community(groupsIterator, &community) {
                let server: String = String(libSessionVal: community.base_url)
                let roomToken: String = String(libSessionVal: community.room)
                
                communities.append(
                    PrioritisedData(
                        data: OpenGroupUrlInfo(
                            threadId: OpenGroup.idFor(roomToken: roomToken, server: server),
                            server: server,
                            roomToken: roomToken,
                            publicKey: Data(
                                libSessionVal: community.pubkey,
                                count: OpenGroup.pubkeyByteLength
                            ).toHexString()
                        ),
                        priority: community.priority
                    )
                )
            }
            else if user_groups_it_is_legacy_group(groupsIterator, &legacyGroup) {
                let groupId: String = String(libSessionVal: legacyGroup.session_id)
                let members: [String: Bool] = LibSession.memberInfo(in: &legacyGroup)
                
                legacyGroups.append(
                    LegacyGroupInfo(
                        id: groupId,
                        name: String(libSessionVal: legacyGroup.name),
                        lastKeyPair: ClosedGroupKeyPair(
                            threadId: groupId,
                            publicKey: Data(
                                libSessionVal: legacyGroup.enc_pubkey,
                                count: ClosedGroup.pubkeyByteLength
                            ),
                            secretKey: Data(
                                libSessionVal: legacyGroup.enc_seckey,
                                count: ClosedGroup.secretKeyByteLength
                            ),
                            receivedTimestamp: (TimeInterval(SnodeAPI.currentOffsetTimestampMs()) / 1000)
                        ),
                        disappearingConfig: DisappearingMessagesConfiguration
                            .defaultWith(groupId)
                            .with(
                                isEnabled: (legacyGroup.disappearing_timer > 0),
                                durationSeconds: TimeInterval(legacyGroup.disappearing_timer),
                                type: .disappearAfterSend
                            ),
                        groupMembers: members
                            .filter { _, isAdmin in !isAdmin }
                            .map { memberId, _ in
                                GroupMember(
                                    groupId: groupId,
                                    profileId: memberId,
                                    role: .standard,
                                    isHidden: false
                                )
                            },
                        groupAdmins: members
                            .filter { _, isAdmin in isAdmin }
                            .map { memberId, _ in
                                GroupMember(
                                    groupId: groupId,
                                    profileId: memberId,
                                    role: .admin,
                                    isHidden: false
                                )
                            },
                        priority: legacyGroup.priority,
                        joinedAt: legacyGroup.joined_at
                    )
                )
            }
            else {
                SNLog("Ignoring unknown conversation type when iterating through volatile conversation info update")
            }
            
            user_groups_iterator_advance(groupsIterator)
        }
        user_groups_iterator_free(groupsIterator) // Need to free the iterator
        
        // Extract all community/legacyGroup/group thread priorities
        let existingThreadInfo: [String: PriorityVisibilityInfo] = (try? SessionThread
            .select(.id, .variant, .pinnedPriority, .shouldBeVisible)
            .filter(
                [
                    SessionThread.Variant.community,
                    SessionThread.Variant.legacyGroup,
                    SessionThread.Variant.group
                ].contains(SessionThread.Columns.variant)
            )
            .asRequest(of: PriorityVisibilityInfo.self)
            .fetchAll(db))
            .defaulting(to: [])
            .reduce(into: [:]) { result, next in result[next.id] = next }
        
        // MARK: -- Handle Community Changes
        
        // Add any new communities (via the OpenGroupManager)
        communities.forEach { community in
            let successfullyAddedGroup: Bool = OpenGroupManager.shared
                .add(
                    db,
                    roomToken: community.data.roomToken,
                    server: community.data.server,
                    publicKey: community.data.publicKey,
                    calledFromConfigHandling: true
                )
            
            if successfullyAddedGroup {
                db.afterNextTransactionNested { _ in
                    OpenGroupManager.shared.performInitialRequestsAfterAdd(
                        successfullyAddedGroup: successfullyAddedGroup,
                        roomToken: community.data.roomToken,
                        server: community.data.server,
                        publicKey: community.data.publicKey,
                        calledFromConfigHandling: false
                    )
                    .subscribe(on: OpenGroupAPI.workQueue)
                    .sinkUntilComplete()
                }
            }
            
            // Set the priority if it's changed (new communities will have already been inserted at
            // this stage)
            if existingThreadInfo[community.data.threadId]?.pinnedPriority != community.priority {
                _ = try? SessionThread
                    .filter(id: community.data.threadId)
                    .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                        db,
                        SessionThread.Columns.pinnedPriority.set(to: community.priority)
                    )
            }
        }
        
        // Remove any communities which are no longer in the config
        let communityIdsToRemove: Set<String> = Set(existingThreadInfo
            .filter { $0.value.variant == .community }
            .keys)
            .subtracting(communities.map { $0.data.threadId })
        
        if !communityIdsToRemove.isEmpty {
            LibSession.kickFromConversationUIIfNeeded(removedThreadIds: Array(communityIdsToRemove))
            
            try SessionThread
                .deleteOrLeave(
                    db,
                    threadIds: Array(communityIdsToRemove),
                    threadVariant: .community,
                    groupLeaveType: .forced,
                    calledFromConfigHandling: true
                )
        }
        
        // MARK: -- Handle Legacy Group Changes
        
        let existingLegacyGroupIds: Set<String> = Set(existingThreadInfo
            .filter { $0.value.variant == .legacyGroup }
            .keys)
        let existingLegacyGroups: [String: ClosedGroup] = (try? ClosedGroup
            .fetchAll(db, ids: existingLegacyGroupIds))
            .defaulting(to: [])
            .reduce(into: [:]) { result, next in result[next.id] = next }
        let existingLegacyGroupMembers: [String: [GroupMember]] = (try? GroupMember
            .filter(existingLegacyGroupIds.contains(GroupMember.Columns.groupId))
            .fetchAll(db))
            .defaulting(to: [])
            .grouped(by: \.groupId)
        
        try legacyGroups.forEach { group in
            guard
                let name: String = group.name,
                let lastKeyPair: ClosedGroupKeyPair = group.lastKeyPair,
                let members: [GroupMember] = group.groupMembers,
                let updatedAdmins: Set<GroupMember> = group.groupAdmins?.asSet(),
                let joinedAt: Int64 = group.joinedAt
            else { return }
            
            if !existingLegacyGroupIds.contains(group.id) {
                // Add a new group if it doesn't already exist
                try MessageReceiver.handleNewClosedGroup(
                    db,
                    groupPublicKey: group.id,
                    name: name,
                    encryptionKeyPair: KeyPair(
                        publicKey: lastKeyPair.publicKey.bytes,
                        secretKey: lastKeyPair.secretKey.bytes
                    ),
                    members: members
                        .asSet()
                        .inserting(contentsOf: updatedAdmins)  // Admins should also have 'standard' member entries
                        .map { $0.profileId },
                    admins: updatedAdmins.map { $0.profileId },
                    expirationTimer: UInt32(group.disappearingConfig?.durationSeconds ?? 0),
                    formationTimestampMs: UInt64((group.joinedAt.map { $0 * 1000 } ?? latestConfigSentTimestampMs)),
                    calledFromConfigHandling: true,
                    using: dependencies
                )
            }
            else {
                // Otherwise update the existing group
                let groupChanges: [ConfigColumnAssignment] = [
                    (existingLegacyGroups[group.id]?.name == name ? nil :
                        ClosedGroup.Columns.name.set(to: name)
                    ),
                    (existingLegacyGroups[group.id]?.formationTimestamp == TimeInterval(joinedAt) ? nil :
                        ClosedGroup.Columns.formationTimestamp.set(to: TimeInterval(joinedAt))
                    )
                ].compactMap { $0 }
                
                // Apply any group changes
                if !groupChanges.isEmpty {
                    _ = try? ClosedGroup
                        .filter(id: group.id)
                        .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                            db,
                            groupChanges
                        )
                }
                
                // Add the lastKey if it doesn't already exist
                let keyPairExists: Bool = ClosedGroupKeyPair
                    .filter(ClosedGroupKeyPair.Columns.threadKeyPairHash == lastKeyPair.threadKeyPairHash)
                    .isNotEmpty(db)
                
                if !keyPairExists {
                    try lastKeyPair.insert(db)
                }
                
                // Update the disappearing messages timer
                let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
                    .fetchOne(db, id: group.id)
                    .defaulting(to: DisappearingMessagesConfiguration.defaultWith(group.id))
                
                if let updatedConfig = group.disappearingConfig, localConfig != updatedConfig {
                    try updatedConfig
                        .saved(db)
                        .clearUnrelatedControlMessages(
                            db,
                            threadVariant: .legacyGroup
                        )
                }
                
                // Update the members
                let updatedMembers: Set<GroupMember> = members
                    .appending(
                        contentsOf: updatedAdmins.map { admin in
                            GroupMember(
                                groupId: admin.groupId,
                                profileId: admin.profileId,
                                role: .standard,
                                isHidden: false
                            )
                        }
                    )
                    .asSet()
                
                if
                    let existingMembers: Set<GroupMember> = existingLegacyGroupMembers[group.id]?
                        .filter({ $0.role == .standard || $0.role == .zombie })
                        .asSet(),
                    existingMembers != updatedMembers
                {
                    // Add in any new members and remove any removed members
                    try updatedMembers.forEach { try $0.save(db) }
                    try existingMembers
                        .filter { !updatedMembers.contains($0) }
                        .forEach { member in
                            try GroupMember
                                .filter(
                                    GroupMember.Columns.groupId == group.id &&
                                    GroupMember.Columns.profileId == member.profileId && (
                                        GroupMember.Columns.role == GroupMember.Role.standard ||
                                        GroupMember.Columns.role == GroupMember.Role.zombie
                                    )
                                )
                                .deleteAll(db)
                        }
                }

                if
                    let existingAdmins: Set<GroupMember> = existingLegacyGroupMembers[group.id]?
                        .filter({ $0.role == .admin })
                        .asSet(),
                    existingAdmins != updatedAdmins
                {
                    // Add in any new admins and remove any removed admins
                    try updatedAdmins.forEach { try $0.save(db) }
                    try existingAdmins
                        .filter { !updatedAdmins.contains($0) }
                        .forEach { member in
                            try GroupMember
                                .filter(
                                    GroupMember.Columns.groupId == group.id &&
                                    GroupMember.Columns.profileId == member.profileId &&
                                    GroupMember.Columns.role == GroupMember.Role.admin
                                )
                                .deleteAll(db)
                        }
                }
            }
            
            // Make any thread-specific changes if needed
            if existingThreadInfo[group.id]?.pinnedPriority != group.priority {
                _ = try? SessionThread
                    .filter(id: group.id)
                    .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                        db,
                        SessionThread.Columns.pinnedPriority.set(to: group.priority)
                    )
            }
        }
        
        // Remove any legacy groups which are no longer in the config
        let legacyGroupIdsToRemove: Set<String> = existingLegacyGroupIds
            .subtracting(legacyGroups.map { $0.id })
        
        if !legacyGroupIdsToRemove.isEmpty {
            LibSession.kickFromConversationUIIfNeeded(removedThreadIds: Array(legacyGroupIdsToRemove))
            
            try SessionThread
                .deleteOrLeave(
                    db,
                    threadIds: Array(legacyGroupIdsToRemove),
                    threadVariant: .legacyGroup,
                    groupLeaveType: .forced,
                    calledFromConfigHandling: true
                )
        }
        
        // MARK: -- Handle Group Changes
        
    }
    
    fileprivate static func memberInfo(in legacyGroup: UnsafeMutablePointer<ugroups_legacy_group_info>) -> [String: Bool] {
        let membersIt: OpaquePointer = ugroups_legacy_members_begin(legacyGroup)
        var members: [String: Bool] = [:]
        var maybeMemberSessionId: UnsafePointer<CChar>? = nil
        var memberAdmin: Bool = false

        while ugroups_legacy_members_next(membersIt, &maybeMemberSessionId, &memberAdmin) {
            guard let memberSessionId: UnsafePointer<CChar> = maybeMemberSessionId else {
                continue
            }

            members[String(cString: memberSessionId)] = memberAdmin
        }
        
        return members
    }
    
    // MARK: - Outgoing Changes
    
    static func upsert(
        legacyGroups: [LegacyGroupInfo],
        in conf: UnsafeMutablePointer<config_object>?
    ) throws {
        guard conf != nil else { throw LibSessionError.nilConfigObject }
        guard !legacyGroups.isEmpty else { return }
        
        try legacyGroups
            .forEach { legacyGroup in
                var cGroupId: [CChar] = try legacyGroup.id.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                guard let userGroup: UnsafeMutablePointer<ugroups_legacy_group_info> = user_groups_get_or_construct_legacy_group(conf, &cGroupId) else {
                    /// It looks like there are some situations where this object might not get created correctly (and
                    /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
                    throw LibSessionError(
                        conf,
                        fallbackError: .getOrConstructFailedUnexpectedly,
                        logMessage: "Unable to upsert legacy group conversation to LibSession"
                    )
                }
                
                // Assign all properties to match the updated group (if there is one)
                if let updatedName: String = legacyGroup.name {
                    userGroup.pointee.name = updatedName.toLibSession()
                    
                    // Store the updated group (needs to happen before variables go out of scope)
                    user_groups_set_legacy_group(conf, userGroup)
                    try LibSessionError.throwIfNeeded(conf) { ugroups_legacy_group_free(userGroup) }
                }
                
                if let lastKeyPair: ClosedGroupKeyPair = legacyGroup.lastKeyPair {
                    userGroup.pointee.enc_pubkey = lastKeyPair.publicKey.toLibSession()
                    userGroup.pointee.enc_seckey = lastKeyPair.secretKey.toLibSession()
                    userGroup.pointee.have_enc_keys = true
                    
                    // Store the updated group (needs to happen before variables go out of scope)
                    user_groups_set_legacy_group(conf, userGroup)
                    try LibSessionError.throwIfNeeded(conf) { ugroups_legacy_group_free(userGroup) }
                }
                
                // Assign all properties to match the updated disappearing messages config (if there is one)
                if let updatedConfig: DisappearingMessagesConfiguration = legacyGroup.disappearingConfig {
                    userGroup.pointee.disappearing_timer = (!updatedConfig.isEnabled ? 0 :
                        Int64(floor(updatedConfig.durationSeconds))
                    )
                    
                    user_groups_set_legacy_group(conf, userGroup)
                    try LibSessionError.throwIfNeeded(conf) { ugroups_legacy_group_free(userGroup) }
                }
                
                // Add/Remove the group members and admins
                let existingMembers: [String: Bool] = {
                    guard legacyGroup.groupMembers != nil || legacyGroup.groupAdmins != nil else { return [:] }
                    
                    return LibSession.memberInfo(in: userGroup)
                }()
                
                if let groupMembers: [GroupMember] = legacyGroup.groupMembers {
                    // Need to make sure we remove any admins before adding them here otherwise we will
                    // overwrite the admin permission to be a standard user permission
                    let memberIds: Set<String> = groupMembers
                        .map { $0.profileId }
                        .asSet()
                        .subtracting(legacyGroup.groupAdmins.defaulting(to: []).map { $0.profileId }.asSet())
                    let existingMemberIds: Set<String> = Array(existingMembers
                        .filter { _, isAdmin in !isAdmin }
                        .keys)
                        .asSet()
                    let membersIdsToAdd: Set<String> = memberIds.subtracting(existingMemberIds)
                    let membersIdsToRemove: Set<String> = existingMemberIds.subtracting(memberIds)
                    
                    try membersIdsToAdd.forEach { memberId in
                        var cProfileId: [CChar] = try memberId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                        ugroups_legacy_member_add(userGroup, &cProfileId, false)
                    }
                    
                    try membersIdsToRemove.forEach { memberId in
                        var cProfileId: [CChar] = try memberId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                        ugroups_legacy_member_remove(userGroup, &cProfileId)
                    }
                }
                
                if let groupAdmins: [GroupMember] = legacyGroup.groupAdmins {
                    let adminIds: Set<String> = groupAdmins.map { $0.profileId }.asSet()
                    let existingAdminIds: Set<String> = Array(existingMembers
                        .filter { _, isAdmin in isAdmin }
                        .keys)
                        .asSet()
                    let adminIdsToAdd: Set<String> = adminIds.subtracting(existingAdminIds)
                    let adminIdsToRemove: Set<String> = existingAdminIds.subtracting(adminIds)
                    
                    try adminIdsToAdd.forEach { adminId in
                        var cProfileId: [CChar] = try adminId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                        ugroups_legacy_member_add(userGroup, &cProfileId, true)
                    }
                    
                    try adminIdsToRemove.forEach { adminId in
                        var cProfileId: [CChar] = try adminId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                        ugroups_legacy_member_remove(userGroup, &cProfileId)
                    }
                }
                
                if let joinedAt: Int64 = legacyGroup.joinedAt {
                    userGroup.pointee.joined_at = joinedAt
                }
                
                // Store the updated group (can't be sure if we made any changes above)
                userGroup.pointee.priority = (legacyGroup.priority ?? userGroup.pointee.priority)
                
                // Note: Need to free the legacy group pointer
                user_groups_set_free_legacy_group(conf, userGroup)
                try LibSessionError.throwIfNeeded(conf)
            }
    }
    
    static func upsert(
        communities: [CommunityInfo],
        in conf: UnsafeMutablePointer<config_object>?
    ) throws {
        guard conf != nil else { throw LibSessionError.nilConfigObject }
        guard !communities.isEmpty else { return }
        
        try communities
            .forEach { community in
                guard
                    var cBaseUrl: [CChar] = community.urlInfo.server.cString(using: .utf8),
                    var cRoom: [CChar] = community.urlInfo.roomToken.cString(using: .utf8)
                else {
                    SNLog("Unable to upsert community conversation to LibSession: \(LibSessionError.invalidCConversion)")
                    throw LibSessionError.invalidCConversion
                }
                
                var cPubkey: [UInt8] = Array(Data(hex: community.urlInfo.publicKey))
                var userCommunity: ugroups_community_info = ugroups_community_info()
                
                guard user_groups_get_or_construct_community(conf, &userCommunity, &cBaseUrl, &cRoom, &cPubkey) else {
                    /// It looks like there are some situations where this object might not get created correctly (and
                    /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
                    throw LibSessionError(
                        conf,
                        fallbackError: .getOrConstructFailedUnexpectedly,
                        logMessage: "Unable to upsert community conversation to LibSession"
                    )
                }
                
                userCommunity.priority = (community.priority ?? userCommunity.priority)
                user_groups_set_community(conf, &userCommunity)
            }
    }
}

// MARK: - External Outgoing Changes

public extension LibSession {
    
    // MARK: -- Communities
    
    static func add(
        _ db: Database,
        server: String,
        rootToken: String,
        publicKey: String
    ) throws {
        try LibSession.performAndPushChange(
            db,
            for: .userGroups,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            try LibSession.upsert(
                communities: [
                    CommunityInfo(
                        urlInfo: OpenGroupUrlInfo(
                            threadId: OpenGroup.idFor(roomToken: rootToken, server: server),
                            server: server,
                            roomToken: rootToken,
                            publicKey: publicKey
                        )
                    )
                ],
                in: conf
            )
        }
    }
    
    static func remove(_ db: Database, server: String, roomToken: String) throws {
        try LibSession.performAndPushChange(
            db,
            for: .userGroups,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            var cBaseUrl: [CChar] = try server.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
            var cRoom: [CChar] = try roomToken.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
            
            // Don't care if the community doesn't exist
            user_groups_erase_community(conf, &cBaseUrl, &cRoom)
        }
        
        // Remove the volatile info as well
        try LibSession.remove(
            db,
            volatileCommunityInfo: [
                OpenGroupUrlInfo(
                    threadId: OpenGroup.idFor(roomToken: roomToken, server: server),
                    server: server,
                    roomToken: roomToken,
                    publicKey: ""
                )
            ]
        )
    }
    
    // MARK: -- Legacy Group Changes
    
    static func add(
        _ db: Database,
        groupPublicKey: String,
        name: String,
        latestKeyPairPublicKey: Data,
        latestKeyPairSecretKey: Data,
        latestKeyPairReceivedTimestamp: TimeInterval,
        disappearingConfig: DisappearingMessagesConfiguration,
        members: Set<String>,
        admins: Set<String>
    ) throws {
        try LibSession.performAndPushChange(
            db,
            for: .userGroups,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            guard conf != nil else { throw LibSessionError.nilConfigObject }
            
            var cGroupId: [CChar] = try groupPublicKey.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
            let userGroup: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf, &cGroupId)
            
            // Need to make sure the group doesn't already exist (otherwise we will end up overriding the
            // content which could revert newer changes since this can be triggered from other 'NEW' messages
            // coming in from the legacy group swarm)
            guard userGroup == nil else {
                ugroups_legacy_group_free(userGroup)
                try LibSessionError.throwIfNeeded(conf)
                return
            }
            
            try LibSession.upsert(
                legacyGroups: [
                    LegacyGroupInfo(
                        id: groupPublicKey,
                        name: name,
                        lastKeyPair: ClosedGroupKeyPair(
                            threadId: groupPublicKey,
                            publicKey: latestKeyPairPublicKey,
                            secretKey: latestKeyPairSecretKey,
                            receivedTimestamp: latestKeyPairReceivedTimestamp
                        ),
                        disappearingConfig: disappearingConfig,
                        groupMembers: members
                            .map { memberId in
                                GroupMember(
                                    groupId: groupPublicKey,
                                    profileId: memberId,
                                    role: .standard,
                                    isHidden: false
                                )
                            },
                        groupAdmins: admins
                            .map { memberId in
                                GroupMember(
                                    groupId: groupPublicKey,
                                    profileId: memberId,
                                    role: .admin,
                                    isHidden: false
                                )
                            }
                    )
                ],
                in: conf
            )
        }
    }
    
    static func update(
        _ db: Database,
        groupPublicKey: String,
        name: String? = nil,
        latestKeyPair: ClosedGroupKeyPair? = nil,
        disappearingConfig: DisappearingMessagesConfiguration? = nil,
        members: Set<String>? = nil,
        admins: Set<String>? = nil
    ) throws {
        try LibSession.performAndPushChange(
            db,
            for: .userGroups,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            try LibSession.upsert(
                legacyGroups: [
                    LegacyGroupInfo(
                        id: groupPublicKey,
                        name: name,
                        lastKeyPair: latestKeyPair,
                        disappearingConfig: disappearingConfig,
                        groupMembers: members?
                            .map { memberId in
                                GroupMember(
                                    groupId: groupPublicKey,
                                    profileId: memberId,
                                    role: .standard,
                                    isHidden: false
                                )
                            },
                        groupAdmins: admins?
                            .map { memberId in
                                GroupMember(
                                    groupId: groupPublicKey,
                                    profileId: memberId,
                                    role: .admin,
                                    isHidden: false
                                )
                            }
                    )
                ],
                in: conf
            )
        }
    }
    
    static func batchUpdate(
        _ db: Database,
        disappearingConfigs: [DisappearingMessagesConfiguration]
    ) throws {
        try LibSession.performAndPushChange(
            db,
            for: .userGroups,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            try LibSession.upsert(
                legacyGroups: disappearingConfigs.map {
                    LegacyGroupInfo(
                        id: $0.id,
                        disappearingConfig: $0
                    )
                },
                in: conf
            )
        }
    }
    
    static func remove(_ db: Database, legacyGroupIds: [String]) throws {
        guard !legacyGroupIds.isEmpty else { return }
        
        try LibSession.performAndPushChange(
            db,
            for: .userGroups,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            legacyGroupIds.forEach { threadId in
                guard var cGroupId: [CChar] = threadId.cString(using: .utf8) else { return }
                
                // Don't care if the group doesn't exist
                user_groups_erase_legacy_group(conf, &cGroupId)
            }
        }
        
        // Remove the volatile info as well
        try LibSession.remove(db, volatileLegacyGroupIds: legacyGroupIds)
    }
    
    // MARK: -- Group Changes
    
    static func remove(_ db: Database, groupIds: [String]) throws {
        guard !groupIds.isEmpty else { return }
        
    }
}

// MARK: - LegacyGroupInfo

extension LibSession {
    struct LegacyGroupInfo: Decodable, FetchableRecord, ColumnExpressible {
        private static let threadIdKey: SQL = SQL(stringLiteral: CodingKeys.threadId.stringValue)
        private static let nameKey: SQL = SQL(stringLiteral: CodingKeys.name.stringValue)
        private static let lastKeyPairKey: SQL = SQL(stringLiteral: CodingKeys.lastKeyPair.stringValue)
        private static let disappearingConfigKey: SQL = SQL(stringLiteral: CodingKeys.disappearingConfig.stringValue)
        private static let priorityKey: SQL = SQL(stringLiteral: CodingKeys.priority.stringValue)
        private static let joinedAtKey: SQL = SQL(stringLiteral: CodingKeys.joinedAt.stringValue)
        
        typealias Columns = CodingKeys
        enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case threadId
            case name
            case lastKeyPair
            case disappearingConfig
            case groupMembers
            case groupAdmins
            case priority
            case joinedAt = "formationTimestamp"
        }
        
        var id: String { threadId }
        
        let threadId: String
        let name: String?
        let lastKeyPair: ClosedGroupKeyPair?
        let disappearingConfig: DisappearingMessagesConfiguration?
        let groupMembers: [GroupMember]?
        let groupAdmins: [GroupMember]?
        let priority: Int32?
        let joinedAt: Int64?
        
        init(
            id: String,
            name: String? = nil,
            lastKeyPair: ClosedGroupKeyPair? = nil,
            disappearingConfig: DisappearingMessagesConfiguration? = nil,
            groupMembers: [GroupMember]? = nil,
            groupAdmins: [GroupMember]? = nil,
            priority: Int32? = nil,
            joinedAt: Int64? = nil
        ) {
            self.threadId = id
            self.name = name
            self.lastKeyPair = lastKeyPair
            self.disappearingConfig = disappearingConfig
            self.groupMembers = groupMembers
            self.groupAdmins = groupAdmins
            self.priority = priority
            self.joinedAt = joinedAt
        }
        
        static func fetchAll(_ db: Database) throws -> [LegacyGroupInfo] {
            let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
            let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
            let keyPair: TypedTableAlias<ClosedGroupKeyPair> = TypedTableAlias()
            
            let prefixLiteral: SQL = SQL(stringLiteral: "\(SessionId.Prefix.standard.rawValue)%")
            let keyPairThreadIdColumnLiteral: SQL = SQL(stringLiteral: ClosedGroupKeyPair.Columns.threadId.name)
            let receivedTimestampColumnLiteral: SQL = SQL(stringLiteral: ClosedGroupKeyPair.Columns.receivedTimestamp.name)
            let threadIdColumnLiteral: SQL = SQL(stringLiteral: DisappearingMessagesConfiguration.Columns.threadId.name)
            
            /// **Note:** The `numColumnsBeforeTypes` value **MUST** match the number of fields before
            /// the `LegacyGroupInfo.lastKeyPairKey` entry below otherwise the query will fail to
            /// parse and might throw
            ///
            /// Explicitly set default values for the fields ignored for search results
            let numColumnsBeforeTypes: Int = 4
            
            let request: SQLRequest<LegacyGroupInfo> = """
                SELECT
                    \(closedGroup[.threadId]) AS \(LegacyGroupInfo.threadIdKey),
                    \(closedGroup[.name]) AS \(LegacyGroupInfo.nameKey),
                    \(closedGroup[.formationTimestamp]) AS \(LegacyGroupInfo.joinedAtKey),
                    \(thread[.pinnedPriority]) AS \(LegacyGroupInfo.priorityKey),
                    \(LegacyGroupInfo.lastKeyPairKey).*,
                    \(LegacyGroupInfo.disappearingConfigKey).*
                
                FROM \(ClosedGroup.self)
                JOIN \(SessionThread.self) ON \(thread[.id]) = \(closedGroup[.threadId])
                LEFT JOIN (
                    SELECT
                        \(keyPair[.threadId]),
                        \(keyPair[.publicKey]),
                        \(keyPair[.secretKey]),
                        MAX(\(keyPair[.receivedTimestamp])) AS \(receivedTimestampColumnLiteral),
                        \(keyPair[.threadKeyPairHash])
                    FROM \(ClosedGroupKeyPair.self)
                    GROUP BY \(keyPair[.threadId])
                ) AS \(LegacyGroupInfo.lastKeyPairKey) ON \(LegacyGroupInfo.lastKeyPairKey).\(keyPairThreadIdColumnLiteral) = \(closedGroup[.threadId])
                LEFT JOIN \(DisappearingMessagesConfiguration.self) AS \(LegacyGroupInfo.disappearingConfigKey) ON \(LegacyGroupInfo.disappearingConfigKey).\(threadIdColumnLiteral) = \(closedGroup[.threadId])
                
                WHERE \(SQL("\(closedGroup[.threadId]) LIKE '\(prefixLiteral)'"))
            """
            
            let legacyGroupInfoNoMembers: [LegacyGroupInfo] = try request
                .adapted { db in
                    let adapters = try splittingRowAdapters(columnCounts: [
                        numColumnsBeforeTypes,
                        ClosedGroupKeyPair.numberOfSelectedColumns(db),
                        DisappearingMessagesConfiguration.numberOfSelectedColumns(db)
                    ])
                    
                    return ScopeAdapter([
                        CodingKeys.lastKeyPair.stringValue: adapters[1],
                        CodingKeys.disappearingConfig.stringValue: adapters[2]
                    ])
                }
                .fetchAll(db)
            let legacyGroupIds: [String] = legacyGroupInfoNoMembers.map { $0.threadId }
            let allLegacyGroupMembers: [String: [GroupMember]] = try GroupMember
                .filter(legacyGroupIds.contains(GroupMember.Columns.groupId))
                .fetchAll(db)
                .grouped(by: \.groupId)
            
            return legacyGroupInfoNoMembers
                .map { nonMemberGroup in
                    LegacyGroupInfo(
                        id: nonMemberGroup.id,
                        name: nonMemberGroup.name,
                        lastKeyPair: nonMemberGroup.lastKeyPair,
                        disappearingConfig: nonMemberGroup.disappearingConfig,
                        groupMembers: allLegacyGroupMembers[nonMemberGroup.id]?
                            .filter { $0.role == .standard || $0.role == .zombie },
                        groupAdmins: allLegacyGroupMembers[nonMemberGroup.id]?
                            .filter { $0.role == .admin },
                        priority: nonMemberGroup.priority,
                        joinedAt: nonMemberGroup.joinedAt
                    )
                }
        }
    }
    
    struct CommunityInfo {
        let urlInfo: OpenGroupUrlInfo
        let priority: Int32?
        
        init(
            urlInfo: OpenGroupUrlInfo,
            priority: Int32? = nil
        ) {
            self.urlInfo = urlInfo
            self.priority = priority
        }
    }
    
    fileprivate struct GroupThreadData {
        let communities: [PrioritisedData<LibSession.OpenGroupUrlInfo>]
        let legacyGroups: [PrioritisedData<LegacyGroupInfo>]
        let groups: [PrioritisedData<String>]
    }
    
    fileprivate struct PrioritisedData<T> {
        let data: T
        let priority: Int32
    }
}
