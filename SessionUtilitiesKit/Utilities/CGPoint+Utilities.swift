// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension CGPoint {
    var length: CGFloat { sqrt(x * x + y * y) }
    
    func adding(_ other: CGPoint) -> CGPoint {
        return CGPoint(x: x + other.x, y: y + other.y)
    }
    
    func subtracting(_ other: CGPoint) -> CGPoint {
        return CGPoint(x: x - other.x, y: y - other.y)
    }
    
    func multiplying(by value: CGFloat) -> CGPoint {
        return CGPoint(x: x * value, y: y * value)
    }
    
    func scaled(by factor: CGFloat) -> CGPoint {
        return CGPoint(x: x * factor, y: y * factor)
    }
    
    func distance(to other: CGPoint) -> CGFloat {
        let delta: CGPoint = CGPoint(x: x - other.x, y: y - other.y)
        
        return sqrt((delta.x * delta.x) + (delta.y * delta.y))
    }
    
    func inverted() -> CGPoint {
        return CGPoint(x: -x, y: -y)
    }
    
    func clamp01() -> CGPoint {
        return CGPoint(x: x.clamp01(), y: y.clamp01())
    }
    
    func clamp(to rect: CGRect) -> CGPoint {
        return CGPoint(
            x: x.clamp(rect.minX, rect.maxX),
            y: y.clamp(rect.minY, rect.maxY)
        )
    }
    
    func min(_ value: CGPoint) -> CGPoint {
        // We use "Swift" to disambiguate the global function min() from this method.
        return CGPoint(x: Swift.min(x, value.x),
                       y: Swift.min(y, value.y))
    }

    func max(_ value: CGPoint) -> CGPoint {
        // We use "Swift" to disambiguate the global function max() from this method.
        return CGPoint(x: Swift.max(x, value.x),
                       y: Swift.max(y, value.y))
    }
    
    func toUnitCoordinates(viewBounds: CGRect, shouldClamp: Bool) -> CGPoint {
        return CGPoint(
            x: CGFloat(x - viewBounds.origin.x).inverseLerp(0, viewBounds.width, shouldClamp: shouldClamp),
            y: CGFloat(y - viewBounds.origin.y).inverseLerp(0, viewBounds.height, shouldClamp: shouldClamp))
    }

    func toUnitCoordinates(viewSize: CGSize, shouldClamp: Bool) -> CGPoint {
        return toUnitCoordinates(viewBounds: CGRect(origin: .zero, size: viewSize), shouldClamp: shouldClamp)
    }

    func fromUnitCoordinates(viewBounds: CGRect) -> CGPoint {
        return CGPoint(
            x: viewBounds.origin.x + x.lerp(0, viewBounds.size.width),
            y: viewBounds.origin.y + y.lerp(0, viewBounds.size.height)
        )
    }

    func fromUnitCoordinates(viewSize: CGSize) -> CGPoint {
        return fromUnitCoordinates(viewBounds: CGRect(origin: .zero, size: viewSize))
    }
    
    func fuzzyEquals(_ other: CGPoint, tolerance: CGFloat = 0.001) -> Bool {
        return (
            x.fuzzyEquals(other.x, tolerance: tolerance) &&
            y.fuzzyEquals(other.y, tolerance: tolerance)
        )
    }
}
