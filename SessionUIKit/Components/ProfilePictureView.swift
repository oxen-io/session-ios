// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import YYImage

public final class ProfilePictureView: UIView {
    public struct Info {
        let imageData: Data?
        let renderingMode: UIImage.RenderingMode
        let themeTintColor: ThemeValue?
        let inset: UIEdgeInsets
        let icon: ProfileIcon
        let backgroundColor: ThemeValue?
        let forcedBackgroundColor: ForcedThemeValue?
        
        public init(
            imageData: Data?,
            renderingMode: UIImage.RenderingMode = .automatic,
            themeTintColor: ThemeValue? = nil,
            inset: UIEdgeInsets = .zero,
            icon: ProfileIcon = .none,
            backgroundColor: ThemeValue? = nil,
            forcedBackgroundColor: ForcedThemeValue? = nil
        ) {
            self.imageData = imageData
            self.renderingMode = renderingMode
            self.themeTintColor = themeTintColor
            self.inset = inset
            self.icon = icon
            self.backgroundColor = backgroundColor
            self.forcedBackgroundColor = forcedBackgroundColor
        }
    }
    
    public enum Size {
        case navigation
        case message
        case list
        case hero
        
        public var viewSize: CGFloat {
            switch self {
                case .navigation, .message: return 26
                case .list: return 46
                case .hero: return 110
            }
        }
        
        public var imageSize: CGFloat {
            switch self {
                case .navigation, .message: return 26
                case .list: return 46
                case .hero: return 80
            }
        }
        
        public var multiImageSize: CGFloat {
            switch self {
                case .navigation, .message: return 18  // Shouldn't be used
                case .list: return 32
                case .hero: return 80
            }
        }
        
        var iconSize: CGFloat {
            switch self {
                case .navigation, .message: return 10   // Intentionally not a multiple of 4
                case .list: return 16
                case .hero: return 24
            }
        }
    }
    
    public enum ProfileIcon: Equatable, Hashable {
        case none
        case crown
        case rightPlus
        case letter(Character)
        
        func iconVerticalInset(for size: Size) -> CGFloat {
            switch (self, size) {
                case (.crown, .navigation), (.crown, .message): return 1
                case (.crown, .list): return 3
                case (.crown, .hero): return 5
                    
                case (.rightPlus, _): return 3
                default: return 0
            }
        }
        
        var isLeadingAligned: Bool {
            switch self {
                case .none, .crown, .letter: return true
                case .rightPlus: return false
            }
        }
    }
    
    public var size: Size {
        didSet {
            widthConstraint.constant = (customWidth ?? size.viewSize)
            heightConstraint.constant = size.viewSize
            profileIconBackgroundWidthConstraint.constant = size.iconSize
            profileIconBackgroundHeightConstraint.constant = size.iconSize
            additionalProfileIconBackgroundWidthConstraint.constant = size.iconSize
            additionalProfileIconBackgroundHeightConstraint.constant = size.iconSize
            
            profileIconBackgroundView.layer.cornerRadius = (size.iconSize / 2)
            additionalProfileIconBackgroundView.layer.cornerRadius = (size.iconSize / 2)
            profileIconLabel.font = .boldSystemFont(ofSize: floor(size.iconSize * 0.75))
            additionalProfileIconLabel.font = .boldSystemFont(ofSize: floor(size.iconSize * 0.75))
        }
    }
    public var customWidth: CGFloat? {
        didSet {
            self.widthConstraint.constant = (customWidth ?? self.size.viewSize)
        }
    }
    override public var clipsToBounds: Bool {
        didSet {
            imageContainerView.clipsToBounds = clipsToBounds
            additionalImageContainerView.clipsToBounds = clipsToBounds
            
            imageContainerView.layer.cornerRadius = (clipsToBounds ?
                (additionalImageContainerView.isHidden ? (size.imageSize / 2) : (size.multiImageSize / 2)) :
                0
            )
            imageContainerView.layer.cornerRadius = (clipsToBounds ? (size.multiImageSize / 2) : 0)
        }
    }
    public override var isHidden: Bool {
        didSet {
            widthConstraint.constant = (isHidden ? 0 : size.viewSize)
            heightConstraint.constant = (isHidden ? 0 : size.viewSize)
        }
    }
    
    // MARK: - Constraints
    
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var imageViewTopConstraint: NSLayoutConstraint!
    private var imageViewLeadingConstraint: NSLayoutConstraint!
    private var imageViewCenterXConstraint: NSLayoutConstraint!
    private var imageViewCenterYConstraint: NSLayoutConstraint!
    private var imageViewWidthConstraint: NSLayoutConstraint!
    private var imageViewHeightConstraint: NSLayoutConstraint!
    private var additionalImageViewWidthConstraint: NSLayoutConstraint!
    private var additionalImageViewHeightConstraint: NSLayoutConstraint!
    private var profileIconTopConstraint: NSLayoutConstraint!
    private var profileIconLeadingConstraint: NSLayoutConstraint!
    private var profileIconBottomConstraint: NSLayoutConstraint!
    private var profileIconBackgroundLeadingAlignConstraint: NSLayoutConstraint!
    private var profileIconBackgroundTrailingAlignConstraint: NSLayoutConstraint!
    private var profileIconBackgroundWidthConstraint: NSLayoutConstraint!
    private var profileIconBackgroundHeightConstraint: NSLayoutConstraint!
    private var additionalProfileIconTopConstraint: NSLayoutConstraint!
    private var additionalProfileIconBottomConstraint: NSLayoutConstraint!
    private var additionalProfileIconBackgroundLeadingAlignConstraint: NSLayoutConstraint!
    private var additionalProfileIconBackgroundTrailingAlignConstraint: NSLayoutConstraint!
    private var additionalProfileIconBackgroundWidthConstraint: NSLayoutConstraint!
    private var additionalProfileIconBackgroundHeightConstraint: NSLayoutConstraint!
    private lazy var imageEdgeConstraints: [NSLayoutConstraint] = [ // MUST be in 'top, left, bottom, right' order
        imageView.pin(.top, to: .top, of: imageContainerView, withInset: 0),
        imageView.pin(.left, to: .left, of: imageContainerView, withInset: 0),
        imageView.pin(.bottom, to: .bottom, of: imageContainerView, withInset: 0),
        imageView.pin(.right, to: .right, of: imageContainerView, withInset: 0),
        animatedImageView.pin(.top, to: .top, of: imageContainerView, withInset: 0),
        animatedImageView.pin(.left, to: .left, of: imageContainerView, withInset: 0),
        animatedImageView.pin(.bottom, to: .bottom, of: imageContainerView, withInset: 0),
        animatedImageView.pin(.right, to: .right, of: imageContainerView, withInset: 0)
    ]
    private lazy var additionalImageEdgeConstraints: [NSLayoutConstraint] = [ // MUST be in 'top, left, bottom, right' order
        additionalImageView.pin(.top, to: .top, of: additionalImageContainerView, withInset: 0),
        additionalImageView.pin(.left, to: .left, of: additionalImageContainerView, withInset: 0),
        additionalImageView.pin(.bottom, to: .bottom, of: additionalImageContainerView, withInset: 0),
        additionalImageView.pin(.right, to: .right, of: additionalImageContainerView, withInset: 0),
        additionalAnimatedImageView.pin(.top, to: .top, of: additionalImageContainerView, withInset: 0),
        additionalAnimatedImageView.pin(.left, to: .left, of: additionalImageContainerView, withInset: 0),
        additionalAnimatedImageView.pin(.bottom, to: .bottom, of: additionalImageContainerView, withInset: 0),
        additionalAnimatedImageView.pin(.right, to: .right, of: additionalImageContainerView, withInset: 0)
    ]
    
    // MARK: - Components
    
    private lazy var imageContainerView: UIView = {
        let result: UIView = UIView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.clipsToBounds = true
        result.themeBackgroundColor = .backgroundSecondary
        
        return result
    }()
    
    private lazy var imageView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.contentMode = .scaleAspectFill
        result.isHidden = true
        
        return result
    }()
    
    private lazy var animatedImageView: YYAnimatedImageView = {
        let result: YYAnimatedImageView = YYAnimatedImageView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.contentMode = .scaleAspectFill
        result.isHidden = true
        
        return result
    }()
    
    private lazy var additionalImageContainerView: UIView = {
        let result: UIView = UIView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.clipsToBounds = true
        result.themeBackgroundColor = .primary
        result.themeBorderColor = .backgroundPrimary
        result.layer.borderWidth = 1
        result.isHidden = true
        
        return result
    }()
    
    private lazy var additionalImageView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.contentMode = .scaleAspectFill
        result.themeTintColor = .textPrimary
        result.isHidden = true
        
        return result
    }()
    
    private lazy var additionalAnimatedImageView: YYAnimatedImageView = {
        let result: YYAnimatedImageView = YYAnimatedImageView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.contentMode = .scaleAspectFill
        result.isHidden = true
        
        return result
    }()
    
    private lazy var profileIconBackgroundView: UIView = {
        let result: UIView = UIView()
        result.isHidden = true
        
        return result
    }()
    
    private lazy var profileIconImageView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.contentMode = .scaleAspectFit
        result.isHidden = true
        
        return result
    }()
    
    private lazy var profileIconLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: 6)
        result.textAlignment = .center
        result.themeTextColor = .backgroundPrimary
        result.isHidden = true
        
        return result
    }()
    
    private lazy var additionalProfileIconBackgroundView: UIView = {
        let result: UIView = UIView()
        result.isHidden = true
        
        return result
    }()
    
    private lazy var additionalProfileIconImageView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.contentMode = .scaleAspectFit
        
        return result
    }()
    
    private lazy var additionalProfileIconLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: 6)
        result.textAlignment = .center
        result.themeTextColor = .backgroundPrimary
        result.isHidden = true
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    public init(size: Size) {
        self.size = size
        
        super.init(frame: CGRect(x: 0, y: 0, width: size.viewSize, height: size.viewSize))
        
        clipsToBounds = true
        setUpViewHierarchy()
    }
    
    public required init?(coder: NSCoder) {
        preconditionFailure("Use init(size:) instead.")
    }
    
    private func setUpViewHierarchy() {
        addSubview(imageContainerView)
        addSubview(profileIconBackgroundView)
        addSubview(additionalImageContainerView)
        addSubview(additionalProfileIconBackgroundView)
        
        profileIconBackgroundView.addSubview(profileIconImageView)
        profileIconBackgroundView.addSubview(profileIconLabel)
        additionalProfileIconBackgroundView.addSubview(additionalProfileIconImageView)
        additionalProfileIconBackgroundView.addSubview(additionalProfileIconLabel)
        
        widthConstraint = self.set(.width, to: self.size.viewSize)
        heightConstraint = self.set(.height, to: self.size.viewSize)
        
        imageViewTopConstraint = imageContainerView.pin(.top, to: .top, of: self)
        imageViewLeadingConstraint = imageContainerView.pin(.leading, to: .leading, of: self)
        imageViewCenterXConstraint = imageContainerView.center(.horizontal, in: self)
        imageViewCenterXConstraint.isActive = false
        imageViewCenterYConstraint = imageContainerView.center(.vertical, in: self)
        imageViewCenterYConstraint.isActive = false
        imageViewWidthConstraint = imageContainerView.set(.width, to: size.imageSize)
        imageViewHeightConstraint = imageContainerView.set(.height, to: size.imageSize)
        additionalImageContainerView.pin(.trailing, to: .trailing, of: self)
        additionalImageContainerView.pin(.bottom, to: .bottom, of: self)
        additionalImageViewWidthConstraint = additionalImageContainerView.set(.width, to: size.multiImageSize)
        additionalImageViewHeightConstraint = additionalImageContainerView.set(.height, to: size.multiImageSize)
        
        imageContainerView.addSubview(imageView)
        imageContainerView.addSubview(animatedImageView)
        additionalImageContainerView.addSubview(additionalImageView)
        additionalImageContainerView.addSubview(additionalAnimatedImageView)
        
        // Activate the image edge constraints
        imageEdgeConstraints.forEach { $0.isActive = true }
        additionalImageEdgeConstraints.forEach { $0.isActive = true }
        
        profileIconTopConstraint = profileIconImageView.pin(
            .top,
            to: .top,
            of: profileIconBackgroundView,
            withInset: 0
        )
        profileIconImageView.pin(.left, to: .left, of: profileIconBackgroundView)
        profileIconImageView.pin(.right, to: .right, of: profileIconBackgroundView)
        profileIconBottomConstraint = profileIconImageView.pin(
            .bottom,
            to: .bottom,
            of: profileIconBackgroundView,
            withInset: 0
        )
        profileIconLabel.pin(to: profileIconBackgroundView)
        profileIconBackgroundLeadingAlignConstraint = profileIconBackgroundView.pin(.leading, to: .leading, of: imageContainerView)
        profileIconBackgroundTrailingAlignConstraint = profileIconBackgroundView.pin(.trailing, to: .trailing, of: imageContainerView)
        profileIconBackgroundView.pin(.bottom, to: .bottom, of: imageContainerView)
        profileIconBackgroundWidthConstraint = profileIconBackgroundView.set(.width, to: size.iconSize)
        profileIconBackgroundHeightConstraint = profileIconBackgroundView.set(.height, to: size.iconSize)
        profileIconBackgroundLeadingAlignConstraint.isActive = false
        profileIconBackgroundTrailingAlignConstraint.isActive = false
        
        additionalProfileIconTopConstraint = additionalProfileIconImageView.pin(
            .top,
            to: .top,
            of: additionalProfileIconBackgroundView,
            withInset: 0
        )
        additionalProfileIconImageView.pin(.left, to: .left, of: additionalProfileIconBackgroundView)
        additionalProfileIconImageView.pin(.right, to: .right, of: additionalProfileIconBackgroundView)
        additionalProfileIconBottomConstraint = additionalProfileIconImageView.pin(
            .bottom,
            to: .bottom,
            of: additionalProfileIconBackgroundView,
            withInset: 0
        )
        additionalProfileIconLabel.pin(to: additionalProfileIconBackgroundView)
        additionalProfileIconBackgroundLeadingAlignConstraint = additionalProfileIconBackgroundView.pin(.leading, to: .leading, of: additionalImageContainerView)
        additionalProfileIconBackgroundTrailingAlignConstraint = additionalProfileIconBackgroundView.pin(.trailing, to: .trailing, of: additionalImageContainerView)
        additionalProfileIconBackgroundView.pin(.bottom, to: .bottom, of: additionalImageContainerView)
        additionalProfileIconBackgroundWidthConstraint = additionalProfileIconBackgroundView.set(.width, to: size.iconSize)
        additionalProfileIconBackgroundHeightConstraint = additionalProfileIconBackgroundView.set(.height, to: size.iconSize)
        additionalProfileIconBackgroundLeadingAlignConstraint.isActive = false
        additionalProfileIconBackgroundTrailingAlignConstraint.isActive = false
    }
    
    // MARK: - Content
    
    private func updateIconView(
        icon: ProfileIcon,
        imageView: UIImageView,
        label: UILabel,
        backgroundView: UIView,
        topConstraint: NSLayoutConstraint,
        leadingAlignConstraint: NSLayoutConstraint,
        trailingAlignConstraint: NSLayoutConstraint,
        bottomConstraint: NSLayoutConstraint
    ) {
        backgroundView.isHidden = (icon == .none)
        leadingAlignConstraint.isActive = icon.isLeadingAligned
        trailingAlignConstraint.isActive = !icon.isLeadingAligned
        topConstraint.constant = icon.iconVerticalInset(for: size)
        bottomConstraint.constant = -icon.iconVerticalInset(for: size)
        
        switch icon {
            case .none:
                imageView.image = nil
                imageView.isHidden = true
                label.isHidden = true
            
            case .crown:
                imageView.image = UIImage(systemName: "crown.fill")
                backgroundView.themeBackgroundColor = .profileIcon_background
                imageView.isHidden = false
                label.isHidden = true
                
                ThemeManager.onThemeChange(observer: imageView) { [weak imageView] _, primaryColor in
                    let targetColor: ThemeValue = (primaryColor == .green ?
                        .profileIcon_greenPrimaryColor :
                        .profileIcon
                    )
                    
                    guard imageView?.themeTintColor != targetColor else { return }
                    
                    imageView?.themeTintColor = targetColor
                }
                
            case .rightPlus:
                imageView.image = UIImage(
                    systemName: "plus",
                    withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
                )
                imageView.themeTintColor = .black
                backgroundView.themeBackgroundColor = .primary
                imageView.isHidden = false
                label.isHidden = true
                
            case .letter(let character):
                label.themeTextColor = .backgroundPrimary
                backgroundView.themeBackgroundColor = .textPrimary
                label.isHidden = false
                label.text = "\(character)"
        }
    }
    
    // MARK: - Content
    
    private func prepareForReuse() {
        imageView.contentMode = .scaleAspectFill
        imageView.isHidden = true
        animatedImageView.contentMode = .scaleAspectFill
        animatedImageView.isHidden = true
        imageContainerView.clipsToBounds = clipsToBounds
        imageContainerView.themeBackgroundColor = .backgroundSecondary
        additionalImageContainerView.isHidden = true
        animatedImageView.image = nil
        additionalImageView.image = nil
        additionalAnimatedImageView.image = nil
        additionalImageView.isHidden = true
        additionalAnimatedImageView.isHidden = true
        additionalImageContainerView.clipsToBounds = clipsToBounds
        
        imageViewTopConstraint.isActive = false
        imageViewLeadingConstraint.isActive = false
        imageViewCenterXConstraint.isActive = true
        imageViewCenterYConstraint.isActive = true
        profileIconBackgroundView.isHidden = true
        profileIconBackgroundLeadingAlignConstraint.isActive = false
        profileIconBackgroundTrailingAlignConstraint.isActive = false
        profileIconImageView.isHidden = true
        profileIconLabel.isHidden = true
        additionalProfileIconBackgroundView.isHidden = true
        additionalProfileIconBackgroundLeadingAlignConstraint.isActive = false
        additionalProfileIconBackgroundTrailingAlignConstraint.isActive = false
        additionalProfileIconImageView.isHidden = true
        additionalProfileIconLabel.isHidden = true
        imageEdgeConstraints.forEach { $0.constant = 0 }
        additionalImageEdgeConstraints.forEach { $0.constant = 0 }
    }
    
    public func update(
        _ info: Info,
        additionalInfo: Info? = nil
    ) {
        prepareForReuse()
        
        // Sort out the icon first
        updateIconView(
            icon: info.icon,
            imageView: profileIconImageView,
            label: profileIconLabel,
            backgroundView: profileIconBackgroundView,
            topConstraint: profileIconTopConstraint,
            leadingAlignConstraint: profileIconBackgroundLeadingAlignConstraint,
            trailingAlignConstraint: profileIconBackgroundTrailingAlignConstraint,
            bottomConstraint: profileIconBottomConstraint
        )
        
        // Populate the main imageView
        switch info.imageData?.guessedImageFormat {
            case .gif, .webp: animatedImageView.image = info.imageData.map { YYImage(data: $0) }
            default:
                imageView.image = info.imageData
                    .map {
                        guard info.renderingMode != .automatic else { return UIImage(data: $0) }
                        
                        return UIImage(data: $0)?.withRenderingMode(info.renderingMode)
                    }
        }
        
        imageView.themeTintColor = info.themeTintColor
        imageView.isHidden = (imageView.image == nil)
        animatedImageView.themeTintColor = info.themeTintColor
        animatedImageView.isHidden = (animatedImageView.image == nil)
        imageContainerView.themeBackgroundColor = info.backgroundColor
        imageContainerView.themeBackgroundColorForced = info.forcedBackgroundColor
        profileIconBackgroundView.layer.cornerRadius = (size.iconSize / 2)
        imageEdgeConstraints.enumerated().forEach { index, constraint in
            switch index % 4 {
                case 0: constraint.constant = info.inset.top
                case 1: constraint.constant = info.inset.left
                case 2: constraint.constant = -info.inset.bottom
                case 3: constraint.constant = -info.inset.right
                default: break
            }
        }
        
        // Check if there is a second image (if not then set the size and finish)
        guard let additionalInfo: Info = additionalInfo else {
            imageViewWidthConstraint.constant = size.imageSize
            imageViewHeightConstraint.constant = size.imageSize
            imageContainerView.layer.cornerRadius = (imageContainerView.clipsToBounds ? (size.imageSize / 2) : 0)
            return
        }
        
        // Sort out the additional icon first
        updateIconView(
            icon: additionalInfo.icon,
            imageView: additionalProfileIconImageView,
            label: additionalProfileIconLabel,
            backgroundView: additionalProfileIconBackgroundView,
            topConstraint: additionalProfileIconTopConstraint,
            leadingAlignConstraint: additionalProfileIconBackgroundLeadingAlignConstraint,
            trailingAlignConstraint: additionalProfileIconBackgroundTrailingAlignConstraint,
            bottomConstraint: additionalProfileIconBottomConstraint
        )
        
        // Set the additional image content and reposition the image views correctly
        switch additionalInfo.imageData?.guessedImageFormat {
            case .gif, .webp: additionalAnimatedImageView.image = additionalInfo.imageData.map { YYImage(data: $0) }
            default:
                additionalImageView.image = additionalInfo.imageData
                    .map {
                        guard additionalInfo.renderingMode != .automatic else { return UIImage(data: $0) }
                        
                        return UIImage(data: $0)?.withRenderingMode(additionalInfo.renderingMode)
                    }
        }
        
        additionalImageView.themeTintColor = additionalInfo.themeTintColor
        additionalImageView.isHidden = (additionalImageView.image == nil)
        additionalAnimatedImageView.themeTintColor = additionalInfo.themeTintColor
        additionalAnimatedImageView.isHidden = (additionalAnimatedImageView.image == nil)
        additionalImageContainerView.isHidden = false
        
        switch (info.backgroundColor, info.forcedBackgroundColor) {
            case (_, .some(let color)): additionalImageContainerView.themeBackgroundColorForced = color
            case (.some(let color), _): additionalImageContainerView.themeBackgroundColor = color
            default: additionalImageContainerView.themeBackgroundColor = .primary
        }
        
        additionalImageEdgeConstraints.enumerated().forEach { index, constraint in
            switch index % 4 {
                case 0: constraint.constant = additionalInfo.inset.top
                case 1: constraint.constant = additionalInfo.inset.left
                case 2: constraint.constant = -additionalInfo.inset.bottom
                case 3: constraint.constant = -additionalInfo.inset.right
                default: break
            }
        }
        
        imageViewTopConstraint.isActive = true
        imageViewLeadingConstraint.isActive = true
        imageViewCenterXConstraint.isActive = false
        imageViewCenterYConstraint.isActive = false
        
        imageViewWidthConstraint.constant = size.multiImageSize
        imageViewHeightConstraint.constant = size.multiImageSize
        imageContainerView.layer.cornerRadius = (imageContainerView.clipsToBounds ? (size.multiImageSize / 2) : 0)
        additionalImageViewWidthConstraint.constant = size.multiImageSize
        additionalImageViewHeightConstraint.constant = size.multiImageSize
        additionalImageContainerView.layer.cornerRadius = (additionalImageContainerView.clipsToBounds ?
            (size.multiImageSize / 2) :
            0
        )
        additionalProfileIconBackgroundView.layer.cornerRadius = (size.iconSize / 2)
    }
}
