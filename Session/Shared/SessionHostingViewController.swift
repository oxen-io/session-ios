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

    internal func setUpNavBarSessionIcon() {
        let logoImageView = UIImageView()
        logoImageView.image = #imageLiteral(resourceName: "SessionGreen32")
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.set(.width, to: 32)
        logoImageView.set(.height, to: 32)
        
        navigationItem.titleView = logoImageView
    }
    
    internal func setUpClearDataBackButton(flow: Onboarding.Flow) {
        if #available(iOS 16.0, *) {
            navigationItem.backAction = UIAction() { [weak self] action in
                switch flow {
                    case .register:
                        self?.clearDataForAccountCreation()
                    case .recover:
                        self?.clearDataForLoadAccount()
                }
            }
        } else {
            let action: Selector = {
                switch flow {
                    case .register:
                        return #selector(clearDataForAccountCreation)
                    case .recover:
                        return #selector(clearDataForLoadAccount)
                    }
            }()
            let clearDataBackButton = UIBarButtonItem(
                image: UIImage(
                    systemName: "chevron.backward",
                    withConfiguration: UIImage.SymbolConfiguration(textStyle: .headline, scale: .large)
                ),
                style: .plain,
                target: self,
                action: action
            )
            clearDataBackButton.imageInsets = .init(top: 0, leading: -8, bottom: 0, trailing: 8)
            clearDataBackButton.themeTintColor = .textPrimary
            navigationItem.leftBarButtonItem = clearDataBackButton
        }
    }
    
    @objc private func clearDataForAccountCreation() {
        let modal: ConfirmationModal = ConfirmationModal(
            targetView: self.view,
            info: ConfirmationModal.Info(
                title: "warning".localized(),
                body: .text("onboardingBackAccountCreation".localized()),
                confirmTitle: "quitButton".localized(),
                confirmAccessibility: Accessibility(identifier: "Confirm quit"),
                confirmStyle: .danger,
                cancelStyle: .textPrimary,
                onConfirm: { [weak self] confirmationModal in
                    self?.deleteAllLocalData()
                }
            )
        )
        self.present(modal, animated: true)
    }
    
    @objc private func clearDataForLoadAccount() {
        let modal: ConfirmationModal = ConfirmationModal(
            targetView: self.view,
            info: ConfirmationModal.Info(
                title: "warning".localized(),
                body: .text("onboardingBackLoadAccount".localized()),
                confirmTitle: "quitButton".localized(),
                confirmStyle: .danger,
                cancelStyle: .textPrimary,
                onConfirm: { [weak self] confirmationModal in
                    self?.deleteAllLocalData()
                }
            )
        )
        self.present(modal, animated: true)
    }
    
    private func deleteAllLocalData(using dependencies: Dependencies = Dependencies()) {
        /// Stop and cancel all current jobs (don't want to inadvertantly have a job store data after it's table has already been cleared)
        ///
        /// **Note:** This is file as long as this process kills the app, if it doesn't then we need an alternate mechanism to flag that
        /// the `JobRunner` is allowed to start it's queues again
        JobRunner.stopAndClearPendingJobs(using: dependencies)
        
        // Clear the app badge and notifications
        AppEnvironment.shared.notificationPresenter.clearAllNotifications()
        UIApplication.shared.applicationIconBadgeNumber = 0
        
        // Clear out the user defaults
        UserDefaults.removeAll()
        
        // Remove the cached key so it gets re-cached on next access
        dependencies.caches.mutate(cache: .general) {
            $0.encodedPublicKey = nil
            $0.recentReactionTimestamps = []
        }
        
        // Stop any pollers
        (UIApplication.shared.delegate as? AppDelegate)?.stopPollers()
        
        // Call through to the SessionApp's "resetAppData" which will wipe out logs, database and
        // profile storage
        let wasUnlinked: Bool = UserDefaults.standard[.wasUnlinked]
        
        SessionApp.resetAppData {
            // Resetting the data clears the old user defaults. We need to restore the unlink default.
            UserDefaults.standard[.wasUnlinked] = wasUnlinked
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
