// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import SessionMessagingKit
import SessionUIKit
import SessionUtilitiesKit

protocol SwipeActionOptimisticCell {
    func optimisticUpdate(isMuted: Bool?, isBlocked: Bool?, isPinned: Bool?, hasUnread: Bool?)
}

extension SwipeActionOptimisticCell {
    public func optimisticUpdate(isMuted: Bool) {
        optimisticUpdate(isMuted: isMuted, isBlocked: nil, isPinned: nil, hasUnread: nil)
    }
    
    public func optimisticUpdate(isBlocked: Bool) {
        optimisticUpdate(isMuted: nil, isBlocked: isBlocked, isPinned: nil, hasUnread: nil)
    }
    
    public func optimisticUpdate(isPinned: Bool) {
        optimisticUpdate(isMuted: nil, isBlocked: nil, isPinned: isPinned, hasUnread: nil)
    }
    
    public func optimisticUpdate(hasUnread: Bool) {
        optimisticUpdate(isMuted: nil, isBlocked: nil, isPinned: nil, hasUnread: hasUnread)
    }
}

public extension UIContextualAction {
    enum SwipeAction {
        case toggleReadStatus
        case hide
        case pin
        case mute
        case block
        case leave
        case delete
        case clear
    }
    
    static func configuration(for actions: [UIContextualAction]?) -> UISwipeActionsConfiguration? {
        return actions.map { UISwipeActionsConfiguration(actions: $0) }
    }
    
    static func generateSwipeActions(
        _ actions: [SwipeAction],
        for side: UIContextualAction.Side,
        indexPath: IndexPath,
        tableView: UITableView,
        threadViewModel: SessionThreadViewModel,
        viewController: UIViewController?,
        navigatableStateHolder: NavigatableStateHolder?,
        using dependencies: Dependencies
    ) -> [UIContextualAction]? {
        guard !actions.isEmpty else { return nil }
        
        let unswipeAnimationDelay: DispatchTimeInterval = .milliseconds(500)
        
        // Note: for some reason the `UISwipeActionsConfiguration` expects actions to be left-to-right
        // for leading actions, but right-to-left for trailing actions...
        let targetActions: [SwipeAction] = (side == .trailing ? actions.reversed() : actions)
        let actionBackgroundColor: [ThemeValue] = [
            .conversationButton_swipeDestructive,
            .conversationButton_swipeSecondary,
            .conversationButton_swipeTertiary
        ]
        
        return targetActions
            .enumerated()
            .compactMap { index, action -> UIContextualAction? in
                // Even though we have to reverse the actions above, the indexes in the view hierarchy
                // are in the expected order
                let targetIndex: Int = (side == .trailing ? (targetActions.count - index) : index)
                let themeBackgroundColor: ThemeValue = actionBackgroundColor[
                    index % actionBackgroundColor.count
                ]
                
                switch action {
                    // MARK: -- toggleReadStatus
                        
                    case .toggleReadStatus:
                        let isUnread: Bool = (
                            threadViewModel.threadWasMarkedUnread == true ||
                            (threadViewModel.threadUnreadCount ?? 0) > 0
                        )
                        
                        return UIContextualAction(
                            title: (isUnread ?
                                "messageMarkRead".localized() :
                                "messageMarkUnread".localized()
                            ),
                            icon: (isUnread ?
                                UIImage(systemName: "envelope.open") :
                                UIImage(systemName: "envelope.badge")
                            ),
                            themeTintColor: .white,
                            themeBackgroundColor: .conversationButton_swipeRead,    // Always Custom
                            accessibility: Accessibility(identifier: (isUnread ? "Mark Read button" : "Mark Unread button")),
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { _, _, completionHandler  in
                            // Delay the change to give the cell "unswipe" animation some time to complete
                            DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + unswipeAnimationDelay) {
                                switch isUnread {
                                    case true: threadViewModel.markAsRead(
                                        target: .threadAndInteractions(
                                            interactionsBeforeInclusive: threadViewModel.interactionId
                                        ),
                                        using: dependencies
                                    )
                                        
                                    case false: threadViewModel.markAsUnread(using: dependencies)
                                }
                            }
                            completionHandler(true)
                        }
                    
                    // MARK: -- clear
                    
                    case .clear:
                        return UIContextualAction(
                            title: "clear".localized(),
                            icon: UIImage(named: "ic_bin"),
                            themeTintColor: .white,
                            themeBackgroundColor: themeBackgroundColor,
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { _, _, completionHandler  in
                            let confirmationModal: ConfirmationModal = ConfirmationModal(
                                info: ConfirmationModal.Info(
                                    title: "clearMessages".localized(),
                                    body: .text("clearMessagesNoteToSelfDescription".localized()),
                                    confirmTitle: "clear".localized(),
                                    confirmStyle: .danger,
                                    cancelStyle: .alert_text,
                                    dismissOnConfirm: true,
                                    onConfirm: { _ in
                                        dependencies[singleton: .storage].writeAsync { db in
                                            try SessionThread.deleteOrLeave(
                                                db,
                                                type: .deleteContactConversationAndMarkHidden,
                                                threadId: threadViewModel.threadId,
                                                threadVariant: threadViewModel.threadVariant,
                                                calledFromConfig: nil,
                                                using: dependencies
                                            )
                                        }
                                        
                                        completionHandler(true)
                                    },
                                    afterClosed: { completionHandler(false) }
                                )
                            )
                            
                            viewController?.present(confirmationModal, animated: true, completion: nil)
                        }
                        
                    // MARK: -- hide
                        
                    case .hide:
                        return UIContextualAction(
                            title: "hide".localized(),
                            icon: UIImage(systemName: "eye.slash"),
                            themeTintColor: .white,
                            themeBackgroundColor: themeBackgroundColor,
                            accessibility: Accessibility(identifier: "Hide button"),
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { _, _, completionHandler  in
                            switch threadViewModel.threadId {
                                case SessionThreadViewModel.messageRequestsSectionId:
                                    dependencies[singleton: .storage].write { db in
                                        db[.hasHiddenMessageRequests] = true
                                    }
                                    completionHandler(true)
                                    
                                default:
                                    let confirmationModal: ConfirmationModal = ConfirmationModal(
                                        info: ConfirmationModal.Info(
                                            title: "noteToSelfHide".localized(),
                                            body: .text("noteToSelfHideDescription".localized()),
                                            confirmTitle: "hide".localized(),
                                            confirmStyle: .danger,
                                            cancelStyle: .alert_text,
                                            dismissOnConfirm: true,
                                            onConfirm: { _ in
                                                dependencies[singleton: .storage].writeAsync { db in
                                                    try SessionThread.deleteOrLeave(
                                                        db,
                                                        type: .hideContactConversation,
                                                        threadId: threadViewModel.threadId,
                                                        threadVariant: threadViewModel.threadVariant,
                                                        calledFromConfig: nil,
                                                        using: dependencies
                                                    )
                                                }
                                                
                                                completionHandler(true)
                                            },
                                            afterClosed: { completionHandler(false) }
                                        )
                                    )
                                    
                                    viewController?.present(confirmationModal, animated: true, completion: nil)
                            }
                        }
                        
                    // MARK: -- pin
                        
                    case .pin:
                        return UIContextualAction(
                            title: (threadViewModel.threadPinnedPriority > 0 ?
                                "pinUnpin".localized() :
                                "pin".localized()
                            ),
                            icon: (threadViewModel.threadPinnedPriority > 0 ?
                                UIImage(systemName: "pin.slash") :
                                UIImage(systemName: "pin")
                            ),
                            themeTintColor: .white,
                            themeBackgroundColor: .conversationButton_swipeTertiary,    // Always Tertiary
                            accessibility: Accessibility(
                                identifier: (threadViewModel.threadPinnedPriority > 0 ? "Pin button" : "Unpin button")
                            ),
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { _, _, completionHandler in
                            (tableView.cellForRow(at: indexPath) as? SwipeActionOptimisticCell)?
                                .optimisticUpdate(
                                    isPinned: !(threadViewModel.threadPinnedPriority > 0)
                                )
                            completionHandler(true)
                            
                            // Delay the change to give the cell "unswipe" animation some time to complete
                            DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + unswipeAnimationDelay) {
                                dependencies[singleton: .storage].writeAsync { db in
                                    try SessionThread
                                        .filter(id: threadViewModel.threadId)
                                        .updateAllAndConfig(
                                            db,
                                            SessionThread.Columns.pinnedPriority
                                                .set(to: (threadViewModel.threadPinnedPriority == 0 ? 1 : 0)),
                                            calledFromConfig: nil,
                                            using: dependencies
                                        )
                                }
                            }
                        }

                    // MARK: -- mute

                    case .mute:
                        return UIContextualAction(
                            title: (threadViewModel.threadMutedUntilTimestamp == nil ?
                                "notificationsMute".localized() :
                                "notificationsMuteUnmute".localized()
                            ),
                            icon: (threadViewModel.threadMutedUntilTimestamp == nil ?
                                UIImage(systemName: "speaker.slash") :
                                UIImage(systemName: "speaker")
                            ),
                            iconHeight: Values.mediumFontSize,
                            themeTintColor: .white,
                            themeBackgroundColor: themeBackgroundColor,
                            accessibility: Accessibility(
                                identifier: (threadViewModel.threadMutedUntilTimestamp == nil ? "Mute button" : "Unmute button")
                            ),
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { _, _, completionHandler in
                            (tableView.cellForRow(at: indexPath) as? SwipeActionOptimisticCell)?
                                .optimisticUpdate(
                                    isMuted: !(threadViewModel.threadMutedUntilTimestamp != nil)
                                )
                            completionHandler(true)
                            
                            // Delay the change to give the cell "unswipe" animation some time to complete
                            DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + unswipeAnimationDelay) {
                                dependencies[singleton: .storage].writeAsync { db in
                                    let currentValue: TimeInterval? = try SessionThread
                                        .filter(id: threadViewModel.threadId)
                                        .select(.mutedUntilTimestamp)
                                        .asRequest(of: TimeInterval.self)
                                        .fetchOne(db)
                                    
                                    try SessionThread
                                        .filter(id: threadViewModel.threadId)
                                        .updateAll(
                                            db,
                                            SessionThread.Columns.mutedUntilTimestamp.set(
                                                to: (currentValue == nil ?
                                                    Date.distantFuture.timeIntervalSince1970 :
                                                    nil
                                                )
                                            )
                                        )
                                }
                            }
                        }
                        
                    // MARK: -- block
                        
                    case .block:
                        /// If we don't have the `profileInfo` then we can't actually block so don't offer the block option in that case
                        guard
                            let profileInfo: (id: String, profile: Profile?) = dependencies[singleton: .storage]
                                .read({ db in
                                switch threadViewModel.threadVariant {
                                    case .contact:
                                        return (
                                            threadViewModel.threadId,
                                            try Profile.fetchOne(db, id: threadViewModel.threadId)
                                        )
                                        
                                    case .group:
                                        let firstAdmin: GroupMember? = try GroupMember
                                            .filter(GroupMember.Columns.groupId == threadViewModel.threadId)
                                            .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                                            .fetchOne(db)
                                        
                                        return try firstAdmin
                                            .map { admin in
                                                (
                                                    admin.profileId,
                                                    try Profile.fetchOne(db, id: admin.profileId)
                                                )
                                            }
                                        
                                    default: return nil
                                }
                            })
                        else { return nil }
                        
                        return UIContextualAction(
                            title: (threadViewModel.threadIsBlocked == true ?
                                "blockUnblock".localized() :
                                "block".localized()
                            ),
                            icon: UIImage(named: "table_ic_block"),
                            iconHeight: Values.mediumFontSize,
                            themeTintColor: .white,
                            themeBackgroundColor: themeBackgroundColor,
                            accessibility: Accessibility(identifier: "Block button"),
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { [weak viewController] _, _, completionHandler in
                            let threadIsBlocked: Bool = (threadViewModel.threadIsBlocked == true)
                            let threadIsContactMessageRequest: Bool = (
                                threadViewModel.threadVariant == .contact &&
                                threadViewModel.threadIsMessageRequest == true
                            )
                            let contactChanges: [ConfigColumnAssignment] = [
                                Contact.Columns.isBlocked.set(to: !threadIsBlocked),
                                
                                /// **Note:** We set `didApproveMe` to `true` so the current user will be able to send a
                                /// message to the person who originally sent them the message request in the future if they
                                /// unblock them
                                (!threadIsContactMessageRequest ? nil : Contact.Columns.didApproveMe.set(to: true)),
                                (!threadIsContactMessageRequest ? nil : Contact.Columns.isApproved.set(to: false))
                            ].compactMap { $0 }
                            
                            let performBlock: (UIViewController?) -> () = { viewController in
                                (tableView.cellForRow(at: indexPath) as? SwipeActionOptimisticCell)?
                                    .optimisticUpdate(
                                        isBlocked: !threadIsBlocked
                                    )
                                completionHandler(true)
                                
                                // Delay the change to give the cell "unswipe" animation some time to complete
                                DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + unswipeAnimationDelay) {
                                    dependencies[singleton: .storage]
                                        .writePublisher { db in
                                            // Create the contact if it doesn't exist
                                            switch threadViewModel.threadVariant {
                                                case .contact:
                                                    try Contact
                                                        .fetchOrCreate(db, id: threadViewModel.threadId, using: dependencies)
                                                        .upsert(db)
                                                    try Contact
                                                        .filter(id: threadViewModel.threadId)
                                                        .updateAllAndConfig(
                                                            db,
                                                            contactChanges,
                                                            calledFromConfig: nil,
                                                            using: dependencies
                                                        )
                                                    
                                                case .group:
                                                    try Contact
                                                        .fetchOrCreate(db, id: profileInfo.id, using: dependencies)
                                                        .upsert(db)
                                                    try Contact
                                                        .filter(id: profileInfo.id)
                                                        .updateAllAndConfig(
                                                            db,
                                                            contactChanges,
                                                            calledFromConfig: nil,
                                                            using: dependencies
                                                        )
                                                    
                                                default: break
                                            }
                                            
                                            // Blocked message requests should be deleted
                                            if threadViewModel.threadIsMessageRequest == true {
                                                try SessionThread.deleteOrLeave(
                                                    db,
                                                    type: .deleteContactConversationAndMarkHidden,
                                                    threadId: threadViewModel.threadId,
                                                    threadVariant: threadViewModel.threadVariant,
                                                    calledFromConfig: nil,
                                                    using: dependencies
                                                )
                                            }
                                        }
                                        .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                                        .sinkUntilComplete()
                                }
                            }
                                
                            switch threadViewModel.threadIsMessageRequest == true {
                                case false: performBlock(nil)
                                case true:
                                    let nameToUse: String = {
                                        switch threadViewModel.threadVariant {
                                            case .group:
                                                return Profile.displayName(
                                                    for: .contact,
                                                    id: profileInfo.id,
                                                    name: profileInfo.profile?.name,
                                                    nickname: profileInfo.profile?.nickname,
                                                    suppressId: false
                                                )
                                                
                                            default: return threadViewModel.displayName
                                        }
                                    }()
                                    
                                    let confirmationModal: ConfirmationModal = ConfirmationModal(
                                        info: ConfirmationModal.Info(
                                            title: "block".localized(),
                                            body: .attributedText(
                                                "blockDescription"
                                                    .put(key: "name", value: nameToUse)
                                                    .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize))
                                            ),
                                            confirmTitle: "block".localized(),
                                            confirmStyle: .danger,
                                            cancelStyle: .alert_text,
                                            dismissOnConfirm: true,
                                            onConfirm: { _ in
                                                performBlock(viewController)
                                            },
                                            afterClosed: { completionHandler(false) }
                                        )
                                    )
                                    
                                    viewController?.present(confirmationModal, animated: true, completion: nil)
                            }
                        }

                    // MARK: -- leave

                    case .leave:
                        return UIContextualAction(
                            title: "leave".localized(),
                            icon: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                            iconHeight: Values.mediumFontSize,
                            themeTintColor: .white,
                            themeBackgroundColor: themeBackgroundColor,
                            accessibility: Accessibility(identifier: "Leave button"),
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { [weak viewController] _, _, completionHandler in
                            let confirmationModalTitle: String = {
                                switch threadViewModel.threadVariant {
                                    case .legacyGroup, .group:
                                        return "groupLeave".localized()
                                        
                                    default: return "communityLeave".localized()
                                }
                            }()
                            
                            let confirmationModalExplanation: NSAttributedString = {
                                switch (threadViewModel.threadVariant, threadViewModel.currentUserIsClosedGroupAdmin) {
                                    case (.group, true):
                                        return "groupLeaveDescriptionAdmin"
                                            .put(key: "group_name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: .boldSystemFont(ofSize: Values.smallFontSize))
                                    
                                    case (.legacyGroup, true):
                                        return "groupLeaveDescription"
                                            .put(key: "group_name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: .boldSystemFont(ofSize: Values.smallFontSize))
                                    
                                    default:
                                        return "groupLeaveDescription"
                                            .put(key: "group_name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: .boldSystemFont(ofSize: Values.smallFontSize))
                                }
                            }()
                            
                            let confirmationModal: ConfirmationModal = ConfirmationModal(
                                info: ConfirmationModal.Info(
                                    title: confirmationModalTitle,
                                    body: .attributedText(confirmationModalExplanation),
                                    confirmTitle: "leave".localized(),
                                    confirmStyle: .danger,
                                    cancelStyle: .alert_text,
                                    dismissOnConfirm: true,
                                    onConfirm: { _ in
                                        let deletionType: SessionThread.DeletionType = {
                                            switch threadViewModel.threadVariant {
                                                case .legacyGroup, .group: return .leaveGroupAsync
                                                default: return .deleteCommunityAndContent
                                            }
                                        }()
                                        
                                        dependencies[singleton: .storage].writeAsync { db in
                                            do {
                                                try SessionThread.deleteOrLeave(
                                                    db,
                                                    type: deletionType,
                                                    threadId: threadViewModel.threadId,
                                                    threadVariant: threadViewModel.threadVariant,
                                                    calledFromConfig: nil,
                                                    using: dependencies
                                                )
                                            } catch {
                                                DispatchQueue.main.async {
                                                    let toastBody: String = {
                                                        switch threadViewModel.threadVariant {
                                                            case .legacyGroup, .group:
                                                                return "groupLeaveErrorFailed"
                                                                    .put(key: "group_name", value: threadViewModel.displayName)
                                                                    .localized()
                                                                
                                                            default:
                                                                return "communityLeaveError"
                                                                    .put(key: "community_name", value: threadViewModel.displayName)
                                                                    .localized()
                                                        }
                                                    }()
                                                    navigatableStateHolder?.showToast(
                                                        text: toastBody,
                                                        backgroundColor: .backgroundSecondary
                                                    )
                                                }
                                            }
                                        }
                                        
                                        completionHandler(true)
                                    },
                                    afterClosed: { completionHandler(false) }
                                )
                            )
                            
                            viewController?.present(confirmationModal, animated: true, completion: nil)
                        }
                        
                    // MARK: -- delete
                        
                    case .delete:
                        return UIContextualAction(
                            title: "delete".localized(),
                            icon: UIImage(named: "ic_bin"),
                            themeTintColor: .white,
                            themeBackgroundColor: themeBackgroundColor,
                            accessibility: Accessibility(identifier: "Delete button"),
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { [weak viewController] _, _, completionHandler in
                            let isMessageRequest: Bool = (threadViewModel.threadIsMessageRequest == true)
                            let confirmationModalTitle: String = {
                                switch (threadViewModel.threadVariant, isMessageRequest) {
                                    case (_, true): return "delete".localized()
                                    case (.contact, _):
                                        return "conversationsDelete".localized()
                                        
                                    case (.legacyGroup, _), (.group, _):
                                        return "groupDelete".localized()
                                        
                                    case (.community, _): return "delete".localized()
                                }
                            }()
                            let confirmationModalExplanation: NSAttributedString = {
                                guard !isMessageRequest else {
                                    switch threadViewModel.threadVariant {
                                        case .group: return NSAttributedString(string: "groupInviteDelete".localized())
                                        default: return NSAttributedString(string: "messageRequestsDelete".localized())
                                    }
                                }
                                
                                guard threadViewModel.currentUserIsClosedGroupAdmin == false else {
                                    return "groupDeleteDescription"
                                        .put(key: "group_name", value: threadViewModel.displayName)
                                        .localizedFormatted(baseFont: .boldSystemFont(ofSize: Values.smallFontSize))
                                }
                                
                                switch threadViewModel.threadVariant {
                                    case .contact:
                                        return "conversationsDeleteDescription"
                                            .put(key: "name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: .boldSystemFont(ofSize: Values.smallFontSize))
                                        
                                    default:
                                        return "groupDeleteDescriptionMember"
                                            .put(key: "group_name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: .boldSystemFont(ofSize: Values.smallFontSize))
                                }
                            }()
                            
                            let confirmationModal: ConfirmationModal = ConfirmationModal(
                                info: ConfirmationModal.Info(
                                    title: confirmationModalTitle,
                                    body: .attributedText(confirmationModalExplanation),
                                    confirmTitle: "delete".localized(),
                                    confirmStyle: .danger,
                                    cancelStyle: .alert_text,
                                    dismissOnConfirm: true,
                                    onConfirm: { _ in
                                        let deletionType: SessionThread.DeletionType = {
                                            switch (threadViewModel.threadVariant, isMessageRequest) {
                                                case (.community, _): return .deleteCommunityAndContent
                                                case (.group, true): return .deleteGroupAndContent
                                                case (.group, _), (.legacyGroup, _):
                                                    return .leaveGroupAsync
                                                
                                                case (.contact, _): return .deleteContactConversationAndMarkHidden
                                            }
                                        }()
                                        
                                        dependencies[singleton: .storage].writeAsync { db in
                                            try SessionThread.deleteOrLeave(
                                                db,
                                                type: deletionType,
                                                threadId: threadViewModel.threadId,
                                                threadVariant: threadViewModel.threadVariant,
                                                calledFromConfig: nil,
                                                using: dependencies
                                            )
                                        }
                                        
                                        completionHandler(true)
                                    },
                                    afterClosed: { completionHandler(false) }
                                )
                            )
                            
                            viewController?.present(confirmationModal, animated: true, completion: nil)
                        }
                }
            }
    }
}
