// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

final class InfoBanner: UIView {
    public struct Info: Equatable, Hashable {
        let font: UIFont
        let message: String
        let hasIcon: Bool
        let tintColor: ThemeValue
        let backgroundColor: ThemeValue
        let accessibility: Accessibility?
        let labelAccessibility: Accessibility?
        let height: CGFloat?
        let onTap: (() -> Void)?
        
        func with(
            font: UIFont? = nil,
            message: String? = nil,
            hasIcon: Bool? = nil,
            tintColor: ThemeValue? = nil,
            backgroundColor: ThemeValue? = nil,
            accessibility: Accessibility? = nil,
            labelAccessibility: Accessibility? = nil,
            height: CGFloat? = nil,
            onTap: (() -> Void)? = nil
        ) -> Info {
            return Info(
                font: font ?? self.font,
                message: message ?? self.message,
                hasIcon: hasIcon ?? self.hasIcon,
                tintColor: tintColor ?? self.tintColor,
                backgroundColor: backgroundColor ?? self.backgroundColor,
                accessibility: accessibility ?? self.accessibility,
                labelAccessibility: labelAccessibility ?? self.labelAccessibility,
                height: height ?? self.height,
                onTap: onTap ?? self.onTap
            )
        }
        
        public func hash(into hasher: inout Hasher) {
            font.hash(into: &hasher)
            message.hash(into: &hasher)
            hasIcon.hash(into: &hasher)
            tintColor.hash(into: &hasher)
            backgroundColor.hash(into: &hasher)
            accessibility.hash(into: &hasher)
            labelAccessibility.hash(into: &hasher)
            height.hash(into: &hasher)
        }
        
        public static func == (lhs: InfoBanner.Info, rhs: InfoBanner.Info) -> Bool {
            return (
                lhs.font == rhs.font &&
                lhs.message == rhs.message &&
                lhs.hasIcon == rhs.hasIcon &&
                lhs.tintColor == rhs.tintColor &&
                lhs.backgroundColor == rhs.backgroundColor &&
                lhs.accessibility == rhs.accessibility &&
                lhs.labelAccessibility == rhs.labelAccessibility &&
                lhs.height == rhs.height
            )
        }
    }
    
    private lazy var stackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.axis = .horizontal
        result.alignment = .center
        result.distribution = .fill
        result.spacing = Values.smallSpacing
        
        return result
    }()
    
    private lazy var leftIconImageView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.set(.width, to: 18)
        result.set(.height, to: 18)
        result.isHidden = true
        
        return result
    }()
    
    private lazy var label: UILabel = {
        let result: UILabel = UILabel()
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        result.isAccessibilityElement = true
        
        return result
    }()
    
    private lazy var rightIconImageView: UIImageView = {
        let result: UIImageView = UIImageView(
            image: UIImage(systemName: "arrow.up.right.square")?.withRenderingMode(.alwaysTemplate)
        )
        result.set(.width, to: 18)
        result.set(.height, to: 18)
        result.isHidden = true
        
        return result
    }()
    
    public var info: Info?
    private var heightConstraint: NSLayoutConstraint?
    
    // MARK: - Initialization
    
    init(info: Info) {
        super.init(frame: CGRect.zero)
        
        addSubview(stackView)
        
        stackView.addArrangedSubview(leftIconImageView)
        stackView.addArrangedSubview(label)
        stackView.addArrangedSubview(rightIconImageView)
        
        stackView.pin(.top, to: .top, of: self, withInset: Values.verySmallSpacing)
        stackView.pin(.bottom, to: .bottom, of: self, withInset: -Values.verySmallSpacing)
        stackView.pin(.leading, to: .leading, of: self, withInset: Values.mediumSpacing)
        stackView.pin(.trailing, to: .trailing, of: self, withInset: -Values.mediumSpacing)
        
        switch info.height {
            case .some(let fixedHeight): self.heightConstraint = self.set(.height, to: fixedHeight)
            case .none: self.heightConstraint?.isActive = false
        }
        
        self.update(info)
        
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(bannerTapped))
        self.addGestureRecognizer(tapGestureRecognizer)
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(message:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(coder:) instead.")
    }
    
    // MARK: - Interaction
    
    @objc private func bannerTapped() {
        info?.onTap?()
    }
    
    // MARK: - Update
    
    private func update(_ info: InfoBanner.Info) {
        self.info = info
        
        themeBackgroundColor = info.backgroundColor
        isAccessibilityElement = (info.accessibility != nil)
        accessibilityIdentifier = info.accessibility?.identifier
        accessibilityLabel = info.accessibility?.label
        
        label.font = info.font
        label.text = info.message
        label.themeTextColor = info.tintColor
        label.accessibilityIdentifier = info.labelAccessibility?.identifier
        label.accessibilityLabel = info.labelAccessibility?.label
        leftIconImageView.isHidden = !info.hasIcon
        leftIconImageView.themeTintColor = info.tintColor
        rightIconImageView.isHidden = !info.hasIcon
        rightIconImageView.themeTintColor = info.tintColor
    }
    
    public func update(
        font: UIFont? = nil,
        message: String? = nil,
        hasIcon: Bool? = nil,
        tintColor: ThemeValue? = nil,
        backgroundColor: ThemeValue? = nil,
        accessibility: Accessibility? = nil,
        labelAccessibility: Accessibility? = nil,
        height: CGFloat? = nil,
        onTap: (() -> Void)? = nil
    ) {
        guard let currentInfo: Info = self.info else { return }
        
        self.update(
            currentInfo.with(
                font: font,
                message: message,
                hasIcon: hasIcon,
                tintColor: tintColor,
                backgroundColor: backgroundColor,
                accessibility: accessibility,
                labelAccessibility: labelAccessibility,
                height: height,
                onTap: onTap
            )
        )
    }
}
