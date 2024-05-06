//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.

import UIKit
import SessionUIKit
import SignalCoreKit

public class CircleView: UIView {

    @available(*, unavailable, message:"use other constructor instead.")
    required public init?(coder aDecoder: NSCoder) {
        notImplemented()
    }

    public required init() {
        super.init(frame: .zero)
    }

    public required init(diameter: CGFloat) {
        super.init(frame: .zero)

        set(.width, to: diameter)
        set(.height, to: diameter)
    }

    override public var frame: CGRect {
        didSet {
            updateRadius()
        }
    }

    override public var bounds: CGRect {
        didSet {
            updateRadius()
        }
    }

    private func updateRadius() {
        self.layer.cornerRadius = self.bounds.size.height / 2
    }
}
