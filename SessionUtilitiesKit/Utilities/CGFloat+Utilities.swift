// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension CGFloat {
    var square: CGFloat { self * self }
    
    func clamp(_ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
        return Swift.max(minValue, Swift.min(maxValue, self))
    }
    
    func clamp01() -> CGFloat {
        return clamp(0, 1)
    }
    
    func lerp(_ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
        return (minValue * (1 - self)) + (maxValue * self)
    }
    
    func inverseLerp(_ minValue: CGFloat, _ maxValue: CGFloat, shouldClamp: Bool = false) -> CGFloat {
        let result: CGFloat = ((self - minValue) / (maxValue - minValue))
        
        return (shouldClamp ? result.clamp01() : result)
    }
    
    func fuzzyEquals(_ other: CGFloat, tolerance: CGFloat = 0.001) -> Bool {
        return abs(self - other) < tolerance
    }
}
