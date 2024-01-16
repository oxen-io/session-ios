// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit
import SessionSnodeKit

// MARK: - Size Restrictions

public extension LibSession {
    static var sizeMaxGroupNameBytes: Int { GROUP_NAME_MAX_LENGTH }
    static var sizeMaxCommunityBaseUrlBytes: Int { COMMUNITY_BASE_URL_MAX_LENGTH }
    static var sizeMaxCommunityFullUrlBytes: Int { COMMUNITY_FULL_URL_MAX_LENGTH }
    static var sizeMaxCommunityRoomBytes: Int { COMMUNITY_ROOM_MAX_LENGTH }
 
    static var sizeCommunityPubkeyBytes: Int { 32 }
    static var sizeLegacyGroupPubkeyBytes: Int { 32 }
    static var sizeLegacyGroupSecretKeyBytes: Int { 32 }
    static var sizeGroupSecretKeyBytes: Int { 64 }
    static var sizeGroupAuthDataBytes: Int { 100 }
}

// MARK: - UserGroups Handling

internal extension LibSession {
    static let columnsRelatedToUserGroups: [ColumnExpression] = [
        ClosedGroup.Columns.name,
        ClosedGroup.Columns.authData,
        ClosedGroup.Columns.groupIdentityPrivateKey
    ]
    
    // MARK: - Incoming Changes
    
    static func handleUserGroupsUpdate(
        _ db: Database,
        in config: Config?,
        serverTimestampMs: Int64,
        using dependencies: Dependencies
    ) throws {
        guard config.needsDump(using: dependencies) else { return }
        guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
        
        var infiniteLoopGuard: Int = 0
        var communities: [PrioritisedData<OpenGroupUrlInfo>] = []
        var legacyGroups: [LegacyGroupInfo] = []
        var groups: [GroupInfo] = []
        var community: ugroups_community_info = ugroups_community_info()
        var legacyGroup: ugroups_legacy_group_info = ugroups_legacy_group_info()
        var group: ugroups_group_info = ugroups_group_info()
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
                                count: LibSession.sizeCommunityPubkeyBytes
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
                                count: LibSession.sizeLegacyGroupPubkeyBytes
                            ),
                            secretKey: Data(
                                libSessionVal: legacyGroup.enc_seckey,
                                count: LibSession.sizeLegacyGroupSecretKeyBytes
                            ),
                            receivedTimestamp: TimeInterval(
                                (Double(SnodeAPI.currentOffsetTimestampMs(using: dependencies)) / 1000)
                            )
                        ),
                        disappearingConfig: DisappearingMessagesConfiguration
                            .defaultWith(groupId)
                            .with(
                                isEnabled: (legacyGroup.disappearing_timer > 0),
                                durationSeconds: TimeInterval(legacyGroup.disappearing_timer),
                                type: .disappearAfterSend,
                                lastChangeTimestampMs: serverTimestampMs
                            ),
                        groupMembers: members
                            .filter { _, isAdmin in !isAdmin }
                            .map { memberId, _ in
                                GroupMember(
                                    groupId: groupId,
                                    profileId: memberId,
                                    role: .standard,
                                    roleStatus: .accepted,  // Legacy group members don't have role statuses
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
                                    roleStatus: .accepted,  // Legacy group members don't have role statuses
                                    isHidden: false
                                )
                            },
                        priority: legacyGroup.priority,
                        joinedAt: TimeInterval(legacyGroup.joined_at)
                    )
                )
            }
            else if user_groups_it_is_group(groupsIterator, &group) {
                let groupSessionId: String = String(libSessionVal: group.id)
                
                groups.append(
                    GroupInfo(
                        groupSessionId: groupSessionId,
                        groupIdentityPrivateKey: (!group.have_secretkey ? nil :
                            Data(
                                libSessionVal: group.secretkey,
                                count: LibSession.sizeGroupSecretKeyBytes,
                                nullIfEmpty: true
                            )
                        ),
                        name: String(libSessionVal: group.name),
                        authData: (!group.have_auth_data ? nil :
                            Data(
                                libSessionVal: group.auth_data,
                                count: LibSession.sizeGroupAuthDataBytes,
                                nullIfEmpty: true
                            )
                        ),
                        priority: group.priority,
                        joinedAt: TimeInterval(group.joined_at),
                        invited: group.invited,
                        wasKickedFromGroup: ugroups_group_is_kicked(&group)
                    )
                )
            }
            else {
                SNLog("[LibSession] Ignoring unknown conversation type when iterating through volatile conversation info update")
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
            LibSession.kickFromConversationUIIfNeeded(removedThreadIds: Array(communityIdsToRemove), using: dependencies)
            
            try SessionThread
                .deleteOrLeave(
                    db,
                    threadIds: Array(communityIdsToRemove),
                    threadVariant: .community,
                    groupLeaveType: .forced,
                    calledFromConfigHandling: true,
                    using: dependencies
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
                let joinedAt: TimeInterval = group.joinedAt
            else { return }
            
            if !existingLegacyGroupIds.contains(group.id) {
                // Add a new group if it doesn't already exist
                try MessageReceiver.handleNewLegacyClosedGroup(
                    db,
                    legacyGroupSessionId: group.id,
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
                    formationTimestamp: TimeInterval((group.joinedAt ?? (Double(serverTimestampMs) / 1000))),
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
                
                if
                    let remoteConfig = group.disappearingConfig,
                    let remoteLastChangeTimestampMs = remoteConfig.lastChangeTimestampMs,
                    let localLastChangeTimestampMs = localConfig.lastChangeTimestampMs,
                    remoteLastChangeTimestampMs > localLastChangeTimestampMs
                {
                    _ = try localConfig.with(
                        isEnabled: remoteConfig.isEnabled,
                        durationSeconds: remoteConfig.durationSeconds,
                        type: remoteConfig.type,
                        lastChangeTimestampMs: remoteConfig.lastChangeTimestampMs
                    ).upsert(db)
                    
                    _ = try Interaction
                        .filter(Interaction.Columns.threadId == group.id)
                        .filter(Interaction.Columns.variant == Interaction.Variant.infoDisappearingMessagesUpdate)
                        .filter(Interaction.Columns.timestampMs <= (remoteLastChangeTimestampMs - Int64(remoteConfig.durationSeconds * 1000)))
                        .deleteAll(db)
                }
                
                // Update the members
                let updatedMembers: Set<GroupMember> = members
                    .appending(
                        contentsOf: updatedAdmins.map { admin in
                            GroupMember(
                                groupId: admin.groupId,
                                profileId: admin.profileId,
                                role: .standard,
                                roleStatus: .accepted,  // Legacy group members don't have role statuses
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
                    try updatedMembers.forEach { try $0.upsert(db) }
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
                    try updatedAdmins.forEach { try $0.upsert(db) }
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
            LibSession.kickFromConversationUIIfNeeded(removedThreadIds: Array(legacyGroupIdsToRemove), using: dependencies)
            
            try SessionThread
                .deleteOrLeave(
                    db,
                    threadIds: Array(legacyGroupIdsToRemove),
                    threadVariant: .legacyGroup,
                    groupLeaveType: .forced,
                    calledFromConfigHandling: true,
                    using: dependencies
                )
        }
        
        // MARK: -- Handle Group Changes
        
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        let existingGroupSessionIds: Set<String> = Set(existingThreadInfo
            .filter { $0.value.variant == .group }
            .keys)
        let existingGroups: [String: ClosedGroup] = (try? ClosedGroup
            .fetchAll(db, ids: existingGroupSessionIds))
            .defaulting(to: [])
            .reduce(into: [:]) { result, next in result[next.id] = next }
        
        try groups.forEach { group in
            switch (existingGroups[group.groupSessionId], existingGroupSessionIds.contains(group.groupSessionId)) {
                case (.none, _), (_, false):
                    // Add a new group if it doesn't already exist
                    try MessageReceiver.handleNewGroup(
                        db,
                        groupSessionId: group.groupSessionId,
                        groupIdentityPrivateKey: group.groupIdentityPrivateKey,
                        name: group.name,
                        authData: group.authData,
                        joinedAt: TimeInterval(group.joinedAt ?? (Double(serverTimestampMs) / 1000)),
                        invited: (group.invited == true),
                        calledFromConfigHandling: true,
                        using: dependencies
                    )
                    
                    /// If the thread didn't already exist, or the user had previously been kicked but has since been re-added to the group, then insert
                    /// a fallback 'invited' info message
                    if existingGroups[group.groupSessionId] == nil || group.wasKickedFromGroup == true {
                        _ = try Interaction(
                            threadId: group.groupSessionId,
                            authorId: group.groupSessionId,
                            variant: .infoGroupInfoInvited,
                            body: ClosedGroup.MessageInfo
                                .invitedFallback(group.name ?? "GROUP_TITLE_FALLBACK".localized())
                                .infoString(using: dependencies),
                            timestampMs: (group.joinedAt.map { Int64(Double($0 * 1000)) } ?? serverTimestampMs),
                            wasRead: LibSession.timestampAlreadyRead(
                                threadId: group.groupSessionId,
                                threadVariant: .group,
                                timestampMs: (group.joinedAt.map { Int64(Double($0 * 1000)) } ?? serverTimestampMs),
                                userSessionId: userSessionId,
                                openGroup: nil,
                                using: dependencies
                            )
                        ).inserted(db)
                    }
                    
                case (.some(let existingGroup), _):
                    let joinedAt: TimeInterval = (
                        group.joinedAt.map { TimeInterval($0) } ??
                        existingGroup.formationTimestamp
                    )
                    
                    /// Otherwise update the existing group
                    ///
                    /// **Note:** We ignore the `name` value here as if it's an existing group then assume we will get the
                    /// proper name by polling for the `GROUP_INFO` instead of via syncing the `USER_GROUPS` data
                    let groupChanges: [ConfigColumnAssignment] = [
                        (existingGroup.formationTimestamp == joinedAt ? nil :
                            ClosedGroup.Columns.formationTimestamp.set(to: TimeInterval(joinedAt))
                        ),
                        (existingGroup.authData == group.authData ? nil :
                            ClosedGroup.Columns.authData.set(to: group.authData)
                        ),
                        (existingGroup.groupIdentityPrivateKey == group.groupIdentityPrivateKey ? nil :
                            ClosedGroup.Columns.groupIdentityPrivateKey.set(to: group.groupIdentityPrivateKey)
                        ),
                        (existingGroup.invited == group.invited ? nil :
                            ClosedGroup.Columns.invited.set(to: (group.invited ?? false))
                        )
                    ].compactMap { $0 }

                    // Apply any group changes
                    if !groupChanges.isEmpty {
                        _ = try? ClosedGroup
                            .filter(id: group.groupSessionId)
                            .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                                db,
                                groupChanges
                            )
                    }
            }

            // Make any thread-specific changes if needed
            if existingThreadInfo[group.groupSessionId]?.pinnedPriority != group.priority {
                _ = try? SessionThread
                    .filter(id: group.groupSessionId)
                    .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                        db,
                        SessionThread.Columns.pinnedPriority.set(to: group.priority)
                    )
            }
        }
        
        // Remove any groups which are no longer in the config
        let groupSessionIdsToRemove: Set<String> = existingGroupSessionIds
            .subtracting(groups.map { $0.groupSessionId })
        
        if !groupSessionIdsToRemove.isEmpty {
            LibSession.kickFromConversationUIIfNeeded(removedThreadIds: Array(groupSessionIdsToRemove), using: dependencies)
            
            try SessionThread
                .deleteOrLeave(
                    db,
                    threadIds: Array(groupSessionIdsToRemove),
                    threadVariant: .group,
                    groupLeaveType: .forced,
                    calledFromConfigHandling: true
                )
            
            groupSessionIdsToRemove.forEach { groupSessionId in
                LibSession.removeGroupStateIfNeeded(
                    db,
                    groupSessionId: SessionId(.group, hex: groupSessionId),
                    using: dependencies
                )
            }
        }
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
        in config: Config?
    ) throws {
        guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
        guard !legacyGroups.isEmpty else { return }
        
        try legacyGroups
            .forEach { legacyGroup in
                var cGroupId: [CChar] = legacyGroup.id.cArray.nullTerminated()
                guard let userGroup: UnsafeMutablePointer<ugroups_legacy_group_info> = user_groups_get_or_construct_legacy_group(conf, &cGroupId) else {
                    /// It looks like there are some situations where this object might not get created correctly (and
                    /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
                    SNLog("Unable to upsert legacy group conversation to LibSession: \(config.lastError)")
                    throw LibSessionError.getOrConstructFailedUnexpectedly
                }
                
                // Assign all properties to match the updated group (if there is one)
                if let updatedName: String = legacyGroup.name {
                    userGroup.pointee.name = updatedName.toLibSession()
                    
                    // Store the updated group (needs to happen before variables go out of scope)
                    user_groups_set_legacy_group(conf, userGroup)
                }
                
                if let lastKeyPair: ClosedGroupKeyPair = legacyGroup.lastKeyPair {
                    userGroup.pointee.enc_pubkey = lastKeyPair.publicKey.toLibSession()
                    userGroup.pointee.enc_seckey = lastKeyPair.secretKey.toLibSession()
                    userGroup.pointee.have_enc_keys = true
                    
                    // Store the updated group (needs to happen before variables go out of scope)
                    user_groups_set_legacy_group(conf, userGroup)
                }
                
                // Assign all properties to match the updated disappearing messages config (if there is one)
                if let updatedConfig: DisappearingMessagesConfiguration = legacyGroup.disappearingConfig {
                    userGroup.pointee.disappearing_timer = (!updatedConfig.isEnabled ? 0 :
                        Int64(floor(updatedConfig.durationSeconds))
                    )
                    
                    user_groups_set_legacy_group(conf, userGroup)
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
                    
                    membersIdsToAdd.forEach { memberId in
                        var cProfileId: [CChar] = memberId.cArray.nullTerminated()
                        ugroups_legacy_member_add(userGroup, &cProfileId, false)
                    }
                    
                    membersIdsToRemove.forEach { memberId in
                        var cProfileId: [CChar] = memberId.cArray.nullTerminated()
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
                    
                    adminIdsToAdd.forEach { adminId in
                        var cProfileId: [CChar] = adminId.cArray.nullTerminated()
                        ugroups_legacy_member_add(userGroup, &cProfileId, true)
                    }
                    
                    adminIdsToRemove.forEach { adminId in
                        var cProfileId: [CChar] = adminId.cArray.nullTerminated()
                        ugroups_legacy_member_remove(userGroup, &cProfileId)
                    }
                }
                
                if let joinedAt: Int64 = legacyGroup.joinedAt.map({ Int64($0) }) {
                    userGroup.pointee.joined_at = joinedAt
                }
                
                // Store the updated group (can't be sure if we made any changes above)
                userGroup.pointee.priority = (legacyGroup.priority ?? userGroup.pointee.priority)
                
                // Note: Need to free the legacy group pointer
                user_groups_set_free_legacy_group(conf, userGroup)
            }
    }
    
    static func upsert(
        groups: [GroupInfo],
        in config: Config?
    ) throws {
        guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
        guard !groups.isEmpty else { return }
        
        try groups
            .forEach { group in
                var cGroupSessionId: [CChar] = group.groupSessionId.cArray.nullTerminated()
                var userGroup: ugroups_group_info = ugroups_group_info()
                
                guard user_groups_get_or_construct_group(conf, &userGroup, &cGroupSessionId) else {
                    /// It looks like there are some situations where this object might not get created correctly (and
                    /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
                    SNLog("Unable to upsert group conversation to LibSession: \(String(describing: config.lastError))")
                    throw LibSessionError.getOrConstructFailedUnexpectedly
                }
                
                /// Assign the non-admin auth data (if it exists)
                if let authData: Data = group.authData {
                    userGroup.auth_data = authData.toLibSession()
                    userGroup.have_auth_data = true
                }

                /// Assign the admin key (if it exists)
                ///
                /// **Note:** We do this after assigning the `auth_data` as generally the values are mutually
                /// exclusive and if we have a `groupIdentityPrivateKey` we want that to take priority
                if let privateKey: Data = group.groupIdentityPrivateKey {
                    userGroup.secretkey = privateKey.toLibSession()
                    userGroup.have_secretkey = true

                    // Store the updated group (needs to happen before variables go out of scope)
                    user_groups_set_group(conf, &userGroup)
                }
                
                /// Assign the group name
                if let name: String = group.name {
                    userGroup.name = name.toLibSession()
                    
                    // Store the updated group (needs to happen before variables go out of scope)
                    user_groups_set_group(conf, &userGroup)
                }

                // Store the updated group (can't be sure if we made any changes above)
                userGroup.invited = (group.invited ?? userGroup.invited)
                userGroup.joined_at = (group.joinedAt.map { Int64($0) } ?? userGroup.joined_at)
                userGroup.priority = (group.priority ?? userGroup.priority)
                user_groups_set_group(conf, &userGroup)
            }
    }
    
    static func upsert(
        communities: [CommunityInfo],
        in config: Config?
    ) throws {
        guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
        guard !communities.isEmpty else { return }
        
        try communities
            .forEach { community in
                var cBaseUrl: [CChar] = community.urlInfo.server.cArray.nullTerminated()
                var cRoom: [CChar] = community.urlInfo.roomToken.cArray.nullTerminated()
                var cPubkey: [UInt8] = Data(hex: community.urlInfo.publicKey).cArray
                var userCommunity: ugroups_community_info = ugroups_community_info()
                
                guard user_groups_get_or_construct_community(conf, &userCommunity, &cBaseUrl, &cRoom, &cPubkey) else {
                    /// It looks like there are some situations where this object might not get created correctly (and
                    /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
                    SNLog("Unable to upsert community conversation to LibSession: \(String(describing: config.lastError))")
                    throw LibSessionError.getOrConstructFailedUnexpectedly
                }
                
                userCommunity.priority = (community.priority ?? userCommunity.priority)
                user_groups_set_community(conf, &userCommunity)
            }
    }
    
    @discardableResult static func updatingGroups<T>(
        _ db: Database,
        _ updated: [T],
        using dependencies: Dependencies
    ) throws -> [T] {
        guard let updatedGroups: [ClosedGroup] = updated as? [ClosedGroup] else { throw StorageError.generic }
        
        // Exclude legacy groups as they aren't managed via LibSession
        let targetGroups: [ClosedGroup] = updatedGroups
            .filter { (try? SessionId(from: $0.id))?.prefix == .group }
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        
        // If we only updated the current user contact then no need to continue
        guard !targetGroups.isEmpty else { return updated }
        
        // Apply the changes
        try LibSession.performAndPushChange(
            db,
            for: .userGroups,
            sessionId: userSessionId,
            using: dependencies
        ) { config in
            try upsert(
                groups: targetGroups.map { group -> GroupInfo in
                    GroupInfo(
                        groupSessionId: group.threadId,
                        groupIdentityPrivateKey: group.groupIdentityPrivateKey,
                        name: group.name,
                        authData: group.authData
                    )
                },
                in: config
            )
        }
        
        return updated
    }
}

// MARK: - External Outgoing Changes

public extension LibSession {
    
    // MARK: -- Communities
    
    static func add(
        _ db: Database,
        server: String,
        rootToken: String,
        publicKey: String,
        using dependencies: Dependencies
    ) throws {
        try LibSession.performAndPushChange(
            db,
            for: .userGroups,
            sessionId: getUserSessionId(db, using: dependencies),
            using: dependencies
        ) { config in
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
                in: config
            )
        }
    }
    
    static func remove(
        _ db: Database,
        server: String,
        roomToken: String,
        using dependencies: Dependencies
    ) throws {
        try LibSession.performAndPushChange(
            db,
            for: .userGroups,
            sessionId: getUserSessionId(db, using: dependencies),
            using: dependencies
        ) { config in
            guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
            
            var cBaseUrl: [CChar] = server.cArray.nullTerminated()
            var cRoom: [CChar] = roomToken.cArray.nullTerminated()
            
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
            ],
            using: dependencies
        )
    }
    
    // MARK: -- Legacy Group Changes
    
    static func add(
        _ db: Database,
        legacyGroupSessionId: String,
        name: String,
        latestKeyPairPublicKey: Data,
        latestKeyPairSecretKey: Data,
        latestKeyPairReceivedTimestamp: TimeInterval,
        disappearingConfig: DisappearingMessagesConfiguration,
        members: Set<String>,
        admins: Set<String>,
        formationTimestamp: TimeInterval,
        using dependencies: Dependencies
    ) throws {
        try LibSession.performAndPushChange(
            db,
            for: .userGroups,
            sessionId: getUserSessionId(db, using: dependencies),
            using: dependencies
        ) { config in
            guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
            
            var cGroupSessionId: [CChar] = legacyGroupSessionId.cArray.nullTerminated()
            let userGroup: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf, &cGroupSessionId)
            
            // Need to make sure the group doesn't already exist (otherwise we will end up overriding the
            // content which could revert newer changes since this can be triggered from other 'NEW' messages
            // coming in from the legacy group swarm)
            guard userGroup == nil else {
                ugroups_legacy_group_free(userGroup)
                return
            }
            
            try LibSession.upsert(
                legacyGroups: [
                    LegacyGroupInfo(
                        id: legacyGroupSessionId,
                        name: name,
                        lastKeyPair: ClosedGroupKeyPair(
                            threadId: legacyGroupSessionId,
                            publicKey: latestKeyPairPublicKey,
                            secretKey: latestKeyPairSecretKey,
                            receivedTimestamp: latestKeyPairReceivedTimestamp
                        ),
                        disappearingConfig: disappearingConfig,
                        groupMembers: members
                            .map { memberId in
                                GroupMember(
                                    groupId: legacyGroupSessionId,
                                    profileId: memberId,
                                    role: .standard,
                                    roleStatus: .accepted,  // Legacy group members don't have role statuses
                                    isHidden: false
                                )
                            },
                        groupAdmins: admins
                            .map { memberId in
                                GroupMember(
                                    groupId: legacyGroupSessionId,
                                    profileId: memberId,
                                    role: .admin,
                                    roleStatus: .accepted,  // Legacy group members don't have role statuses
                                    isHidden: false
                                )
                            },
                        joinedAt: formationTimestamp
                    )
                ],
                in: config
            )
        }
    }
    
    static func update(
        _ db: Database,
        legacyGroupSessionId: String,
        name: String? = nil,
        latestKeyPair: ClosedGroupKeyPair? = nil,
        disappearingConfig: DisappearingMessagesConfiguration? = nil,
        members: Set<String>? = nil,
        admins: Set<String>? = nil,
        using dependencies: Dependencies
    ) throws {
        try LibSession.performAndPushChange(
            db,
            for: .userGroups,
            sessionId: getUserSessionId(db, using: dependencies),
            using: dependencies
        ) { config in
            try LibSession.upsert(
                legacyGroups: [
                    LegacyGroupInfo(
                        id: legacyGroupSessionId,
                        name: name,
                        lastKeyPair: latestKeyPair,
                        disappearingConfig: disappearingConfig,
                        groupMembers: members?
                            .map { memberId in
                                GroupMember(
                                    groupId: legacyGroupSessionId,
                                    profileId: memberId,
                                    role: .standard,
                                    roleStatus: .accepted,  // Legacy group members don't have role statuses
                                    isHidden: false
                                )
                            },
                        groupAdmins: admins?
                            .map { memberId in
                                GroupMember(
                                    groupId: legacyGroupSessionId,
                                    profileId: memberId,
                                    role: .admin,
                                    roleStatus: .accepted,  // Legacy group members don't have role statuses
                                    isHidden: false
                                )
                            }
                    )
                ],
                in: config
            )
        }
    }
    
    static func batchUpdate(
        _ db: Database,
        disappearingConfigs: [DisappearingMessagesConfiguration],
        using dependencies: Dependencies
    ) throws {
        try LibSession.performAndPushChange(
            db,
            for: .userGroups,
            sessionId: getUserSessionId(db, using: dependencies),
            using: dependencies
        ) { config in
            try LibSession.upsert(
                legacyGroups: disappearingConfigs.map {
                    LegacyGroupInfo(
                        id: $0.id,
                        disappearingConfig: $0
                    )
                },
                in: config
            )
        }
    }
    
    static func remove(
        _ db: Database,
        legacyGroupIds: [String],
        using dependencies: Dependencies
    ) throws {
        guard !legacyGroupIds.isEmpty else { return }
        
        try LibSession.performAndPushChange(
            db,
            for: .userGroups,
            sessionId: getUserSessionId(db, using: dependencies),
            using: dependencies
        ) { config in
            guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
            
            legacyGroupIds.forEach { threadId in
                var cGroupId: [CChar] = threadId.cArray.nullTerminated()
                
                // Don't care if the group doesn't exist
                user_groups_erase_legacy_group(conf, &cGroupId)
            }
        }
        
        // Remove the volatile info as well
        try LibSession.remove(db, volatileLegacyGroupIds: legacyGroupIds, using: dependencies)
    }
    
    // MARK: -- Group Changes
    
    static func add(
        _ db: Database,
        groupSessionId: String,
        groupIdentityPrivateKey: Data?,
        name: String?,
        authData: Data?,
        joinedAt: TimeInterval,
        invited: Bool,
        using dependencies: Dependencies
    ) throws {
        try LibSession.performAndPushChange(
            db,
            for: .userGroups,
            sessionId: getUserSessionId(db, using: dependencies),
            using: dependencies
        ) { config in
            try LibSession.upsert(
                groups: [
                    GroupInfo(
                        groupSessionId: groupSessionId,
                        groupIdentityPrivateKey: groupIdentityPrivateKey,
                        name: name,
                        authData: authData,
                        joinedAt: joinedAt,
                        invited: invited
                    )
                ],
                in: config
            )
        }
    }
    
    static func update(
        _ db: Database,
        groupSessionId: String,
        groupIdentityPrivateKey: Data? = nil,
        name: String? = nil,
        authData: Data? = nil,
        invited: Bool? = nil,
        using dependencies: Dependencies
    ) throws {
        try LibSession.performAndPushChange(
            db,
            for: .userGroups,
            sessionId: getUserSessionId(db, using: dependencies),
            using: dependencies
        ) { config in
            try LibSession.upsert(
                groups: [
                    GroupInfo(
                        groupSessionId: groupSessionId,
                        groupIdentityPrivateKey: groupIdentityPrivateKey,
                        name: name,
                        authData: authData,
                        invited: invited
                    )
                ],
                in: config
            )
        }
    }
    
    static func markAsKicked(
        _ db: Database,
        groupSessionIds: [String],
        using dependencies: Dependencies
    ) throws {
        guard !groupSessionIds.isEmpty else { return }
        
        try LibSession.performAndPushChange(
            db,
            for: .userGroups,
            sessionId: getUserSessionId(db, using: dependencies),
            using: dependencies
        ) { config in
            guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
            
            groupSessionIds.forEach { groupSessionId in
                var cGroupSessionId: [CChar] = groupSessionId.cArray.nullTerminated()
                var userGroup: ugroups_group_info = ugroups_group_info()
                
                guard user_groups_get_group(conf, &userGroup, &cGroupSessionId) else { return }
                
                ugroups_group_set_kicked(&userGroup)
                user_groups_set_group(conf, &userGroup)
            }
        }
    }
    
    static func wasKickedFromGroup(
        groupSessionId: SessionId,
        using dependencies: Dependencies = Dependencies()
    ) -> Bool {
        return (try? dependencies[cache: .libSession]
            .config(for: .userGroups, sessionId: getUserSessionId(using: dependencies))
            .wrappedValue
            .map { config in
                guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
                
                var cGroupId: [CChar] = groupSessionId.hexString.cArray.nullTerminated()
                var userGroup: ugroups_group_info = ugroups_group_info()
                
                // If the group doesn't exist then assume the user hasn't been kicked
                guard user_groups_get_group(conf, &userGroup, &cGroupId) else { return false }
                
                return ugroups_group_is_kicked(&userGroup)
            })
            .defaulting(to: false)
    }
    
    static func remove(
        _ db: Database,
        groupSessionIds: [String],
        using dependencies: Dependencies
    ) throws {
        guard !groupSessionIds.isEmpty else { return }
        
        try LibSession.performAndPushChange(
            db,
            for: .userGroups,
            sessionId: getUserSessionId(db, using: dependencies),
            using: dependencies
        ) { config in
            guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
            
            groupSessionIds.forEach { groupSessionId in
                var cGroupSessionId: [CChar] = groupSessionId.cArray.nullTerminated()

                // Don't care if the group doesn't exist
                user_groups_erase_group(conf, &cGroupSessionId)
            }
        }
        
        // Remove the volatile info as well
        try LibSession.remove(db, volatileGroupSessionIds: groupSessionIds, using: dependencies)
    }
}

// MARK: - LegacyGroupInfo

extension LibSession {
    struct LegacyGroupInfo: Decodable, FetchableRecord, ColumnExpressible {
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
        let joinedAt: TimeInterval?
        
        init(
            id: String,
            name: String? = nil,
            lastKeyPair: ClosedGroupKeyPair? = nil,
            disappearingConfig: DisappearingMessagesConfiguration? = nil,
            groupMembers: [GroupMember]? = nil,
            groupAdmins: [GroupMember]? = nil,
            priority: Int32? = nil,
            joinedAt: TimeInterval? = nil
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
            let lastKeyPair: TypedTableAlias<ClosedGroupKeyPair> = TypedTableAlias(LegacyGroupInfo.self, column: .lastKeyPair)
            let disappearingConfig: TypedTableAlias<DisappearingMessagesConfiguration> = TypedTableAlias(LegacyGroupInfo.self, column: .disappearingConfig)
            
            /// **Note:** The `numColumnsBeforeTypes` value **MUST** match the number of fields before
            /// the `lastKeyPair` entry below otherwise the query will fail to
            /// parse and might throw
            ///
            /// Explicitly set default values for the fields ignored for search results
            let numColumnsBeforeTypes: Int = 4
            
            let request: SQLRequest<LegacyGroupInfo> = """
                SELECT
                    \(closedGroup[.threadId]) AS \(LegacyGroupInfo.Columns.threadId),
                    \(closedGroup[.name]) AS \(LegacyGroupInfo.Columns.name),
                    \(closedGroup[.formationTimestamp]) AS \(LegacyGroupInfo.Columns.joinedAt),
                    \(thread[.pinnedPriority]) AS \(LegacyGroupInfo.Columns.priority),
                    \(lastKeyPair.allColumns),
                    \(disappearingConfig.allColumns)
                
                FROM \(ClosedGroup.self)
                JOIN \(SessionThread.self) ON \(thread[.id]) = \(closedGroup[.threadId])
                LEFT JOIN (
                    SELECT
                        \(lastKeyPair[.threadId]),
                        \(lastKeyPair[.publicKey]),
                        \(lastKeyPair[.secretKey]),
                        MAX(\(lastKeyPair[.receivedTimestamp])) AS \(ClosedGroupKeyPair.Columns.receivedTimestamp),
                        \(lastKeyPair[.threadKeyPairHash])
                    FROM \(lastKeyPair)
                    GROUP BY \(lastKeyPair[.threadId])
                ) \(lastKeyPair, asSubquery: true) ON \(lastKeyPair[.threadId]) = \(closedGroup[.threadId])
                LEFT JOIN \(disappearingConfig) ON \(disappearingConfig[.threadId]) = \(closedGroup[.threadId])
                
                WHERE \(closedGroup[.threadId]) LIKE '\(SessionId.Prefix.standard)%'
            """
            
            let legacyGroupInfoNoMembers: [LegacyGroupInfo] = try request
                .adapted { db in
                    let adapters = try splittingRowAdapters(columnCounts: [
                        numColumnsBeforeTypes,
                        ClosedGroupKeyPair.numberOfSelectedColumns(db),
                        DisappearingMessagesConfiguration.numberOfSelectedColumns(db)
                    ])
                    
                    return ScopeAdapter.with(LegacyGroupInfo.self, [
                        .lastKeyPair: adapters[1],
                        .disappearingConfig: adapters[2]
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
}

// MARK: - GroupInfo

extension LibSession {
    struct GroupInfo {
        let groupSessionId: String
        let groupIdentityPrivateKey: Data?
        let name: String?
        let authData: Data?
        let priority: Int32?
        let joinedAt: TimeInterval?
        let invited: Bool?
        let wasKickedFromGroup: Bool?
        
        init(
            groupSessionId: String,
            groupIdentityPrivateKey: Data? = nil,
            name: String? = nil,
            authData: Data? = nil,
            priority: Int32? = nil,
            joinedAt: TimeInterval? = nil,
            invited: Bool? = nil,
            wasKickedFromGroup: Bool? = nil
        ) {
            self.groupSessionId = groupSessionId
            self.groupIdentityPrivateKey = groupIdentityPrivateKey
            self.name = name
            self.authData = authData
            self.priority = priority
            self.joinedAt = joinedAt
            self.invited = invited
            self.wasKickedFromGroup = wasKickedFromGroup
        }
    }
}

// MARK: - CommunityInfo

extension LibSession {
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
}

// MARK: - GroupThreadData

extension LibSession {
    fileprivate struct GroupThreadData {
        let communities: [PrioritisedData<LibSession.OpenGroupUrlInfo>]
        let legacyGroups: [PrioritisedData<LegacyGroupInfo>]
        let groups: [PrioritisedData<GroupInfo>]
    }
}

// MARK: - PrioritisedData

extension LibSession {
    fileprivate struct PrioritisedData<T> {
        let data: T
        let priority: Int32
    }
}
