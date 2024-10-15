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
        guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
        
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
        
        // If the current user is an admin but doesn't have the 'accepted' status then update it now
        let currentMemberIsNewAdmin: Bool = updatedMembers.contains { member in
            member.profileId == userSessionId.hexString &&
            member.role == .admin &&
            member.roleStatus != .accepted
        }
        if currentMemberIsNewAdmin {
            try GroupMember
                .filter(GroupMember.Columns.profileId == userSessionId.hexString)
                .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
                .updateAllAndConfig(
                    db,
                    GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.accepted),
                    calledFromConfig: .groupMembers,
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
                calledFromConfig: .groupMembers,
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
            guard case .object(let conf) = cache.config(for: .groupMembers, sessionId: groupSessionId) else {
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
    ) throws -> [String: Bool] {
        return try dependencies.mutate(cache: .libSession) { cache in
            guard case .object(let conf) = cache.config(for: .groupMembers, sessionId: groupSessionId) else {
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
                guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
                
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
        guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
        
        // Only update members if they already exist in the group
        var cMemberId: [CChar] = try memberId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
        var groupMember: config_group_member = config_group_member()
        
        // If the member doesn't exist then do nothing
        guard groups_members_get(conf, &groupMember, &cMemberId) else { return }
        
        switch role {
            case .standard: groupMember.invited = status.libSessionValue
            case .admin:
                groupMember.admin = (groupMember.admin || status == .accepted)
                groupMember.promoted = status.libSessionValue
                
            default: break
        }
        
        groups_members_set(conf, &groupMember)
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
        guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
        
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
                guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
                
                try memberIds.forEach { memberId in
                    // Only update members if they already exist in the group
                    var cMemberId: [CChar] = try memberId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                    var groupMember: config_group_member = config_group_member()
                    
                    guard groups_members_get(conf, &groupMember, &cMemberId) else { return }
                    
                    groupMember.removed = (removeMessages ? 2 : 1)
                    groups_members_set(conf, &groupMember)
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
                guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
                
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
        
        // Exclude legacy groups as they aren't managed via SessionUtil
        let targetMembers: [GroupMember] = updatedMembers
            .filter { (try? SessionId(from: $0.groupId))?.prefix == .group }
        
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
                    guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
                    
                    // Only update members if they already exist in the group
                    var cMemberId: [CChar] = try member.profileId.cString(using: .utf8) ?? {
                        throw LibSessionError.invalidCConversion
                    }()
                    var groupMember: config_group_member = config_group_member()
                    
                    guard groups_members_get(conf, &groupMember, &cMemberId) else {
                        return
                    }
                    
                    // Update the role and status to match
                    switch member.role {
                        case .admin:
                            groupMember.admin = true
                            groupMember.invited = 0
                            groupMember.promoted = member.roleStatus.libSessionValue
                            
                        default:
                            groupMember.admin = false
                            groupMember.invited = member.roleStatus.libSessionValue
                            groupMember.promoted = 0
                    }
                    
                    groups_members_set(conf, &groupMember)
                    try LibSessionError.throwIfNeeded(conf)
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
            
            // Ignore members pending removal
            guard member.removed == 0 else { continue }
            
            result.append(
                GroupMember(
                    groupId: groupSessionId.hexString,
                    profileId: member.get(\.session_id),
                    role: (member.admin || (member.promoted > 0) ? .admin : .standard),
                    roleStatus: {
                        switch (member.invited, member.promoted, member.admin) {
                            case (2, _, _), (_, 2, _): return .failed               // Explicitly failed
                            case (3, _, _), (_, 3, _): return .notSentYet           // Explicitly notSentYet
                            case (1..., _, _), (_, 1..., _): return .pending        // Pending if not one of the above
                            default: return .accepted                               // Otherwise it's accepted
                        }
                    }(),
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
    ) throws -> [String: Bool] {
        var infiniteLoopGuard: Int = 0
        var result: [String: Bool] = [:]
        var member: config_group_member = config_group_member()
        let membersIterator: UnsafeMutablePointer<groups_members_iterator> = groups_members_iterator_new(conf)
        
        while !groups_members_iterator_done(membersIterator, &member) {
            try LibSession.checkLoopLimitReached(&infiniteLoopGuard, for: .groupMembers)
            
            guard member.removed > 0 else {
                groups_members_iterator_advance(membersIterator)
                continue
            }
            
            result[member.get(\.session_id)] = (member.removed == 2)
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
