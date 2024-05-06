// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
    var topLeft: CGPoint { origin }
    var topRight: CGPoint { CGPoint(x: maxX, y: minY) }
    var bottomLeft: CGPoint { CGPoint(x: minX, y: maxY) }
    var bottomRight: CGPoint { CGPoint(x: maxX, y: maxY) }
}
