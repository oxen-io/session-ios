// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit

public class HostWrapper: ObservableObject {
    public weak var controller: UIViewController?
}

public enum NavigationItem {
    case profile(profile: Profile)
    case search
    case close
}

public class SessionHostingViewController<Content>: UIHostingController<ModifiedContent<Content, _EnvironmentKeyWritingModifier<HostWrapper?>>>, ThemedNavigation where Content : View {
    public override var preferredStatusBarStyle: UIStatusBarStyle {
        return ThemeManager.currentTheme.statusBarStyle
    }
    
    public var navigationBackground: ThemeValue? { customizedNavigationBackground }
    private let customizedNavigationBackground: ThemeValue?
    private let shouldHideNavigationBar: Bool
    
    private var leftBarButtonItemAction: (() -> ())?
    private var rightBarButtonItemAction: (() -> ())?

    lazy var navBarTitleLabel: UILabel = {
        let result = UILabel()
        result.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        result.alpha = 1

        return result
    }()

    lazy var crossfadeLabel: UILabel = {
        let result = UILabel()
        result.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        result.alpha = 0

        return result
    }()
    
    public init(rootView:Content, customizedNavigationBackground: ThemeValue? = nil, shouldHideNavigationBar: Bool = false) {
        self.customizedNavigationBackground = customizedNavigationBackground
        self.shouldHideNavigationBar = shouldHideNavigationBar
        let container = HostWrapper()
        let modified = rootView.environmentObject(container) as! ModifiedContent<Content, _EnvironmentKeyWritingModifier<HostWrapper?>>
        super.init(rootView: modified)
        container.controller = self
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.backButtonTitle = ""
        view.themeBackgroundColor = .backgroundPrimary
        ThemeManager.applyNavigationStylingIfNeeded(to: self)

        setNeedsStatusBarAppearanceUpdate()
    }
    
    public override func viewWillAppear(_ animated: Bool) {
        if shouldHideNavigationBar {
            self.navigationController?.setNavigationBarHidden(true, animated: animated)
        }
        super.viewWillAppear(animated)
    }
    
    public override func viewWillDisappear(_ animated: Bool) {
        if shouldHideNavigationBar {
            self.navigationController?.setNavigationBarHidden(false, animated: animated)
        }
        super.viewWillDisappear(animated)
    }
    
    // MARK: Navigation bar title

    internal func setNavBarTitle(_ title: String, customFontSize: CGFloat? = nil) {
        let container = UIView()
        navBarTitleLabel.text = title
        crossfadeLabel.text = title

        if let customFontSize = customFontSize {
            navBarTitleLabel.font = .boldSystemFont(ofSize: customFontSize)
            crossfadeLabel.font = .boldSystemFont(ofSize: customFontSize)
        }

        container.addSubview(navBarTitleLabel)
        container.addSubview(crossfadeLabel)

        navBarTitleLabel.pin(to: container)
        crossfadeLabel.pin(to: container)

        navigationItem.titleView = container
    }
    
    internal func setUpNavBarSessionHeading() {
        let headingImageView = UIImageView(
            image: UIImage(named: "SessionHeading")?
                .withRenderingMode(.alwaysTemplate)
        )
        headingImageView.themeTintColor = .textPrimary
        headingImageView.contentMode = .scaleAspectFit
        headingImageView.set(.width, to: 150)
        headingImageView.set(.height, to: Values.mediumFontSize)
        
        navigationItem.titleView = headingImageView
    }

    internal func setUpNavBarSessionIcon() {
        let logoImageView = UIImageView()
        logoImageView.image = #imageLiteral(resourceName: "SessionGreen32")
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.set(.width, to: 32)
        logoImageView.set(.height, to: 32)
        
        navigationItem.titleView = logoImageView
    }
    
    // MARK: Navigation bar button items
    
    internal func setUpNavBarButton(leftItem: NavigationItem? = nil, rightItem: NavigationItem? = nil, leftAction: (() -> ())? = nil, rightAction: (() -> ())? = nil) {
        self.leftBarButtonItemAction = leftAction
        self.rightBarButtonItemAction = rightAction
        navigationItem.leftBarButtonItem = generateBarButtonItem(item: leftItem, action: #selector(leftBarButtonAction))
        navigationItem.rightBarButtonItem = generateBarButtonItem(item: rightItem, action: #selector(rightBarButtonAction))
    }
    
    private func generateBarButtonItem(item: NavigationItem?, action: Selector?) -> UIBarButtonItem? {
        guard let navigationItem: NavigationItem = item else { return nil }
        switch navigationItem {
            case .profile(let profile):
                // Profile picture view
                let profilePictureView = ProfilePictureView(size: .navigation)
                profilePictureView.accessibilityIdentifier = "User settings"
                profilePictureView.accessibilityLabel = "User settings"
                profilePictureView.isAccessibilityElement = true
                profilePictureView.update(
                    publicKey: profile.id,
                    threadVariant: .contact,
                    customImageData: nil,
                    profile: profile,
                    additionalProfile: nil
                )
                
                let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: action)
                profilePictureView.addGestureRecognizer(tapGestureRecognizer)
                
                // Path status indicator
                let pathStatusView = PathStatusView()
                pathStatusView.accessibilityLabel = "Current onion routing path indicator"
                
                // Container view
                let profilePictureViewContainer = UIView()
                profilePictureViewContainer.addSubview(profilePictureView)
                profilePictureView.autoPinEdgesToSuperviewEdges()
                profilePictureViewContainer.addSubview(pathStatusView)
                pathStatusView.pin(.trailing, to: .trailing, of: profilePictureViewContainer)
                pathStatusView.pin(.bottom, to: .bottom, of: profilePictureViewContainer)
            
                let result = UIBarButtonItem(customView: profilePictureViewContainer)
                result.isAccessibilityElement = true
                return result
            case .search:
                let result = UIBarButtonItem(barButtonSystemItem: .search, target: self, action: action)
                result.accessibilityLabel = "Search button"
                result.isAccessibilityElement  = true
                return result
            case .close:
                let result = UIBarButtonItem(image: #imageLiteral(resourceName: "X"), style: .plain, target: self, action: #selector(close))
                result.themeTintColor = .textPrimary
                result.isAccessibilityElement = true
                return result
            }
    }
    
    @objc private func leftBarButtonAction() {
        self.leftBarButtonItemAction?()
    }
    
    @objc private func rightBarButtonAction() {
        self.rightBarButtonItemAction?()
    }
    
    @objc private func close() {
        dismiss(animated: true, completion: nil)
    }
}
