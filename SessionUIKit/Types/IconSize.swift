// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import DifferenceKit

public enum IconSize: Differentiable {
    case verySmall
    case small
    case medium
    case large
    case veryLarge
    case extraLarge
    
    case mediumAspectFill
    
    case fit
    
    public var size: CGFloat {
        switch self {
            case .verySmall: return 12
            case .small: return 20
            case .medium, .mediumAspectFill: return 24
            case .large: return 32
            case .veryLarge: return 40
            case .extraLarge: return 80
            case .fit: return 0
        }
    }
}
