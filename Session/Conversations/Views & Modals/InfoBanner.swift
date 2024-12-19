// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit
import SessionUIKit

final class InfoBanner: UIView {
    public enum Icon: Equatable, Hashable {
        case none
        case link
        case close
        
        var image: UIImage? {
            switch self {
                case .none: return nil
                case .link: return UIImage(systemName: "arrow.up.right.square")?.withRenderingMode(.alwaysTemplate)
                case .close:
                    return UIImage(
                        systemName: "xmark",
                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
                    )?.withRenderingMode(.alwaysTemplate)
            }
        }
    }
    
    public struct Info: Equatable, Hashable {
        let font: UIFont
        let message: NSAttributedString
        let icon: Icon
        let tintColor: ThemeValue
        let backgroundColor: ThemeValue
        let accessibility: Accessibility?
        let labelAccessibility: Accessibility?
        let height: CGFloat?
        let onTap: (() -> Void)?
        
        static var empty: Info = Info(
            font: .systemFont(ofSize: Values.smallFontSize),
            message: NSAttributedString()
        )
        
        public init(
            font: UIFont,
            message: NSAttributedString,
            icon: Icon = .none,
            tintColor: ThemeValue = .black,
            backgroundColor: ThemeValue = .primary,
            accessibility: Accessibility? = nil,
            labelAccessibility: Accessibility? = nil,
            height: CGFloat? = nil,
            onTap: (() -> Void)? = nil
        ) {
            self.font = font
            self.message = message
            self.icon = icon
            self.tintColor = tintColor
            self.backgroundColor = backgroundColor
            self.accessibility = accessibility
            self.labelAccessibility = labelAccessibility
            self.height = height
            self.onTap = onTap
        }
        
        func with(
            font: UIFont? = nil,
            message: NSAttributedString? = nil,
            icon: Icon? = nil,
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
                icon: icon ?? self.icon,
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
            icon.hash(into: &hasher)
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
                lhs.icon == rhs.icon &&
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
    
    private lazy var leftIconPadding: UIView = {
        let result: UIView = UIView()
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
    
    public var font: UIFont { info?.font ?? .systemFont(ofSize: Values.smallFontSize) }
    
    // MARK: - Initialization
    
    init(info: Info) {
        super.init(frame: CGRect.zero)
        
        addSubview(stackView)
        
        stackView.addArrangedSubview(leftIconPadding)
        stackView.addArrangedSubview(label)
        stackView.addArrangedSubview(rightIconImageView)
        
        stackView.pin(.top, to: .top, of: self, withInset: Values.verySmallSpacing)
        stackView.pin(.bottom, to: .bottom, of: self, withInset: -Values.verySmallSpacing)
        stackView.pin(.leading, to: .leading, of: self, withInset: Values.mediumSpacing)
        stackView.pin(.trailing, to: .trailing, of: self, withInset: -Values.mediumSpacing)
        
        self.update(with: info)
        
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
    
    public func update(
        font: UIFont? = nil,
        message: NSAttributedString? = nil,
        icon: Icon = .none,
        tintColor: ThemeValue? = nil,
        backgroundColor: ThemeValue? = nil,
        accessibility: Accessibility? = nil,
        labelAccessibility: Accessibility? = nil,
        height: CGFloat? = nil,
        onTap: (() -> Void)? = nil
    ) {
        guard let currentInfo: Info = self.info else { return }
        
        self.update(
            with: currentInfo.with(
                font: font,
                message: message,
                icon: icon,
                tintColor: tintColor,
                backgroundColor: backgroundColor,
                accessibility: accessibility,
                labelAccessibility: labelAccessibility,
                height: height,
                onTap: onTap
            )
        )
    }
    
    public func update(with info: InfoBanner.Info) {
        self.info = info
        self.heightConstraint?.isActive = false // Calling 'set' below will enable it
        
        switch info.height {
            case .some(let fixedHeight): self.heightConstraint = self.set(.height, to: fixedHeight)
            case .none: break
        }
        
        themeBackgroundColor = info.backgroundColor
        isAccessibilityElement = (info.accessibility != nil)
        accessibilityIdentifier = info.accessibility?.identifier
        accessibilityLabel = info.accessibility?.label
        
        label.font = info.font
        label.attributedText = info.message
        label.themeTextColor = info.tintColor
        label.accessibilityIdentifier = info.labelAccessibility?.identifier
        label.accessibilityLabel = info.labelAccessibility?.label
        rightIconImageView.image = info.icon.image
        rightIconImageView.isHidden = (info.icon == .none)
        rightIconImageView.themeTintColor = info.tintColor
    }
}
