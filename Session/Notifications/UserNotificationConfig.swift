// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import UserNotifications
import SessionMessagingKit
import SignalCoreKit
import SignalUtilitiesKit
import SessionUtilitiesKit

class UserNotificationConfig {
    class var allNotificationCategories: Set<UNNotificationCategory> {
        let categories = AppNotificationCategory.allCases.map { notificationCategory($0) }
        return Set(categories)
    }

    class func notificationActions(for category: AppNotificationCategory) -> [UNNotificationAction] {
        return category.actions.map { notificationAction($0) }
    }

    class func notificationCategory(_ category: AppNotificationCategory) -> UNNotificationCategory {
        return UNNotificationCategory(
            identifier: category.identifier,
            actions: notificationActions(for: category),
            intentIdentifiers: [],
            options: []
        )
    }

    class func notificationAction(_ action: AppNotificationAction) -> UNNotificationAction {
        switch action {
            case .markAsRead:
                return UNNotificationAction(
                    identifier: action.identifier,
                    title: MessageStrings.markAsReadNotificationAction,
                    options: []
                )
                
            case .reply:
                return UNTextInputNotificationAction(
                    identifier: action.identifier,
                    title: MessageStrings.replyNotificationAction,
                    options: [],
                    textInputButtonTitle: MessageStrings.sendButton,
                    textInputPlaceholder: ""
                )
                
            case .showThread:
                return UNNotificationAction(
                    identifier: action.identifier,
                    title: CallStrings.showThreadButtonTitle,
                    options: [.foreground]
                )
        }
    }

    class func action(identifier: String) -> AppNotificationAction? {
        return AppNotificationAction.allCases.first { notificationAction($0).identifier == identifier }
    }
}
