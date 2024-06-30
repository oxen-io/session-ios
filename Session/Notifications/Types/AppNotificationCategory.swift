// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

enum AppNotificationCategory: CaseIterable {
    case incomingMessage
    case errorMessage
    case threadlessErrorMessage
}

extension AppNotificationCategory {
    var identifier: String {
        switch self {
            case .incomingMessage: return "Signal.AppNotificationCategory.incomingMessage"
            case .errorMessage: return "Signal.AppNotificationCategory.errorMessage"
            case .threadlessErrorMessage: return "Signal.AppNotificationCategory.threadlessErrorMessage"
        }
    }

    var actions: [AppNotificationAction] {
        switch self {
            case .incomingMessage: return [.markAsRead, .reply]
            case .errorMessage: return []
            case .threadlessErrorMessage: return []
        }
    }
}
