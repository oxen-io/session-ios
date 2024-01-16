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
    
    // MARK: - Incoming Changes
    
    static func handleGroupMembersUpdate(
        _ db: Database,
        in config: Config?,
        groupSessionId: SessionId,
        serverTimestampMs: Int64,
        using dependencies: Dependencies
    ) throws {
        guard config.needsDump(using: dependencies) else { return }
        guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
        
        // Get the two member sets
        let updatedMembers: Set<GroupMember> = try extractMembers(from: conf, groupSessionId: groupSessionId)
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
        if (try? extractPendingRemovals(from: conf, groupSessionId: groupSessionId))?.isEmpty == false {
            dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .processPendingGroupMemberRemovals,
                    threadId: groupSessionId.hexString,
                    details: ProcessPendingGroupMemberRemovalsJob.Details(
                        changeTimestampMs: serverTimestampMs
                    )
                ),
                canStartJob: true,
                using: dependencies
            )
        }
        
        // If there were members then also extract and update the profile information for the members
        // if we don't have newer data locally
        guard !updatedMembers.isEmpty else { return }
        
        let groupProfiles: Set<Profile>? = try? extractProfiles(
            from: conf,
            groupSessionId: groupSessionId,
            serverTimestampMs: serverTimestampMs
        )
        
        groupProfiles?.forEach { profile in
            try? Profile.updateIfNeeded(
                db,
                publicKey: profile.id,
                name: profile.name,
                displayPictureUpdate: {
                    guard
                        let profilePictureUrl: String = profile.profilePictureUrl,
                        let profileKey: Data = profile.profileEncryptionKey
                    else { return .none }
                    
                    return .updateTo(
                        url: profilePictureUrl,
                        key: profileKey,
                        fileName: nil
                    )
                }(),
                sentTimestamp: TimeInterval(Double(serverTimestampMs) * 1000),
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
        return try dependencies[cache: .libSession]
            .config(for: .groupMembers, sessionId: groupSessionId)
            .wrappedValue
            .map { config in
                guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
                
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
        return try dependencies[cache: .libSession]
            .config(for: .groupMembers, sessionId: groupSessionId)
            .wrappedValue
            .map { config in
                guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
                
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
        try LibSession.performAndPushChange(
            db,
            for: .groupMembers,
            sessionId: groupSessionId,
            using: dependencies
        ) { config in
            guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
            
            try members.forEach { memberId, profile in
                var profilePic: user_profile_pic = user_profile_pic()
                
                if
                    let picUrl: String = profile?.profilePictureUrl,
                    let picKey: Data = profile?.profileEncryptionKey,
                    !picUrl.isEmpty,
                    picKey.count == DisplayPictureManager.aes256KeyByteLength
                {
                    profilePic.url = picUrl.toLibSession()
                    profilePic.key = picKey.toLibSession()
                }

                var error: LibSessionError?
                try CExceptionHelper.performSafely {
                    var cMemberId: [CChar] = memberId.cArray
                    var member: config_group_member = config_group_member()
                    
                    guard groups_members_get_or_construct(conf, &member, &cMemberId) else {
                        error = .getOrConstructFailedUnexpectedly
                        return
                    }
                    
                    // Don't override the existing name with an empty one
                    if let memberName: String = profile?.name, !memberName.isEmpty {
                        member.name = memberName.toLibSession()
                    }
                    member.profile_pic = profilePic
                    member.invited = 1
                    member.supplement = allowAccessToHistoricMessages
                    groups_members_set(conf, &member)
                }
                
                if let error: LibSessionError = error {
                    SNLog("[LibSession] Failed to add member to group: \(groupSessionId)")
                    throw error
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
        using dependencies: Dependencies
    ) throws {
        try LibSession.performAndPushChange(
            db,
            for: .groupMembers,
            sessionId: groupSessionId,
            using: dependencies
        ) { config in
            guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
            
            // Only update members if they already exist in the group
            var cMemberId: [CChar] = memberId.cArray
            var groupMember: config_group_member = config_group_member()
            
            // If the member doesn't exist or the role status is already "accepted" then do nothing
            guard
                groups_members_get(conf, &groupMember, &cMemberId) && (
                    (role == .standard && groupMember.invited != Int32(GroupMember.RoleStatus.accepted.rawValue)) ||
                    (role == .admin && (
                        !groupMember.admin ||
                        groupMember.promoted != Int32(GroupMember.RoleStatus.accepted.rawValue)
                    ))
                )
            else { return }
            
            switch role {
                case .standard: groupMember.invited = Int32(status.rawValue)
                case .admin:
                    groupMember.admin = (status == .accepted)
                    groupMember.promoted = Int32(status.rawValue)
                    
                default: break
            }
            
            groups_members_set(conf, &groupMember)
        }
    }
    
    static func flagMembersForRemoval(
        _ db: Database,
        groupSessionId: SessionId,
        memberIds: Set<String>,
        removeMessages: Bool,
        using dependencies: Dependencies
    ) throws {
        try LibSession.performAndPushChange(
            db,
            for: .groupMembers,
            sessionId: groupSessionId,
            using: dependencies
        ) { config in
            guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
            
            memberIds.forEach { memberId in
                // Only update members if they already exist in the group
                var cMemberId: [CChar] = memberId.cArray
                var groupMember: config_group_member = config_group_member()
                
                guard groups_members_get(conf, &groupMember, &cMemberId) else { return }
                
                groupMember.removed = (removeMessages ? 2 : 1)
                groups_members_set(conf, &groupMember)
            }
        }
    }
    
    static func removeMembers(
        _ db: Database,
        groupSessionId: SessionId,
        memberIds: Set<String>,
        using dependencies: Dependencies
    ) throws {
        try LibSession.performAndPushChange(
            db,
            for: .groupMembers,
            sessionId: groupSessionId,
            using: dependencies
        ) { config in
            guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
            
            memberIds.forEach { memberId in
                var cMemberId: [CChar] = memberId.cArray
                groups_members_erase(conf, &cMemberId)
            }
        }
    }
    
    static func updatingGroupMembers<T>(
        _ db: Database,
        _ updated: [T],
        using dependencies: Dependencies
    ) throws -> [T] {
        guard let updatedMembers: [GroupMember] = updated as? [GroupMember] else { throw StorageError.generic }
        
        // Exclude legacy groups as they aren't managed via LibSession
        let targetMembers: [GroupMember] = updatedMembers
            .filter { (try? SessionId(from: $0.groupId))?.prefix == .group }
        
        // If we only updated the current user contact then no need to continue
        guard
            !targetMembers.isEmpty,
            let groupId: SessionId = targetMembers.first.map({ try? SessionId(from: $0.groupId) }),
            groupId.prefix == .group
        else { return updated }
        
        // Loop through each of the groups and update their settings
        try targetMembers.forEach { member in
            try LibSession.performAndPushChange(
                db,
                for: .groupMembers,
                sessionId: groupId,
                using: dependencies
            ) { config in
                guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
                
                // Only update members if they already exist in the group
                var cMemberId: [CChar] = member.profileId.cArray
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
            
            let memberId: String = String(cString: withUnsafeBytes(of: member.session_id) { [UInt8]($0) }
                .map { CChar($0) }
                .nullTerminated()
            )
            
            result.append(
                GroupMember(
                    groupId: groupSessionId.hexString,
                    profileId: memberId,
                    role: (member.admin || (member.promoted > 0) ? .admin : .standard),
                    roleStatus: {
                        switch (member.invited, member.promoted, member.admin) {
                            case (2, _, _), (_, 2, false): return .failed           // Explicitly failed
                            case (1..., _, _), (_, 1..., false): return .pending    // Pending if not accepted
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
            
            let memberId: String = String(cString: withUnsafeBytes(of: member.session_id) { [UInt8]($0) }
                .map { CChar($0) }
                .nullTerminated()
            )
            
            result[memberId] = (member.removed == 2)
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
            
            let memberId: String = String(cString: withUnsafeBytes(of: member.session_id) { [UInt8]($0) }
                .map { CChar($0) }
                .nullTerminated()
            )
            let profilePictureUrl: String? = String(libSessionVal: member.profile_pic.url, nullIfEmpty: true)
            
            result.append(
                Profile(
                    id: memberId,
                    name: String(libSessionVal: member.name),
                    lastNameUpdate: TimeInterval(Double(serverTimestampMs) / 1000),
                    nickname: nil,
                    profilePictureUrl: profilePictureUrl,
                    profileEncryptionKey: (profilePictureUrl == nil ? nil :
                        Data(
                            libSessionVal: member.profile_pic.key,
                            count: DisplayPictureManager.aes256KeyByteLength
                        )
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
