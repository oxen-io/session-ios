// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionUtilitiesKit

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

    internal func setUpNavBarSessionIcon(using dependencies: Dependencies) {
        let logoImageView = UIImageView()
        logoImageView.image = #imageLiteral(resourceName: "SessionGreen32")
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.set(.width, to: 32)
        logoImageView.set(.height, to: 32)
        
        switch (dependencies[feature: .serviceNetwork], dependencies[feature: .forceOffline]) {
            case (.mainnet, false): navigationItem.titleView = logoImageView
            case (.testnet, _), (.mainnet, true):
                let containerView: UIView = UIView()
                containerView.clipsToBounds = false
                containerView.addSubview(logoImageView)
                logoImageView.pin(to: containerView)
                
                let labelStackView: UIStackView = UIStackView()
                labelStackView.axis = .vertical
                containerView.addSubview(labelStackView)
                labelStackView.center(in: containerView)
                labelStackView.transform = CGAffineTransform.identity.rotated(by: -(CGFloat.pi / 6))
                
                let testnetLabel: UILabel = UILabel()
                testnetLabel.font = Fonts.boldSpaceMono(ofSize: 14)
                testnetLabel.textAlignment = .center
                
                if dependencies[feature: .serviceNetwork] != .mainnet {
                    labelStackView.addArrangedSubview(testnetLabel)
                }
                
                let offlineLabel: UILabel = UILabel()
                offlineLabel.font = Fonts.boldSpaceMono(ofSize: 14)
                offlineLabel.textAlignment = .center
                labelStackView.addArrangedSubview(offlineLabel)
                
                ThemeManager.onThemeChange(observer: testnetLabel) { [weak testnetLabel, weak offlineLabel] theme, primaryColor in
                    guard
                        let textColor: UIColor = theme.color(for: .textPrimary),
                        let strokeColor: UIColor = theme.color(for: .backgroundPrimary)
                    else { return }
                    
                    if dependencies[feature: .serviceNetwork] != .mainnet {
                        testnetLabel?.attributedText = NSAttributedString(
                            string: dependencies[feature: .serviceNetwork].title,
                            attributes: [
                                .foregroundColor: textColor,
                                .strokeColor: strokeColor,
                                .strokeWidth: -3
                            ]
                        )
                    }
                    
                    offlineLabel?.attributedText = NSAttributedString(
                        string: "Offline",  // stringlint:ignore
                        attributes: [
                            .foregroundColor: textColor,
                            .strokeColor: strokeColor,
                            .strokeWidth: -3
                        ]
                    )
                }
                
                navigationItem.titleView = containerView
        }
        
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
