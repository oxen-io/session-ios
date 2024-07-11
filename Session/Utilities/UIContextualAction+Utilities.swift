// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
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
        navigatableStateHolder: NavigatableStateHolder?
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
            .map { index, action -> UIContextualAction in
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
                                        )
                                    )
                                        
                                    case false: threadViewModel.markAsUnread()
                                }
                            }
                            completionHandler(true)
                        }
                        
                    // MARK: -- hide
                        
                    case .hide:
                        return UIContextualAction(
                            title: "hide".localized(),
                            icon: UIImage(systemName: "eye.slash"),
                            themeTintColor: .white,
                            themeBackgroundColor: themeBackgroundColor,
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { _, _, completionHandler  in
                            switch threadViewModel.threadId {
                                case SessionThreadViewModel.messageRequestsSectionId:
                                    Storage.shared.write { db in db[.hasHiddenMessageRequests] = true }
                                    completionHandler(true)
                                    
                                default:
                                    let confirmationModalExplanation: NSAttributedString = {
                                        let message = String(
                                            format: "noteToSelfHideDescription".localized(),
                                            threadViewModel.displayName
                                        )
                                        
                                        return NSAttributedString(string: message)
                                            .adding(
                                                attributes: [
                                                    .font: UIFont.boldSystemFont(ofSize: Values.smallFontSize)
                                                ],
                                                range: (message as NSString).range(of: threadViewModel.displayName)
                                            )
                                    }()
                                    
                                    let confirmationModal: ConfirmationModal = ConfirmationModal(
                                        info: ConfirmationModal.Info(
                                            title: "noteToSelfHide".localized(),
                                            body: .attributedText(confirmationModalExplanation),
                                            confirmTitle: "hide".localized(),
                                            confirmAccessibility: Accessibility(
                                                identifier: "Hide"
                                            ),
                                            confirmStyle: .danger,
                                            cancelStyle: .alert_text,
                                            dismissOnConfirm: true,
                                            onConfirm: { _ in
                                                Storage.shared.writeAsync { db in
                                                    try SessionThread.deleteOrLeave(
                                                        db,
                                                        threadId: threadViewModel.threadId,
                                                        threadVariant: threadViewModel.threadVariant,
                                                        groupLeaveType: .silent,
                                                        calledFromConfigHandling: false
                                                    )
                                                }
                                                viewController?.dismiss(animated: true, completion: nil)
                                                
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
                                Storage.shared.writeAsync { db in
                                    try SessionThread
                                        .filter(id: threadViewModel.threadId)
                                        .updateAllAndConfig(
                                            db,
                                            SessionThread.Columns.pinnedPriority
                                                .set(to: (threadViewModel.threadPinnedPriority == 0 ? 1 : 0))
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
                                Storage.shared.writeAsync { db in
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
                        return UIContextualAction(
                            title: (threadViewModel.threadIsBlocked == true ?
                                "blockUnblock".localized() :
                                "block".localized()
                            ),
                            icon: UIImage(named: "table_ic_block"),
                            iconHeight: Values.mediumFontSize,
                            themeTintColor: .white,
                            themeBackgroundColor: themeBackgroundColor,
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { [weak viewController] _, _, completionHandler in
                            let threadIsBlocked: Bool = (threadViewModel.threadIsBlocked == true)
                            let threadIsMessageRequest: Bool = (threadViewModel.threadIsMessageRequest == true)
                            let contactChanges: [ConfigColumnAssignment] = [
                                Contact.Columns.isBlocked.set(to: !threadIsBlocked),
                                
                                /// **Note:** We set `didApproveMe` to `true` so the current user will be able to send a
                                /// message to the person who originally sent them the message request in the future if they
                                /// unblock them
                                (!threadIsMessageRequest ? nil : Contact.Columns.didApproveMe.set(to: true)),
                                (!threadIsMessageRequest ? nil : Contact.Columns.isApproved.set(to: false))
                            ].compactMap { $0 }
                            
                            let performBlock: (UIViewController?) -> () = { viewController in
                                (tableView.cellForRow(at: indexPath) as? SwipeActionOptimisticCell)?
                                    .optimisticUpdate(
                                        isBlocked: !threadIsBlocked
                                    )
                                viewController?.dismiss(animated: true, completion: nil)
                                completionHandler(true)
                                
                                // Delay the change to give the cell "unswipe" animation some time to complete
                                DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + unswipeAnimationDelay) {
                                    Storage.shared
                                        .writePublisher { db in
                                            // Create the contact if it doesn't exist
                                            try Contact
                                                .fetchOrCreate(db, id: threadViewModel.threadId)
                                                .save(db)
                                            try Contact
                                                .filter(id: threadViewModel.threadId)
                                                .updateAllAndConfig(db, contactChanges)
                                            
                                            // Blocked message requests should be deleted
                                            if threadIsMessageRequest {
                                                try SessionThread.deleteOrLeave(
                                                    db,
                                                    threadId: threadViewModel.threadId,
                                                    threadVariant: .contact,
                                                    groupLeaveType: .silent,
                                                    calledFromConfigHandling: false
                                                )
                                            }
                                        }
                                        .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                                        .sinkUntilComplete()
                                }
                            }
                                
                            switch threadIsMessageRequest {
                                case false: performBlock(nil)
                                case true:
                                    let confirmationModal: ConfirmationModal = ConfirmationModal(
                                        info: ConfirmationModal.Info(
                                            title: "blockDescription"
                                                .put(key: "name", value: threadViewModel.displayName)
                                                .localized(),
                                            confirmTitle: "block".localized(),
                                            confirmAccessibility: Accessibility(
                                                identifier: "Block"
                                            ),
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
                                if threadViewModel.currentUserIsClosedGroupAdmin == true {
                                    return "groupOnlyAdmin"
                                        .put(key: "group_name", value: threadViewModel.displayName)
                                        .localizedFormatted(baseFont: .boldSystemFont(ofSize: Values.smallFontSize))
                                }
                                
                                return "communityLeaveDescription"
                                    .put(key: "community_name", value: threadViewModel.displayName)
                                    .localizedFormatted(baseFont: .boldSystemFont(ofSize: Values.smallFontSize))
                            }()
                            
                            let confirmationModal: ConfirmationModal = ConfirmationModal(
                                info: ConfirmationModal.Info(
                                    title: confirmationModalTitle,
                                    body: .attributedText(confirmationModalExplanation),
                                    confirmTitle: "leave".localized(),
                                    confirmAccessibility: Accessibility(
                                        identifier: "Leave"
                                    ),
                                    confirmStyle: .danger,
                                    cancelStyle: .alert_text,
                                    dismissOnConfirm: true,
                                    onConfirm: { _ in
                                        Storage.shared.writeAsync { db in
                                            do {
                                                try SessionThread.deleteOrLeave(
                                                    db,
                                                    threadId: threadViewModel.threadId,
                                                    threadVariant: threadViewModel.threadVariant,
                                                    groupLeaveType: .standard,
                                                    calledFromConfigHandling: false
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
                                        viewController?.dismiss(animated: true, completion: nil)
                                        
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
                            icon: UIImage(named: "icon_bin"),
                            iconHeight: Values.mediumFontSize,
                            themeTintColor: .white,
                            themeBackgroundColor: themeBackgroundColor,
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
                                    return NSAttributedString(
                                        string: "messageRequestsDelete".localized()
                                    )
                                }
                                guard threadViewModel.currentUserIsClosedGroupAdmin == false else {
                                    return "groupOnlyAdmin"
                                        .put(key: "group_name", value: threadViewModel.displayName)
                                        .localizedFormatted(baseFont: .boldSystemFont(ofSize: Values.smallFontSize))
                                }
                                
                                switch threadViewModel.threadVariant {
                                    case .contact:
                                        return "conversationsDeleteDescription"
                                            .put(key: "name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: .boldSystemFont(ofSize: Values.smallFontSize))
                                        
                                    case .legacyGroup, .group:
                                        return "groupDeleteDescription"
                                            .put(key: "group_name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: .boldSystemFont(ofSize: Values.smallFontSize))
                                        
                                    case .community:
                                        return "communityLeaveDescription"
                                            .put(key: "community_name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: .boldSystemFont(ofSize: Values.smallFontSize))
                                }
                            }()
                            
                            let confirmationModal: ConfirmationModal = ConfirmationModal(
                                info: ConfirmationModal.Info(
                                    title: confirmationModalTitle,
                                    body: .attributedText(confirmationModalExplanation),
                                    confirmTitle: "delete".localized(),
                                    confirmAccessibility: Accessibility(
                                        identifier: "Confirm delete"
                                    ),
                                    confirmStyle: .danger,
                                    cancelStyle: .alert_text,
                                    dismissOnConfirm: true,
                                    onConfirm: { _ in
                                        Storage.shared.writeAsync { db in
                                            try SessionThread.deleteOrLeave(
                                                db,
                                                threadId: threadViewModel.threadId,
                                                threadVariant: threadViewModel.threadVariant,
                                                groupLeaveType: (isMessageRequest ? .silent : .forced),
                                                calledFromConfigHandling: false
                                            )
                                        }
                                        viewController?.dismiss(animated: true, completion: nil)
                                        
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
