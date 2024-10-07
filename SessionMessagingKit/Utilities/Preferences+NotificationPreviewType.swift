// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import DifferenceKit
import SessionUtilitiesKit

public extension Preferences {
    enum NotificationPreviewType: Int, CaseIterable, EnumIntSetting, Differentiable {
        public static var defaultPreviewType: NotificationPreviewType = .nameAndPreview
        
        /// Notifications should include both the sender name and a preview of the message content
        case nameAndPreview
        
        /// Notifications should include the sender name but no preview
        case nameNoPreview
        
        /// Notifications should be a generic message
        case noNameNoPreview
        
        public var name: String {
            switch self {
                case .nameAndPreview: return "notificationsContentShowNameAndContent".localized()
                case .nameNoPreview: return "notificationsContentShowNameOnly".localized()
                case .noNameNoPreview: return "notificationsContentShowNoNameOrContent".localized()
            }
        }
    }
}
