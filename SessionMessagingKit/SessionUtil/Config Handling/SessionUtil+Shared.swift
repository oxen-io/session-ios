// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import SessionUIKit
import SessionUtil
import SessionUtilitiesKit

// MARK: - Convenience

internal extension SessionUtil {
    static let columnsRelatedToThreads: [ColumnExpression] = [
        SessionThread.Columns.pinnedPriority,
        SessionThread.Columns.shouldBeVisible
    ]
    
    static func assignmentsRequireConfigUpdate(_ assignments: [ConfigColumnAssignment]) -> Bool {
        let targetColumns: Set<ColumnKey> = Set(assignments.map { ColumnKey($0.column) })
        let allColumnsThatTriggerConfigUpdate: Set<ColumnKey> = []
            .appending(contentsOf: columnsRelatedToUserProfile)
            .appending(contentsOf: columnsRelatedToContacts)
            .appending(contentsOf: columnsRelatedToConvoInfoVolatile)
            .appending(contentsOf: columnsRelatedToUserGroups)
            .appending(contentsOf: columnsRelatedToThreads)
            .map { ColumnKey($0) }
            .asSet()
        
        return !allColumnsThatTriggerConfigUpdate.isDisjoint(with: targetColumns)
    }
    
    /// A negative `priority` value indicates hidden
    static let hiddenPriority: Int32 = -1
    
    static func shouldBeVisible(priority: Int32) -> Bool {
        return (priority >= 0)
    }
    
    static func performAndPushChange(
        _ db: Database,
        for variant: ConfigDump.Variant,
        publicKey: String,
        change: (UnsafeMutablePointer<config_object>?) throws -> ()
    ) throws {
        // FIXME: Remove this once `useSharedUtilForUserConfig` is permanent
        guard SessionUtil.userConfigsEnabled(db, ignoreRequirementsForRunningMigrations: true) else { return }
        
        // Since we are doing direct memory manipulation we are using an `Atomic`
        // type which has blocking access in it's `mutate` closure
        let needsPush: Bool
        
        do {
            needsPush = try SessionUtil
                .config(
                    for: variant,
                    publicKey: publicKey
                )
                .mutate { conf in
                    guard conf != nil else { throw SessionUtilError.nilConfigObject }
                    
                    // Peform the change
                    try change(conf)
                    
                    // If we don't need to dump the data the we can finish early
                    guard config_needs_dump(conf) else { return config_needs_push(conf) }
                    
                    try SessionUtil.createDump(
                        conf: conf,
                        for: variant,
                        publicKey: publicKey
                    )?.save(db)
                    
                    return config_needs_push(conf)
                }
        }
        catch {
            SNLog("[libSession] Failed to update/dump updated \(variant) config data")
            throw error
        }
        
        // Make sure we need a push before scheduling one
        guard needsPush else { return }
        
        db.afterNextTransactionNestedOnce(dedupeId: SessionUtil.syncDedupeId(publicKey)) { db in
            ConfigurationSyncJob.enqueue(db, publicKey: publicKey)
        }
    }
    
    @discardableResult static func updatingThreads<T>(_ db: Database, _ updated: [T]) throws -> [T] {
        guard let updatedThreads: [SessionThread] = updated as? [SessionThread] else {
            throw StorageError.generic
        }
        
        // If we have no updated threads then no need to continue
        guard !updatedThreads.isEmpty else { return updated }
        
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let groupedThreads: [SessionThread.Variant: [SessionThread]] = updatedThreads
            .grouped(by: \.variant)
        let urlInfo: [String: OpenGroupUrlInfo] = try OpenGroupUrlInfo
            .fetchAll(db, ids: updatedThreads.map { $0.id })
            .reduce(into: [:]) { result, next in result[next.threadId] = next }
        
        // Update the unread state for the threads first (just in case that's what changed)
        try SessionUtil.updateMarkedAsUnreadState(db, threads: updatedThreads)
        
        // Then update the `hidden` and `priority` values
        try groupedThreads.forEach { variant, threads in
            switch variant {
                case .contact:
                    // If the 'Note to Self' conversation is pinned then we need to custom handle it
                    // first as it's part of the UserProfile config
                    if let noteToSelf: SessionThread = threads.first(where: { $0.id == userPublicKey }) {
                        try SessionUtil.performAndPushChange(
                            db,
                            for: .userProfile,
                            publicKey: userPublicKey
                        ) { conf in
                            try SessionUtil.updateNoteToSelf(
                                priority: {
                                    guard noteToSelf.shouldBeVisible else { return SessionUtil.hiddenPriority }
                                    
                                    return noteToSelf.pinnedPriority
                                        .map { Int32($0 == 0 ? 0 : max($0, 1)) }
                                        .defaulting(to: 0)
                                }(),
                                in: conf
                            )
                        }
                    }
                    
                    // Remove the 'Note to Self' convo from the list for updating contact priorities
                    let remainingThreads: [SessionThread] = threads.filter { $0.id != userPublicKey }
                    
                    guard !remainingThreads.isEmpty else { return }
                    
                    try SessionUtil.performAndPushChange(
                        db,
                        for: .contacts,
                        publicKey: userPublicKey
                    ) { conf in
                        try SessionUtil.upsert(
                            contactData: remainingThreads
                                .map { thread in
                                    SyncedContactInfo(
                                        id: thread.id,
                                        priority: {
                                            guard thread.shouldBeVisible else { return SessionUtil.hiddenPriority }
                                            
                                            return thread.pinnedPriority
                                                .map { Int32($0 == 0 ? 0 : max($0, 1)) }
                                                .defaulting(to: 0)
                                        }()
                                    )
                                },
                            in: conf
                        )
                    }
                    
                case .community:
                    try SessionUtil.performAndPushChange(
                        db,
                        for: .userGroups,
                        publicKey: userPublicKey
                    ) { conf in
                        try SessionUtil.upsert(
                            communities: threads
                                .compactMap { thread -> CommunityInfo? in
                                    urlInfo[thread.id].map { urlInfo in
                                        CommunityInfo(
                                            urlInfo: urlInfo,
                                            priority: thread.pinnedPriority
                                                .map { Int32($0 == 0 ? 0 : max($0, 1)) }
                                                .defaulting(to: 0)
                                        )
                                    }
                                },
                            in: conf
                        )
                    }
                    
                case .legacyGroup:
                    try SessionUtil.performAndPushChange(
                        db,
                        for: .userGroups,
                        publicKey: userPublicKey
                    ) { conf in
                        try SessionUtil.upsert(
                            legacyGroups: threads
                                .map { thread in
                                    LegacyGroupInfo(
                                        id: thread.id,
                                        priority: thread.pinnedPriority
                                            .map { Int32($0 == 0 ? 0 : max($0, 1)) }
                                            .defaulting(to: 0)
                                    )
                                },
                            in: conf
                        )
                    }
                
                case .group:
                    break
            }
        }
        
        return updated
    }
    
    static func kickFromConversationUIIfNeeded(removedThreadIds: [String]) {
        guard !removedThreadIds.isEmpty else { return }
        
        // If the user is currently navigating somewhere within the view hierarchy of a conversation
        // we just deleted then return to the home screen
        DispatchQueue.main.async {
            guard
                let rootViewController: UIViewController = CurrentAppContext().mainWindow?.rootViewController,
                let topBannerController: TopBannerController = (rootViewController as? TopBannerController),
                !topBannerController.children.isEmpty,
                let navController: UINavigationController = topBannerController.children[0] as? UINavigationController
            else { return }
            
            // Extract the ones which will respond to SessionUtil changes
            let targetViewControllers: [any SessionUtilRespondingViewController] = navController
                .viewControllers
                .compactMap { $0 as? SessionUtilRespondingViewController }
            let presentedNavController: UINavigationController? = (navController.presentedViewController as? UINavigationController)
            let presentedTargetViewControllers: [any SessionUtilRespondingViewController] = (presentedNavController?
                .viewControllers
                .compactMap { $0 as? SessionUtilRespondingViewController })
                .defaulting(to: [])
            
            // Make sure we have a conversation list and that one of the removed conversations are
            // in the nav hierarchy
            let rootNavControllerNeedsPop: Bool = (
                targetViewControllers.count > 1 &&
                targetViewControllers.contains(where: { $0.isConversationList }) &&
                targetViewControllers.contains(where: { $0.isConversation(in: removedThreadIds) })
            )
            let presentedNavControllerNeedsPop: Bool = (
                presentedTargetViewControllers.count > 1 &&
                presentedTargetViewControllers.contains(where: { $0.isConversationList }) &&
                presentedTargetViewControllers.contains(where: { $0.isConversation(in: removedThreadIds) })
            )
            
            // Force the UI to refresh if needed (most screens should do this automatically via database
            // observation, but a couple of screens don't so need to be done manually)
            targetViewControllers
                .appending(contentsOf: presentedTargetViewControllers)
                .filter { $0.isConversationList }
                .forEach { $0.forceRefreshIfNeeded() }
            
            switch (rootNavControllerNeedsPop, presentedNavControllerNeedsPop) {
                case (true, false):
                    // Return to the conversation list as the removed conversation will be invalid
                    guard
                        let targetViewController: UIViewController = navController.viewControllers
                            .last(where: { viewController in
                                ((viewController as? SessionUtilRespondingViewController)?.isConversationList)
                                    .defaulting(to: false)
                            })
                    else { return }
                    
                    if navController.presentedViewController != nil {
                        navController.dismiss(animated: false) {
                            navController.popToViewController(targetViewController, animated: true)
                        }
                    }
                    else {
                        navController.popToViewController(targetViewController, animated: true)
                    }
                    
                case (false, true):
                    // Return to the conversation list as the removed conversation will be invalid
                    guard
                        let targetViewController: UIViewController = presentedNavController?
                            .viewControllers
                            .last(where: { viewController in
                                ((viewController as? SessionUtilRespondingViewController)?.isConversationList)
                                    .defaulting(to: false)
                            })
                    else { return }
                    
                    if presentedNavController?.presentedViewController != nil {
                        presentedNavController?.dismiss(animated: false) {
                            presentedNavController?.popToViewController(targetViewController, animated: true)
                        }
                    }
                    else {
                        presentedNavController?.popToViewController(targetViewController, animated: true)
                    }
                    
                default: break
            }
        }
    }
}

// MARK: - External Outgoing Changes

public extension SessionUtil {
    static func conversationInConfig(
        _ db: Database? = nil,
        threadId: String,
        threadVariant: SessionThread.Variant,
        visibleOnly: Bool
    ) -> Bool {
        // FIXME: Remove this once `useSharedUtilForUserConfig` is permanent
        guard SessionUtil.userConfigsEnabled(db) else { return true }
        
        let configVariant: ConfigDump.Variant = {
            switch threadVariant {
                case .contact: return .contacts
                case .legacyGroup, .group, .community: return .userGroups
            }
        }()
        
        return SessionUtil
            .config(for: configVariant, publicKey: getUserHexEncodedPublicKey())
            .wrappedValue
            .map { conf in
                var cThreadId: [CChar] = threadId.cArray.nullTerminated()
                
                switch threadVariant {
                    case .contact:
                        var contact: contacts_contact = contacts_contact()
                        
                        guard contacts_get(conf, &contact, &cThreadId) else { return false }
                        
                        /// If the user opens a conversation with an existing contact but doesn't send them a message
                        /// then the one-to-one conversation should remain hidden so we want to delete the `SessionThread`
                        /// when leaving the conversation
                        return (!visibleOnly || SessionUtil.shouldBeVisible(priority: contact.priority))
                        
                    case .community:
                        let maybeUrlInfo: OpenGroupUrlInfo? = Storage.shared
                            .read { db in try OpenGroupUrlInfo.fetchAll(db, ids: [threadId]) }?
                            .first
                        
                        guard let urlInfo: OpenGroupUrlInfo = maybeUrlInfo else { return false }
                        
                        var cBaseUrl: [CChar] = urlInfo.server.cArray.nullTerminated()
                        var cRoom: [CChar] = urlInfo.roomToken.cArray.nullTerminated()
                        var community: ugroups_community_info = ugroups_community_info()
                        
                        /// Not handling the `hidden` behaviour for communities so just indicate the existence
                        return user_groups_get_community(conf, &community, &cBaseUrl, &cRoom)
                        
                    case .legacyGroup:
                        let groupInfo: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf, &cThreadId)
                        
                        /// Not handling the `hidden` behaviour for legacy groups so just indicate the existence
                        if groupInfo != nil {
                            ugroups_legacy_group_free(groupInfo)
                            return true
                        }
                        
                        return false
                        
                    case .group:
                        return false
                }
            }
            .defaulting(to: false)
    }
}

// MARK: - ColumnKey

internal extension SessionUtil {
    struct ColumnKey: Equatable, Hashable {
        let sourceType: Any.Type
        let columnName: String
        
        init(_ column: ColumnExpression) {
            self.sourceType = type(of: column)
            self.columnName = column.name
        }
        
        func hash(into hasher: inout Hasher) {
            ObjectIdentifier(sourceType).hash(into: &hasher)
            columnName.hash(into: &hasher)
        }
        
        static func == (lhs: ColumnKey, rhs: ColumnKey) -> Bool {
            return (
                lhs.sourceType == rhs.sourceType &&
                lhs.columnName == rhs.columnName
            )
        }
    }
}

// MARK: - PriorityVisibilityInfo

extension SessionUtil {
    struct PriorityVisibilityInfo: Codable, FetchableRecord, Identifiable {
        let id: String
        let variant: SessionThread.Variant
        let pinnedPriority: Int32?
        let shouldBeVisible: Bool
    }
}

// MARK: - SessionUtilRespondingViewController

public protocol SessionUtilRespondingViewController {
    var isConversationList: Bool { get }
    
    func isConversation(in threadIds: [String]) -> Bool
    func forceRefreshIfNeeded()
}

public extension SessionUtilRespondingViewController {
    var isConversationList: Bool { false }
    
    func isConversation(in threadIds: [String]) -> Bool { return false }
    func forceRefreshIfNeeded() {}
}