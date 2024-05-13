// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

final class SessionTableViewTitleView: UIView {
    private static let maxWidth: CGFloat = UIScreen.main.bounds.width - 44 * 2 - 16 * 2
    private var oldSize: CGSize = .zero
    
    override var frame: CGRect {
        set(newValue) {
            super.frame = newValue

            if let superview = self.superview {
                self.center = CGPoint(x: superview.center.x, y: self.center.y)
            }
        }

        get {
            return super.frame
        }
    }

    // MARK: - UI Components
    
    private lazy var titleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.setContentCompressionResistancePriority(.required, for: .vertical)
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byTruncatingTail
        
        return result
    }()

    private lazy var subtitleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.miniFontSize)
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        result.textAlignment = .center
        result.set(.width, lessThanOrEqualTo: Self.maxWidth)
        
        return result
    }()
    
    private lazy var stackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ titleLabel, subtitleLabel ])
        result.axis = .vertical
        result.alignment = .center
        
        return result
    }()
    
    private lazy var subtitleLabelHeightConstraint: NSLayoutConstraint = subtitleLabel.set(.height, to: 0)

    // MARK: - Initialization
    
    init() {
        super.init(frame: .zero)
        
        addSubview(stackView)
        
        // Note: We are intentionally letting the stackView go out of bounds because the title will clip
        // in some cases when the subtitle wraps over 2 lines (this provides the extra space we need)
        stackView.pin(.top, to: .top, of: self, withInset: -2)
        stackView.pin(.leading, to: .leading, of: self)
        stackView.pin(.trailing, to: .trailing, of: self)
        stackView.pin(.bottom, to: .bottom, of: self, withInset: 2)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init() instead.")
    }

    // MARK: - Content
    
    public func update(title: String, subtitle: String?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.update(title: title, subtitle: subtitle)
            }
            return
        }
        
        self.titleLabel.text = title
        self.titleLabel.font = .boldSystemFont(
            ofSize: (subtitle?.isEmpty == false ?
                Values.largeFontSize :
                Values.veryLargeFontSize
            )
        )
        
        if let subtitle: String = subtitle {
            subtitleLabelHeightConstraint.constant = subtitle.heightWithConstrainedWidth(width: Self.maxWidth, font: self.subtitleLabel.font)
            self.subtitleLabel.text = subtitle
            self.subtitleLabel.isHidden = false
        } else {
            self.subtitleLabel.isHidden = true
        }
    }
}
