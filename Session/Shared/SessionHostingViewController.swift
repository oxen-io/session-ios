// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit

public class HostWrapper: ObservableObject {
    public weak var controller: UIViewController?
}

public enum NavigationItemPosition {
    case left
    case right
}

public class SessionHostingViewController<Content>: UIHostingController<ModifiedContent<Content, _EnvironmentKeyWritingModifier<HostWrapper?>>>, ThemedNavigation where Content : View {
    public override var preferredStatusBarStyle: UIStatusBarStyle {
        return ThemeManager.currentTheme.statusBarStyle
    }
    
    public var navigationBackground: ThemeValue? { customizedNavigationBackground }
    private let customizedNavigationBackground: ThemeValue?
    private let shouldHideNavigationBar: Bool

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
    
    internal func setUpDismissingButton(on postion: NavigationItemPosition) {
        let closeButton = UIBarButtonItem(image: #imageLiteral(resourceName: "X"), style: .plain, target: self, action: #selector(close))
        closeButton.themeTintColor = .textPrimary
        switch postion {
            case .left:
                navigationItem.leftBarButtonItem = closeButton
            case .right:
                navigationItem.rightBarButtonItem = closeButton
        }
    }
    
    @objc private func close() {
        dismiss(animated: true, completion: nil)
    }
}
