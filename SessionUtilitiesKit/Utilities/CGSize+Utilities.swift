// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension CGSize {
    var asPoint: CGPoint { CGPoint(x: width, y: height) }
    
    func rounded() -> CGSize {
        return CGSize(
            width: Int(Float(width).rounded()),
            height: Int(Float(height).rounded())
        )
    }
}
