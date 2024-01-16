// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit.UIApplication

public extension UIApplication.State {
    var name: String {
        switch self {
            case .active: return "Active"
            case .background: return "Background"
            case .inactive: return "Inactive"
            @unknown default: return "Unknown"
        }
    }
}
