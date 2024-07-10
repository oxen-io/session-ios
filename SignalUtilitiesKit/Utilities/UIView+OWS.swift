//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.

import UIKit
import SessionUIKit

public extension UIView {
    func applyScaleAspectFitLayout(subview: UIView, aspectRatio: CGFloat) -> [NSLayoutConstraint] {
        guard subviews.contains(subview) else { return [] }

        // This emulates the behavior of contentMode = .scaleAspectFit using
        // iOS auto layout constraints.
        //
        // This allows ConversationInputToolbar to place the "cancel" button
        // in the upper-right hand corner of the preview content.
        return [
            subview.center(.horizontal, in: self),
            subview.center(.vertical, in: self),
            subview.set(.width, to: .height, of: subview, multiplier: aspectRatio),
            subview.set(.width, lessThanOrEqualTo: .width, of: self),
            subview.set(.height, lessThanOrEqualTo: .height, of: self)
        ]
    }
}

public extension UIView {
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
