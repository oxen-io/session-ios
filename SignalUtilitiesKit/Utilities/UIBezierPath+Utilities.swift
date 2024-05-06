// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SignalCoreKit

public extension UIBezierPath {
    func addRegion(withPoints points: [CGPoint]) {
        guard let first = points.first else {
            owsFailDebug("No points.")
            return
        }
        move(to: first)
        for point in points.dropFirst() {
            addLine(to: point)
        }
        addLine(to: first)
    }
}
