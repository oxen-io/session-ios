//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

public protocol CaptionContainerViewDelegate: AnyObject {
    func captionContainerViewDidUpdateText(_ captionContainerView: CaptionContainerView)
}

public class CaptionContainerView: UIView {

    weak var delegate: CaptionContainerViewDelegate?

    var currentText: String? {
        get { return currentCaptionView.text }
        set {
            currentCaptionView.text = newValue
            delegate?.captionContainerViewDidUpdateText(self)
        }
    }

    var pendingText: String? {
        get { return pendingCaptionView.text }
        set {
            pendingCaptionView.text = newValue
            delegate?.captionContainerViewDidUpdateText(self)
        }
    }

    func updatePagerTransition(ratioComplete: CGFloat) {
        if let currentText = self.currentText, currentText.count > 0 {
            currentCaptionView.alpha = 1 - ratioComplete
        } else {
            currentCaptionView.alpha = 0
        }

        if let pendingText = self.pendingText, pendingText.count > 0 {
            pendingCaptionView.alpha = ratioComplete
        } else {
            pendingCaptionView.alpha = 0
        }
    }

    func completePagerTransition() {
        updatePagerTransition(ratioComplete: 1)

        // promote "pending" to "current" caption view.
        let oldCaptionView = self.currentCaptionView
        self.currentCaptionView = self.pendingCaptionView
        self.pendingCaptionView = oldCaptionView
        self.pendingText = nil
        self.currentCaptionView.alpha = 1
        self.pendingCaptionView.alpha = 0
    }

    // MARK: Initializers

    override init(frame: CGRect) {
        super.init(frame: frame)

        setContentHugging(to: .required)
        setCompressionResistance(to: .required)

        addSubview(currentCaptionView)
        currentCaptionView.pin(.top, greaterThanOrEqualTo: .top, of: self)
        currentCaptionView.pin(.leading, to: .leading, of: self)
        currentCaptionView.pin(.trailing, to: .trailing, of: self)
        currentCaptionView.pin(.bottom, to: .bottom, of: self)

        pendingCaptionView.alpha = 0
        addSubview(pendingCaptionView)
        pendingCaptionView.pin(.top, greaterThanOrEqualTo: .top, of: self)
        pendingCaptionView.pin(.leading, to: .leading, of: self)
        pendingCaptionView.pin(.trailing, to: .trailing, of: self)
        pendingCaptionView.pin(.bottom, to: .bottom, of: self)
    }

    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Subviews

    private var pendingCaptionView: CaptionView = CaptionView()
    private var currentCaptionView: CaptionView = CaptionView()
}

private class CaptionView: UIView {

    var text: String? {
        get { return textView.text }

        set {
            if let captionText = newValue, captionText.count > 0 {
                textView.text = captionText
            } else {
                textView.text = nil
            }
        }
    }

    // MARK: Subviews

    let textView: CaptionTextView = {
        let textView = CaptionTextView()

        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.themeTextColor = .textPrimary
        textView.themeBackgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = false

        return textView
    }()

    let scrollFadeView: GradientView = {
        let result: GradientView = GradientView()
        result.themeBackgroundGradient = [
            .clear,
            .black
        ]
        
        return result
    }()

    // MARK: Initializers

    override init(frame: CGRect) {
        super.init(frame: frame)

        addSubview(textView)
        textView.pin(toMarginsOf: self)

        addSubview(scrollFadeView)
        scrollFadeView.pin(.leading, to: .leading, of: self)
        scrollFadeView.pin(.trailing, to: .trailing, of: self)
        scrollFadeView.pin(.bottom, to: .bottom, of: self)
        scrollFadeView.set(.height, to: 20)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: UIView overrides

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollFadeView.isHidden = !textView.doesContentNeedScroll
    }

    // MARK: -

    class CaptionTextView: UITextView {
        var kMaxHeight: CGFloat = Values.scaleFromIPhone5(200)

        override var text: String! {
            didSet {
                invalidateIntrinsicContentSize()
            }
        }

        override var font: UIFont? {
            didSet {
                invalidateIntrinsicContentSize()
            }
        }

        var doesContentNeedScroll: Bool {
            return self.bounds.height == kMaxHeight
        }

        override func layoutSubviews() {
            super.layoutSubviews()

            // Enable/disable scrolling depending on wether we've clipped
            // content in `intrinsicContentSize`
            isScrollEnabled = doesContentNeedScroll
        }

        override var intrinsicContentSize: CGSize {
            var size = super.intrinsicContentSize

            if size.height == UIView.noIntrinsicMetric {
                size.height = layoutManager.usedRect(for: textContainer).height + textContainerInset.top + textContainerInset.bottom
            }
            size.height = min(kMaxHeight, size.height)

            return size
        }
    }
}
