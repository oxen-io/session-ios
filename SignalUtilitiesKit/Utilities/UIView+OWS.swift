//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.

import UIKit
import SessionUIKit
import SignalCoreKit
import SessionUtilitiesKit

public extension UIView {
    func applyScaleAspectFitLayout(subview: UIView, aspectRatio: CGFloat) -> [NSLayoutConstraint] {
        guard subviews.contains(subview) else {
            owsFailDebug("Not a subview.")
            return []
        }

        // This emulates the behavior of contentMode = .scaleAspectFit using
        // iOS auto layout constraints.
        //
        // This allows ConversationInputToolbar to place the "cancel" button
        // in the upper-right hand corner of the preview content.
        var constraints = [NSLayoutConstraint]()
        constraints.append(subview.center(.horizontal, in: self))
        constraints.append(subview.center(.vertical, in: self))
        constraints.append(subview.set(.width, to: .height, of: subview, multiplier: aspectRatio))
        constraints.append(subview.set(.width, lessThanOrEqualTo: .width, of: self))
        constraints.append(subview.set(.height, lessThanOrEqualTo: .height, of: self))
        return constraints
    }
    
    func setShadow(
        radius: CGFloat = 2.0,
        opacity: Float = 0.66,
        offset: CGSize = .zero,
        color: ThemeValue = .black
    ) {
        layer.themeShadowColor = color
        layer.shadowRadius = radius
        layer.shadowOpacity = opacity
        layer.shadowOffset = offset
    }
}
