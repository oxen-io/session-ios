// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Size Restrictions

public extension LibSession {
    static var sizeMaxGroupMemberCount: Int { 100 }
}

// MARK: - Group Members Handling

internal extension LibSession {
    static let columnsRelatedToGroupMembers: [ColumnExpression] = [
        GroupMember.Columns.role,
        GroupMember.Columns.roleStatus
    ]
}

// MARK: - Incoming Changes

internal extension LibSessionCacheType {
    func handleGroupMembersUpdate(
        _ db: Database,
        in config: LibSession.Config?,
        groupSessionId: SessionId,
        serverTimestampMs: Int64
    ) throws {
        guard configNeedsDump(config) else { return }
        guard case .groupMembers(let conf) = config else { throw LibSessionError.invalidConfigObject }
        
        // Get the two member sets
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let updatedMembers: Set<GroupMember> = try LibSession.extractMembers(from: conf, groupSessionId: groupSessionId)
        let existingMembers: Set<GroupMember> = (try? GroupMember
            .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
            .fetchSet(db))
            .defaulting(to: [])
        let updatedStandardMemberIds: Set<String> = updatedMembers
            .filter { $0.role == .standard }
            .map { $0.profileId }
            .asSet()
        let updatedAdminMemberIds: Set<String> = updatedMembers
            .filter { $0.role == .admin }
            .map { $0.profileId }
            .asSet()

        // Add in any new members and remove any removed members
        try updatedMembers
            .subtracting(existingMembers)
            .forEach { try $0.upsert(db) }
        
        try GroupMember
            .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
            .filter(
                (
                    GroupMember.Columns.role == GroupMember.Role.standard &&
                    !updatedStandardMemberIds.contains(GroupMember.Columns.profileId)
                ) || (
                    GroupMember.Columns.role == GroupMember.Role.admin &&
                    !updatedAdminMemberIds.contains(GroupMember.Columns.profileId)
                )
            )
            .deleteAll(db)
        
        // Schedule a job to process the removals
        if (try? LibSession.extractPendingRemovals(from: conf, groupSessionId: groupSessionId))?.isEmpty == false {
            dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .processPendingGroupMemberRemovals,
                    threadId: groupSessionId.hexString,
                    details: ProcessPendingGroupMemberRemovalsJob.Details(
                        changeTimestampMs: serverTimestampMs
                    )
                ),
                canStartJob: true
            )
        }
        
        // If the current user is an admin but doesn't have the correct member state then update it now
        let maybeCurrentMember: GroupMember? = updatedMembers
            .first { member in member.profileId == userSessionId.hexString }
        let currentMemberHasAdminKey: Bool = isAdmin(groupSessionId: groupSessionId)
        
        if
            let currentMember: GroupMember = maybeCurrentMember,
            currentMemberHasAdminKey && (
                currentMember.role != .admin ||
                currentMember.roleStatus != .accepted
            )
        {
            try GroupMember
                .filter(GroupMember.Columns.profileId == userSessionId.hexString)
                .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
                .updateAllAndConfig(
                    db,
                    [
                        (currentMember.role == .admin ? nil :
                            GroupMember.Columns.role.set(to: GroupMember.Role.admin)
                        ),
                        (currentMember.roleStatus == .accepted ? nil :
                            GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.accepted)
                        ),
                    ].compactMap { $0 },
                    calledFromConfig: config,
                    using: dependencies
                )
            try LibSession.updateMemberStatus(
                memberId: userSessionId.hexString,
                role: .admin,
                status: .accepted,
                in: config
            )
        }
        
        // If there were members then also extract and update the profile information for the members
        // if we don't have newer data locally
        guard !updatedMembers.isEmpty else { return }
        
        let groupProfiles: Set<Profile>? = try? LibSession.extractProfiles(
            from: conf,
            groupSessionId: groupSessionId,
            serverTimestampMs: serverTimestampMs
        )
        
        groupProfiles?.forEach { profile in
            try? Profile.updateIfNeeded(
                db,
                publicKey: profile.id,
                displayNameUpdate: .contactUpdate(profile.name),
                displayPictureUpdate: {
                    guard
                        let profilePictureUrl: String = profile.profilePictureUrl,
                        let profileKey: Data = profile.profileEncryptionKey
                    else { return .none }
                    
                    return .contactUpdateTo(
                        url: profilePictureUrl,
                        key: profileKey,
                        fileName: nil
                    )
                }(),
                sentTimestamp: TimeInterval(Double(serverTimestampMs) * 1000),
                calledFromConfig: config,
                using: dependencies
            )
        }
    }
}

// MARK: - Outgoing Changes

internal extension LibSession {
    static func getMembers(
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws -> Set<GroupMember> {
        return try dependencies.mutate(cache: .libSession) { cache in
            guard case .groupMembers(let conf) = cache.config(for: .groupMembers, sessionId: groupSessionId) else {
                throw LibSessionError.invalidConfigObject
            }
            
            return try extractMembers(
                from: conf,
                groupSessionId: groupSessionId
            )
        } ?? { throw LibSessionError.failedToRetrieveConfigData }()
    }
    
    static func getPendingMemberRemovals(
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws -> [String: GROUP_MEMBER_STATUS] {
        return try dependencies.mutate(cache: .libSession) { cache in
            guard case .groupMembers(let conf) = cache.config(for: .groupMembers, sessionId: groupSessionId) else {
                throw LibSessionError.invalidConfigObject
            }
            
            return try extractPendingRemovals(
                from: conf,
                groupSessionId: groupSessionId
            )
        } ?? { throw LibSessionError.failedToRetrieveConfigData }()
    }
    
    static func addMembers(
        _ db: Database,
        groupSessionId: SessionId,
        members: [(id: String, profile: Profile?)],
        allowAccessToHistoricMessages: Bool,
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .groupMembers, sessionId: groupSessionId) { config in
                guard case .groupMembers(let conf) = config else { throw LibSessionError.invalidConfigObject }
                
                try members.forEach { memberId, profile in
                    var cMemberId: [CChar] = try memberId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                    var member: config_group_member = config_group_member()
                    
                    guard groups_members_get_or_construct(conf, &member, &cMemberId) else {
                        throw LibSessionError(
                            conf,
                            fallbackError: .getOrConstructFailedUnexpectedly,
                            logMessage: "Failed to add member to group: \(groupSessionId), error"
                        )
                    }
                    
                    // Don't override the existing name with an empty one
                    if let memberName: String = profile?.name, !memberName.isEmpty {
                        member.set(\.name, to: memberName)
                    }
                    
                    if
                        let picUrl: String = profile?.profilePictureUrl,
                        let picKey: Data = profile?.profileEncryptionKey,
                        !picUrl.isEmpty,
                        picKey.count == DisplayPictureManager.aes256KeyByteLength
                    {
                        member.set(\.profile_pic.url, to: picUrl)
                        member.set(\.profile_pic.key, to: picKey)
                    }
                    
                    member.set(\.invited, to: GroupMember.RoleStatus.notSentYet.libSessionValue)
                    member.set(\.supplement, to: allowAccessToHistoricMessages)
                    groups_members_set(conf, &member)
                    try LibSessionError.throwIfNeeded(conf)
                }
            }
        }
    }
    
    static func updateMemberStatus(
        _ db: Database,
        groupSessionId: SessionId,
        memberId: String,
        role: GroupMember.Role,
        status: GroupMember.RoleStatus,
        profile: Profile?,
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .groupMembers, sessionId: groupSessionId) { config in
                try LibSession.updateMemberStatus(memberId: memberId, role: role, status: status, in: config)
                try LibSession.updateMemberProfile(memberId: memberId, profile: profile, in: config)
            }
        }
    }
    
    static func updateMemberStatus(
        memberId: String,
        role: GroupMember.Role,
        status: GroupMember.RoleStatus,
        in config: Config?
    ) throws {
        guard case .groupMembers(let conf) = config else { throw LibSessionError.invalidConfigObject }
        
        // Only update members if they already exist in the group
        var cMemberId: [CChar] = try memberId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
        
        // Update the role and status to match
        switch (role, status) {
            case (.admin, .accepted): groups_members_set_promotion_accepted(conf, &cMemberId)
            case (.admin, .failed): groups_members_set_promotion_failed(conf, &cMemberId)
            case (.admin, .pending): groups_members_set_promotion_sent(conf, &cMemberId)
            case (.admin, .notSentYet): groups_members_set_promoted(conf, &cMemberId)
            
            case (_, .accepted): groups_members_set_invite_accepted(conf, &cMemberId)
            case (_, .failed): groups_members_set_invite_failed(conf, &cMemberId)
            case (_, .pending): groups_members_set_invite_sent(conf, &cMemberId)
            case (_, .notSentYet): break    // Default state (can't return to this after creation)
        }
        
        try LibSessionError.throwIfNeeded(conf)
    }
    
    static func updateMemberProfile(
        _ db: Database,
        groupSessionId: SessionId,
        memberId: String,
        profile: Profile?,
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .groupMembers, sessionId: groupSessionId) { config in
                try LibSession.updateMemberProfile(memberId: memberId, profile: profile, in: config)
            }
        }
    }
    
    static func updateMemberProfile(
        memberId: String,
        profile: Profile?,
        in config: Config?
    ) throws {
        guard let profile: Profile = profile else { return }
        guard case .groupMembers(let conf) = config else { throw LibSessionError.invalidConfigObject }
        
        // Only update members if they already exist in the group
        var cMemberId: [CChar] = try memberId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
        var groupMember: config_group_member = config_group_member()
        
        // If the member doesn't exist then do nothing
        guard groups_members_get(conf, &groupMember, &cMemberId) else { return }
        
        groupMember.set(\.name, to: profile.name)
        
        if profile.profilePictureUrl != nil && profile.profileEncryptionKey != nil {
            groupMember.set(\.profile_pic.url, to: profile.profilePictureUrl)
            groupMember.set(\.profile_pic.key, to: profile.profileEncryptionKey)
        }
        
        groups_members_set(conf, &groupMember)
        try? LibSessionError.throwIfNeeded(conf)
    }
    
    static func flagMembersForRemoval(
        _ db: Database,
        groupSessionId: SessionId,
        memberIds: Set<String>,
        removeMessages: Bool,
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .groupMembers, sessionId: groupSessionId) { config in
                guard case .groupMembers(let conf) = config else { throw LibSessionError.invalidConfigObject }
                
                try memberIds.forEach { memberId in
                    // Only update members if they already exist in the group
                    var cMemberId: [CChar] = try memberId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                    groups_members_set_removed(conf, &cMemberId, removeMessages)
                    try LibSessionError.throwIfNeeded(conf)
                }
            }
        }
    }
    
    static func removeMembers(
        _ db: Database,
        groupSessionId: SessionId,
        memberIds: Set<String>,
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .groupMembers, sessionId: groupSessionId) { config in
                guard case .groupMembers(let conf) = config else { throw LibSessionError.invalidConfigObject }
                
                try memberIds.forEach { memberId in
                    var cMemberId: [CChar] = try memberId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                    
                    groups_members_erase(conf, &cMemberId)
                }
            }
        }
    }
    
    static func updatingGroupMembers<T>(
        _ db: Database,
        _ updated: [T],
        using dependencies: Dependencies
    ) throws -> [T] {
        guard let updatedMembers: [GroupMember] = updated as? [GroupMember] else { throw StorageError.generic }
        
        // Exclude legacy groups as they aren't managed via SessionUtil and groups where the current user
        // isn't an admin (non-admins can't update `GroupMembers` anyway)
        let targetMembers: [GroupMember] = updatedMembers
            .filter { (try? SessionId(from: $0.groupId))?.prefix == .group }
            .filter { isAdmin(groupSessionId: SessionId(.group, hex: $0.groupId), using: dependencies) }
        
        // If we only updated the current user contact then no need to continue
        guard
            !targetMembers.isEmpty,
            let groupSessionId: SessionId = targetMembers.first.map({ try? SessionId(from: $0.groupId) }),
            groupSessionId.prefix == .group
        else { return updated }
        
        // Loop through each of the groups and update their settings
        try targetMembers.forEach { member in
            try dependencies.mutate(cache: .libSession) { cache in
                try cache.performAndPushChange(db, for: .groupMembers, sessionId: groupSessionId) { config in
                    try LibSession.updateMemberStatus(
                        memberId: member.profileId,
                        role: member.role,
                        status: member.roleStatus,
                        in: config
                    )
                }
            }
        }
        
        return updated
    }
}

// MARK: - MemberData

private struct MemberData {
    let memberId: String
    let profile: Profile?
    let admin: Bool
    let invited: Int32
    let promoted: Int32
}

// MARK: - Convenience

internal extension LibSession {
    static func extractMembers(
        from conf: UnsafeMutablePointer<config_object>?,
        groupSessionId: SessionId
    ) throws -> Set<GroupMember> {
        var infiniteLoopGuard: Int = 0
        var result: [GroupMember] = []
        var member: config_group_member = config_group_member()
        let membersIterator: UnsafeMutablePointer<groups_members_iterator> = groups_members_iterator_new(conf)
        
        while !groups_members_iterator_done(membersIterator, &member) {
            try LibSession.checkLoopLimitReached(&infiniteLoopGuard, for: .groupMembers)
            let status: GROUP_MEMBER_STATUS = group_member_status(&member);
            
            // Ignore members pending removal
            guard !status.isRemoveStatus else { continue }
            
            result.append(
                GroupMember(
                    groupId: groupSessionId.hexString,
                    profileId: member.get(\.session_id),
                    role: (status.isAdmin(member.get(\.admin)) ? .admin : .standard),
                    roleStatus: status.roleStatus,
                    isHidden: false
                )
            )
            
            groups_members_iterator_advance(membersIterator)
        }
        groups_members_iterator_free(membersIterator) // Need to free the iterator
        
        return result.asSet()
    }
    
    static func extractPendingRemovals(
        from conf: UnsafeMutablePointer<config_object>?,
        groupSessionId: SessionId
    ) throws -> [String: GROUP_MEMBER_STATUS] {
        var infiniteLoopGuard: Int = 0
        var result: [String: GROUP_MEMBER_STATUS] = [:]
        var member: config_group_member = config_group_member()
        let membersIterator: UnsafeMutablePointer<groups_members_iterator> = groups_members_iterator_new(conf)
        
        while !groups_members_iterator_done(membersIterator, &member) {
            try LibSession.checkLoopLimitReached(&infiniteLoopGuard, for: .groupMembers)
            let status: GROUP_MEMBER_STATUS = group_member_status(&member);
            
            guard status.isRemoveStatus else {
                groups_members_iterator_advance(membersIterator)
                continue
            }
            
            result[member.get(\.session_id)] = status
            groups_members_iterator_advance(membersIterator)
        }
        groups_members_iterator_free(membersIterator) // Need to free the iterator
        
        return result
    }
    
    static func extractProfiles(
        from conf: UnsafeMutablePointer<config_object>?,
        groupSessionId: SessionId,
        serverTimestampMs: Int64
    ) throws -> Set<Profile> {
        var infiniteLoopGuard: Int = 0
        var result: [Profile] = []
        var member: config_group_member = config_group_member()
        let membersIterator: UnsafeMutablePointer<groups_members_iterator> = groups_members_iterator_new(conf)
        
        while !groups_members_iterator_done(membersIterator, &member) {
            try LibSession.checkLoopLimitReached(&infiniteLoopGuard, for: .groupMembers)
            
            // Ignore members pending removal
            guard member.removed == 0 else { continue }
            
            result.append(
                Profile(
                    id: member.get(\.session_id),
                    name: member.get(\.name),
                    lastNameUpdate: TimeInterval(Double(serverTimestampMs) / 1000),
                    nickname: nil,
                    profilePictureUrl: member.get(\.profile_pic.url, nullIfEmpty: true),
                    profileEncryptionKey: (member.get(\.profile_pic.url, nullIfEmpty: true) == nil ? nil :
                        member.get(\.profile_pic.key)
                    ),
                    lastProfilePictureUpdate: TimeInterval(Double(serverTimestampMs) / 1000),
                    lastBlocksCommunityMessageRequests: nil
                )
            )
            
            groups_members_iterator_advance(membersIterator)
        }
        groups_members_iterator_free(membersIterator) // Need to free the iterator
        
        return result.asSet()
    }
}

fileprivate extension GroupMember.RoleStatus {
    var libSessionValue: Int32 {
        switch self {
            case .accepted: return 0
            case .pending: return Int32(INVITE_SENT.rawValue)
            case .failed: return Int32(INVITE_FAILED.rawValue)
            case .notSentYet: return Int32(INVITE_NOT_SENT.rawValue)
        }
    }
}

fileprivate extension GROUP_MEMBER_STATUS {
    func isAdmin(_ memberAdminFlag: Bool) -> Bool {
        switch self {
            case GROUP_MEMBER_STATUS_PROMOTION_UNKNOWN, GROUP_MEMBER_STATUS_PROMOTION_NOT_SENT,
                GROUP_MEMBER_STATUS_PROMOTION_FAILED, GROUP_MEMBER_STATUS_PROMOTION_SENT,
                GROUP_MEMBER_STATUS_PROMOTION_ACCEPTED:
                return true
                
            default: return memberAdminFlag
        }
    }
    
    var roleStatus: GroupMember.RoleStatus {
        switch self {
            case GROUP_MEMBER_STATUS_INVITE_NOT_SENT, GROUP_MEMBER_STATUS_PROMOTION_NOT_SENT:
                return .notSentYet
            
            case GROUP_MEMBER_STATUS_INVITE_ACCEPTED, GROUP_MEMBER_STATUS_PROMOTION_ACCEPTED:
                return .accepted
                
            case GROUP_MEMBER_STATUS_INVITE_FAILED, GROUP_MEMBER_STATUS_PROMOTION_FAILED:
                return .failed
            
            case GROUP_MEMBER_STATUS_INVITE_SENT, GROUP_MEMBER_STATUS_PROMOTION_SENT:
                return .pending
            
            // Default to "accepted" as that's what the `libSession.groups.member.status()` function does
            default: return .accepted
        }
    }
    
    var isRemoveStatus: Bool {
        switch self {
            case GROUP_MEMBER_STATUS_REMOVED, GROUP_MEMBER_STATUS_REMOVED_UNKNOWN,
                GROUP_MEMBER_STATUS_REMOVED_MEMBER_AND_MESSAGES:
                return true
                
            default: return false
        }
    }
}
