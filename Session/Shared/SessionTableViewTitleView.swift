// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

final class SessionTableViewTitleView: UIView {
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
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byTruncatingTail
        
        return result
    }()

    private lazy var subtitleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.miniFontSize)
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byTruncatingTail
        
        return result
    }()
    
    private lazy var stackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ titleLabel, subtitleLabel ])
        result.axis = .vertical
        result.alignment = .center
        
        return result
    }()

    // MARK: - Initialization
    
    init() {
        super.init(frame: .zero)
        
        addSubview(stackView)
        
        stackView.pin([ UIView.HorizontalEdge.trailing, UIView.VerticalEdge.top, UIView.VerticalEdge.bottom ], to: self)
        stackView.pin(.leading, to: .leading, of: self, withInset: 0)
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
        
        self.subtitleLabel.text = subtitle
    }
}
