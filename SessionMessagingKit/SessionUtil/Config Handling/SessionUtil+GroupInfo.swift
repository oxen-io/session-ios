// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Size Restrictions

public extension SessionUtil {
    static var sizeMaxGroupDescriptionBytes: Int { GROUP_INFO_DESCRIPTION_MAX_LENGTH }
    
    static func isTooLong(groupDescription: String) -> Bool {
        return (groupDescription.utf8CString.count > SessionUtil.sizeMaxGroupDescriptionBytes)
    }
}

// MARK: - Group Info Handling

internal extension SessionUtil {
    static let columnsRelatedToGroupInfo: [ColumnExpression] = [
        ClosedGroup.Columns.name,
        ClosedGroup.Columns.groupDescription,
        ClosedGroup.Columns.displayPictureUrl,
        ClosedGroup.Columns.displayPictureEncryptionKey,
        DisappearingMessagesConfiguration.Columns.isEnabled,
        DisappearingMessagesConfiguration.Columns.type,
        DisappearingMessagesConfiguration.Columns.durationSeconds
    ]
    
    // MARK: - Incoming Changes
    
    static func handleGroupInfoUpdate(
        _ db: Database,
        in config: Config?,
        groupSessionId: SessionId,
        serverTimestampMs: Int64,
        using dependencies: Dependencies
    ) throws {
        guard config.needsDump(using: dependencies) else { return }
        guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
        
        // If the group is destroyed then remove the group date (want to keep the group itself around because
        // the UX of conversations randomly disappearing isn't great) - no other changes matter and this
        // can't be reversed
        guard !groups_info_is_destroyed(conf) else {
            try ClosedGroup.removeData(
                db,
                threadIds: [groupSessionId.hexString],
                dataToRemove: [
                    .poller, .pushNotifications, .messages, .members,
                    .encryptionKeys, .authDetails, .libSessionState
                ],
                calledFromConfig: .groupInfo,
                using: dependencies
            )
            return
        }

        // A group must have a name so if this is null then it's invalid and can be ignored
        guard let groupNamePtr: UnsafePointer<CChar> = groups_info_get_name(conf) else { return }

        let groupDescPtr: UnsafePointer<CChar>? = groups_info_get_description(conf)
        let groupName: String = String(cString: groupNamePtr)
        let groupDesc: String? = groupDescPtr.map { String(cString: $0) }
        let formationTimestamp: TimeInterval = TimeInterval(groups_info_get_created(conf))
        
        // The `displayPic.key` can contain junk data so if the `displayPictureUrl` is null then just
        // set the `displayPictureKey` to null as well
        let displayPic: user_profile_pic = groups_info_get_pic(conf)
        let displayPictureUrl: String? = String(libSessionVal: displayPic.url, nullIfEmpty: true)
        let displayPictureKey: Data? = (displayPictureUrl == nil ? nil :
            Data(
                libSessionVal: displayPic.key,
                count: DisplayPictureManager.aes256KeyByteLength
            )
        )

        // Update the group name
        let existingGroup: ClosedGroup? = try? ClosedGroup
            .filter(id: groupSessionId.hexString)
            .fetchOne(db)
        let needsDisplayPictureUpdate: Bool = (
            existingGroup?.displayPictureUrl != displayPictureUrl ||
            existingGroup?.displayPictureEncryptionKey != displayPictureKey
        )

        let groupChanges: [ConfigColumnAssignment] = [
            ((existingGroup?.name == groupName) ? nil :
                ClosedGroup.Columns.name.set(to: groupName)
            ),
            ((existingGroup?.groupDescription == groupDesc) ? nil :
                ClosedGroup.Columns.groupDescription.set(to: groupDesc)
            ),
            // Only update the 'formationTimestamp' if we don't have one (don't want to override the 'joinedAt'
            // timestamp with the groups creation timestamp
            (formationTimestamp < (existingGroup?.formationTimestamp ?? 0) ? nil :
                ClosedGroup.Columns.formationTimestamp.set(to: formationTimestamp)
            ),
            // If we are removing the display picture do so here
            (!needsDisplayPictureUpdate || displayPictureUrl != nil ? nil :
                ClosedGroup.Columns.displayPictureUrl.set(to: nil)
            ),
            (!needsDisplayPictureUpdate || displayPictureUrl != nil ? nil :
                ClosedGroup.Columns.displayPictureFilename.set(to: nil)
            ),
            (!needsDisplayPictureUpdate || displayPictureUrl != nil ? nil :
                ClosedGroup.Columns.displayPictureEncryptionKey.set(to: nil)
            ),
            (!needsDisplayPictureUpdate || displayPictureUrl != nil ? nil :
                ClosedGroup.Columns.lastDisplayPictureUpdate.set(to: (serverTimestampMs / 1000))
            )
        ].compactMap { $0 }

        if !groupChanges.isEmpty {
            try ClosedGroup
                .filter(id: groupSessionId.hexString)
                .updateAllAndConfig(
                    db,
                    groupChanges,
                    calledFromConfig: .groupInfo,
                    using: dependencies
                )
        }

        // If we have a display picture then start downloading it
        if needsDisplayPictureUpdate, let url: String = displayPictureUrl, let key: Data = displayPictureKey {
            dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .displayPictureDownload,
                    shouldBeUnique: true,
                    details: DisplayPictureDownloadJob.Details(
                        target: .group(id: groupSessionId.hexString, url: url, encryptionKey: key),
                        timestamp: TimeInterval(Double(serverTimestampMs) / 1000)
                    )
                ),
                canStartJob: true,
                using: dependencies
            )
        }

        // Update the disappearing messages configuration
        let targetExpiry: Int32 = groups_info_get_expiry_timer(conf)
        let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
            .fetchOne(db, id: groupSessionId.hexString)
            .defaulting(to: DisappearingMessagesConfiguration.defaultWith(groupSessionId.hexString))
        let updatedConfig: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration
            .defaultWith(groupSessionId.hexString)
            .with(
                isEnabled: (targetExpiry > 0),
                durationSeconds: TimeInterval(targetExpiry),
                type: .disappearAfterSend
            )
        
        if localConfig != updatedConfig {
            try updatedConfig
                .saved(db)
                .clearUnrelatedControlMessages(
                    db,
                    threadVariant: .group,
                    using: dependencies
                )
        }
        
        // Check if the user is an admin in the group
        var messageHashesToDelete: Set<String> = []
        let isAdmin: Bool = ((try? ClosedGroup
            .filter(id: groupSessionId.hexString)
            .select(.groupIdentityPrivateKey)
            .asRequest(of: Data.self)
            .fetchOne(db)) != nil)

        // If there is a `delete_before` setting then delete all messages before the provided timestamp
        let deleteBeforeTimestamp: Int64 = groups_info_get_delete_before(conf)
        
        if deleteBeforeTimestamp > 0 {
            if isAdmin {
                let hashesToDelete: Set<String>? = try? Interaction
                    .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                    .filter(Interaction.Columns.timestampMs < (TimeInterval(deleteBeforeTimestamp) * 1000))
                    .filter(Interaction.Columns.serverHash != nil)
                    .select(.serverHash)
                    .asRequest(of: String.self)
                    .fetchSet(db)
                messageHashesToDelete.insert(contentsOf: hashesToDelete)
            }
            
            let deletionCount: Int = try Interaction
                .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                .filter(Interaction.Columns.timestampMs < (TimeInterval(deleteBeforeTimestamp) * 1000))
                .deleteAll(db)
            
            if deletionCount > 0 {
                SNLog("[SessionUtil] Deleted \(deletionCount) message\(plural: deletionCount) from \(groupSessionId.hexString) due to 'delete_before' value.")
            }
        }
        
        // If there is a `attach_delete_before` setting then delete all messages that have attachments before
        // the provided timestamp and schedule a garbage collection job
        let attachDeleteBeforeTimestamp: Int64 = groups_info_get_attach_delete_before(conf)
        
        if attachDeleteBeforeTimestamp > 0 {
            if isAdmin {
                let hashesToDelete: Set<String>? = try? Interaction
                    .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                    .filter(Interaction.Columns.timestampMs < (TimeInterval(attachDeleteBeforeTimestamp) * 1000))
                    .filter(Interaction.Columns.serverHash != nil)
                    .joining(required: Interaction.interactionAttachments)
                    .select(.serverHash)
                    .asRequest(of: String.self)
                    .fetchSet(db)
                messageHashesToDelete.insert(contentsOf: hashesToDelete)
            }
            
            let deletionCount: Int = try Interaction
                .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                .filter(Interaction.Columns.timestampMs < (TimeInterval(attachDeleteBeforeTimestamp) * 1000))
                .joining(required: Interaction.interactionAttachments)
                .deleteAll(db)
            
            if deletionCount > 0 {
                SNLog("[SessionUtil] Deleted \(deletionCount) message\(plural: deletionCount) with attachments from \(groupSessionId.hexString) due to 'attach_delete_before' value.")
                
                // Schedule a grabage collection job to clean up any now-orphaned attachment files
                dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .garbageCollection,
                        details: GarbageCollectionJob.Details(
                            typesToCollect: [.orphanedAttachments, .orphanedAttachmentFiles]
                        )
                    ),
                    canStartJob: true,
                    using: dependencies
                )
            }
        }
        
        // If the current user is a group admin and there are message hashes which should be deleted then
        // send a fire-and-forget API call to delete the messages from the swarm
        if isAdmin && !messageHashesToDelete.isEmpty {
            (try? Authentication.with(
                db,
                sessionIdHexString: groupSessionId.hexString,
                using: dependencies
            )).map { authMethod in
                try? SnodeAPI
                    .preparedDeleteMessages(
                        serverHashes: Array(messageHashesToDelete),
                        requireSuccessfulDeletion: false,
                        authMethod: authMethod,
                        using: dependencies
                    )
                    .send(using: dependencies)
                    .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
                    .sinkUntilComplete()
            }
        }
    }
}

// MARK: - Outgoing Changes

internal extension SessionUtil {
    static func updatingGroupInfo<T>(
        _ db: Database,
        _ updated: [T],
        using dependencies: Dependencies
    ) throws -> [T] {
        guard let updatedGroups: [ClosedGroup] = updated as? [ClosedGroup] else { throw StorageError.generic }
        
        // Exclude legacy groups as they aren't managed via SessionUtil
        let targetGroups: [ClosedGroup] = updatedGroups
            .filter { (try? SessionId(from: $0.id))?.prefix == .group }
        
        // If we only updated the current user contact then no need to continue
        guard !targetGroups.isEmpty else { return updated }
        
        // Loop through each of the groups and update their settings
        try targetGroups.forEach { group in
            try SessionUtil.performAndPushChange(
                db,
                for: .groupInfo,
                sessionId: SessionId(.group, hex: group.threadId),
                using: dependencies
            ) { config in
                guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
                
                /// Update the name
                ///
                /// **Note:** We indentionally only update the `GROUP_INFO` and not the `USER_GROUPS` as once the
                /// group is synced between devices we want to rely on the proper group config to get display info
                var updatedName: [CChar] = group.name.cArray.nullTerminated()
                groups_info_set_name(conf, &updatedName)
                
                var updatedDescription: [CChar] = (group.groupDescription ?? "").cArray.nullTerminated()
                groups_info_set_description(conf, &updatedDescription)
                
                // Either assign the updated display pic, or sent a blank pic (to remove the current one)
                var displayPic: user_profile_pic = user_profile_pic()
                displayPic.url = group.displayPictureUrl.toLibSession()
                displayPic.key = group.displayPictureEncryptionKey.toLibSession()
                groups_info_set_pic(conf, displayPic)
            }
        }
        
        return updated
    }
    
    static func updatingDisappearingConfigsGroups<T>(
        _ db: Database,
        _ updated: [T],
        using dependencies: Dependencies
    ) throws -> [T] {
        guard let updatedDisappearingConfigs: [DisappearingMessagesConfiguration] = updated as? [DisappearingMessagesConfiguration] else { throw StorageError.generic }
        
        // Filter out any disappearing config changes not related to updated groups
        let targetUpdatedConfigs: [DisappearingMessagesConfiguration] = updatedDisappearingConfigs
            .filter { (try? SessionId.Prefix(from: $0.id)) == .group }
        
        guard !targetUpdatedConfigs.isEmpty else { return updated }
        
        // We should only sync disappearing messages configs which are associated to existing groups
        let existingGroupIds: [String] = (try? ClosedGroup
            .filter(ids: targetUpdatedConfigs.map { $0.id })
            .select(.threadId)
            .asRequest(of: String.self)
            .fetchAll(db))
            .defaulting(to: [])
        
        // If none of the disappearing messages configs are associated with existing groups then ignore
        // the changes (no need to do a config sync)
        guard !existingGroupIds.isEmpty else { return updated }
        
        // Loop through each of the groups and update their settings
        try existingGroupIds
            .compactMap { groupId in targetUpdatedConfigs.first(where: { $0.id == groupId }).map { (groupId, $0) } }
            .forEach { groupId, updatedConfig in
                try SessionUtil.performAndPushChange(
                    db,
                    for: .groupInfo,
                    sessionId: SessionId(.group, hex: groupId),
                    using: dependencies
                ) { config in
                    guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
                    
                    groups_info_set_expiry_timer(conf, Int32(updatedConfig.durationSeconds))
                }
            }
        
        return updated
    }
}

// MARK: - External Outgoing Changes

public extension SessionUtil {
    static func update(
        _ db: Database,
        groupSessionId: SessionId,
        disappearingConfig: DisappearingMessagesConfiguration?,
        using dependencies: Dependencies
    ) throws {
        try SessionUtil.performAndPushChange(
            db,
            for: .groupInfo,
            sessionId: groupSessionId,
            using: dependencies
        ) { config in
            guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
            
            if let config: DisappearingMessagesConfiguration = disappearingConfig {
                groups_info_set_expiry_timer(conf, Int32(config.durationSeconds))
            }
        }
    }
    
    static func deleteMessagesBefore(
        _ db: Database,
        groupSessionId: SessionId,
        timestamp: TimeInterval,
        using dependencies: Dependencies
    ) throws {
        try SessionUtil.performAndPushChange(
            db,
            for: .groupInfo,
            sessionId: groupSessionId,
            using: dependencies
        ) { config in
            guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
            
            // Do nothing if the timestamp isn't newer than the current value
            guard Int64(timestamp) > groups_info_get_delete_before(conf) else { return }
            
            groups_info_set_delete_before(conf, Int64(timestamp))
        }
    }
    
    static func deleteAttachmentsBefore(
        _ db: Database,
        groupSessionId: SessionId,
        timestamp: TimeInterval,
        using dependencies: Dependencies
    ) throws {
        try SessionUtil.performAndPushChange(
            db,
            for: .groupInfo,
            sessionId: groupSessionId,
            using: dependencies
        ) { config in
            guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
            
            // Do nothing if the timestamp isn't newer than the current value
            guard Int64(timestamp) > groups_info_get_attach_delete_before(conf) else { return }
            
            groups_info_set_attach_delete_before(conf, Int64(timestamp))
        }
    }
    
    static func deleteGroupForEveryone(
        _ db: Database,
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws {
        try SessionUtil.performAndPushChange(
            db,
            for: .groupInfo,
            sessionId: groupSessionId,
            using: dependencies
        ) { config in
            guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
            
            groups_info_destroy_group(conf)
        }
    }
    
    static func groupIsDestroyed(
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) -> Bool {
        return dependencies[cache: .sessionUtil]
            .config(for: .groupInfo, sessionId: groupSessionId)
            .wrappedValue
            .map { config in
                guard case .object(let conf) = config else { return false }
                
                return groups_info_is_destroyed(conf)
            }
            .defaulting(to: false)
    }
}
