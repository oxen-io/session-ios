// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SignalUtilitiesKit
import SessionUtilitiesKit
import SessionMessagingKit
import SignalCoreKit

/// This is _NOT_ a singleton and will be instantiated each time that the SAE is used.
final class ShareAppExtensionContext: AppContext {
    var _temporaryDirectory: String?
    var rootViewController: UIViewController
    var reportedApplicationState: UIApplication.State
    
    let appLaunchTime: Date = Date()
    let isShareExtension: Bool = true
    
    var mainWindow: UIWindow?
    var wasWokenUpByPushNotification: Bool = false
    
    var statusBarHeight: CGFloat { return 20 }
    var openSystemSettingsAction: UIAlertAction?
    
    static func determineDeviceRTL() -> Bool {
        // Borrowed from PureLayout's AppExtension compatible RTL support.
        // App Extensions may not access -[UIApplication sharedApplication]; fall back
        // to checking the bundle's preferred localization character direction
        return (
            Locale.characterDirection(
                forLanguage: (Bundle.main.preferredLocalizations.first ?? "")
            ) == Locale.LanguageDirection.rightToLeft
        )
    }
    
    // MARK: - Initialization

    init(rootViewController: UIViewController) {
        self.rootViewController = rootViewController
        self.reportedApplicationState = .active
        self.createTemporaryDirectory()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(extensionHostDidBecomeActive(notification:)),
            name: .NSExtensionHostDidBecomeActive,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(extensionHostWillResignActive(notification:)),
            name: .NSExtensionHostWillResignActive,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(extensionHostDidEnterBackground(notification:)),
            name: .NSExtensionHostDidEnterBackground,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(extensionHostWillEnterForeground(notification:)),
            name: .NSExtensionHostWillEnterForeground,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Notifications
    
    @objc private func extensionHostDidBecomeActive(notification: NSNotification) {
        AssertIsOnMainThread()
        OWSLogger.info("")

        self.reportedApplicationState = .active
        
        NotificationCenter.default.post(
            name: .sessionDidBecomeActive,
            object: nil
        )
    }
    
    @objc private func extensionHostWillResignActive(notification: NSNotification) {
        AssertIsOnMainThread()

        self.reportedApplicationState = .inactive
        
        OWSLogger.info("")
        DDLog.flushLog()

        NotificationCenter.default.post(
            name: .sessionWillResignActive,
            object: nil
        )
    }

    @objc private func extensionHostDidEnterBackground(notification: NSNotification) {
        AssertIsOnMainThread()
        
        OWSLogger.info("")
        DDLog.flushLog()

        self.reportedApplicationState = .background

        NotificationCenter.default.post(
            name: .sessionDidEnterBackground,
            object: nil
        )
    }

    @objc private func extensionHostWillEnterForeground(notification: NSNotification) {
        AssertIsOnMainThread()
        
        OWSLogger.info("")

        self.reportedApplicationState = .inactive

        NotificationCenter.default.post(
            name: .sessionWillEnterForeground,
            object: nil
        )
    }
    
    // MARK: - AppContext Functions
    
    func frontmostViewController() -> UIViewController? {
        return rootViewController.findFrontmostViewController(ignoringAlerts: true)
    }
    
    func setStatusBarHidden(_ isHidden: Bool, animated isAnimated: Bool) {
        OWSLogger.info("Ignoring request to show/hide status bar since we're in an app extension")
    }
    
    func setNetworkActivityIndicatorVisible(_ value: Bool) {
        owsFailDebug("")
    }
}
