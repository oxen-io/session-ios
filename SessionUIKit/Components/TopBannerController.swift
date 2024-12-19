// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class TopBannerController: UIViewController {
    public enum Warning: String, Codable {
        case invalid
        
        var shouldAppearOnResume: Bool {
            switch self {
                case .invalid: return false
            }
        }
        
        var text: String {
            switch self {
                case .invalid: return ""
            }
        }
    }
    
    private static var lastInstance: TopBannerController?
    private let child: UIViewController
    private var initialCachedWarning: Warning?
    
    // MARK: - UI
    
    private lazy var bottomConstraint: NSLayoutConstraint = bannerLabel
        .pin(.bottom, to: .bottom, of: bannerContainer, withInset: -Values.verySmallSpacing)
    
    private let contentStackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.axis = .vertical
        result.distribution = .fill
        result.alignment = .fill
        
        return result
    }()
    
    private let bannerContainer: UIView = {
        let result: UIView = UIView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.themeBackgroundColor = .primary
        result.isHidden = true
        
        return result
    }()
    
    private let bannerLabel: UILabel = {
        let result: UILabel = UILabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setContentHuggingPriority(.required, for: .vertical)
        result.font = .systemFont(ofSize: Values.verySmallFontSize)
        result.textAlignment = .center
        result.themeTextColor = .black
        result.numberOfLines = 0
        
        return result
    }()
    
    private lazy var closeButton: UIButton = {
        let result: UIButton = UIButton()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setImage(
            UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        result.contentMode = .center
        result.themeTintColor = .black
        result.addTarget(self, action: #selector(dismissBannerTapped), for: .touchUpInside)
        
        return result
    }()
    
    // MARK: - Initialization
    
    public init(
        child: UIViewController,
        cachedWarning: Warning? = nil
    ) {
        self.child = child
        self.initialCachedWarning = cachedWarning
        
        super.init(nibName: nil, bundle: nil)
        
        TopBannerController.lastInstance = self
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    public override func loadView() {
        super.loadView()
        
        view.addSubview(contentStackView)
        
        contentStackView.addArrangedSubview(bannerContainer)
        attachChild()
        
        bannerContainer.addSubview(bannerLabel)
        bannerContainer.addSubview(closeButton)
        
        setupLayout()
        
        // If we had an initial warning then show it
        if let warning: Warning = self.initialCachedWarning {
            UIView.performWithoutAnimation {
                TopBannerController.show(warning: warning)
            }
            
            self.initialCachedWarning = nil
        }
    }
    
    private func setupLayout() {
        contentStackView.pin(.top, to: .top, of: view.safeAreaLayoutGuide)
        contentStackView.pin(.leading, to: .leading, of: view)
        contentStackView.pin(.trailing, to: .trailing, of: view)
        contentStackView.pin(.bottom, to: .bottom, of: view)
        
        bannerLabel.pin(.top, to: .top, of: view.safeAreaLayoutGuide, withInset: Values.verySmallSpacing)
        bannerLabel.pin(.leading, to: .leading, of: bannerContainer, withInset: Values.veryLargeSpacing)
        bannerLabel.pin(.trailing, to: .trailing, of: bannerContainer, withInset: -Values.veryLargeSpacing)
        bottomConstraint.isActive = false
        
        let buttonSize: CGFloat = (12 + (Values.smallSpacing * 2))
        closeButton.center(.vertical, in: bannerLabel)
        closeButton.pin(.trailing, to: .trailing, of: bannerContainer, withInset: -Values.smallSpacing)
        closeButton.set(.width, to: buttonSize)
        closeButton.set(.height, to: buttonSize)
    }
    
    // MARK: - Actions
    
    @objc private func dismissBannerTapped() {
        // Remove the cached warning
        SNUIKit.topBannerChanged(to: nil)
        
        UIView.animate(
            withDuration: 0.3,
            animations: { [weak self] in
                self?.bottomConstraint.isActive = false
                self?.contentStackView.setNeedsLayout()
                self?.contentStackView.layoutIfNeeded()
            },
            completion: { [weak self] _ in
                self?.bannerContainer.isHidden = true
            }
        )
    }
    
    // MARK: - Functions
    public func wrappedViewController() -> UIViewController? {
        if let navVC = child as? UINavigationController {
            return navVC.topViewController
        }
        return child
    }
    
    public func attachChild() {
        child.willMove(toParent: self)
        addChild(child)
        contentStackView.addArrangedSubview(child.view)
        child.didMove(toParent: self)
    }
    
    public static func show(
        warning: Warning,
        inWindowFor view: UIView? = nil
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                TopBannerController.show(warning: warning, inWindowFor: view)
            }
            return
        }
        
        // Not an ideal approach but should allow us to have a single banner
        guard let instance: TopBannerController = ((view?.window?.rootViewController as? TopBannerController) ?? TopBannerController.lastInstance) else {
            return
        }
        
        // Cache the banner to show (so we can show it on re-launch)
        if instance.initialCachedWarning != nil && warning != instance.initialCachedWarning {
            SNUIKit.topBannerChanged(to: warning)
        }
        
        UIView.performWithoutAnimation {
            instance.bannerLabel.text = warning.text
            instance.bannerLabel.setNeedsLayout()
            instance.bannerLabel.layoutIfNeeded()
            instance.bottomConstraint.isActive = false
            instance.bannerContainer.isHidden = false
        }
        
        UIView.animate(withDuration: 0.3) { [weak instance] in
            instance?.bottomConstraint.isActive = true
            instance?.contentStackView.setNeedsLayout()
            instance?.contentStackView.layoutIfNeeded()
        }
    }
    
    public static func hide(inWindowFor view: UIView? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                TopBannerController.hide(inWindowFor: view)
            }
            return
        }
        
        // Not an ideal approach but should allow us to have a single banner
        guard let instance: TopBannerController = ((view?.window?.rootViewController as? TopBannerController) ?? TopBannerController.lastInstance) else {
            return
        }
        
        UIView.performWithoutAnimation { instance.dismissBannerTapped() }
    }
}
