// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit

public var isIPhone5OrSmaller: Bool {
    return (UIScreen.main.bounds.height - 568) < 1
}

public var isIPhone6OrSmaller: Bool {
    return (UIScreen.main.bounds.height - 667) < 1
}

public extension UIDevice {
    var isIPad: Bool {
        let isNativeIPad: Bool = (userInterfaceIdiom == .pad)
        let isCompatabilityModeIPad: Bool = (userInterfaceIdiom == .phone && self.model.hasPrefix("iPad"))

        return isNativeIPad || isCompatabilityModeIPad
    }
}
