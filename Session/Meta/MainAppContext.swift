// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SignalCoreKit
import SessionUtilitiesKit

final class MainAppContext: AppContext {
    var _temporaryDirectory: String?
    var reportedApplicationState: UIApplication.State
    
    let appLaunchTime = Date()
    let isMainApp: Bool = true
    var isMainAppAndActive: Bool { UIApplication.shared.applicationState == .active }
    var frontmostViewController: UIViewController? { UIApplication.shared.frontmostViewControllerIgnoringAlerts }
    
    var mainWindow: UIWindow?
    var wasWokenUpByPushNotification: Bool = false
    
    var statusBarHeight: CGFloat { UIApplication.shared.statusBarFrame.size.height }
    var openSystemSettingsAction: UIAlertAction? {
        let result = UIAlertAction(
            title: "OPEN_SETTINGS_BUTTON".localized(),
            style: .default
        ) { _ in UIApplication.shared.openSystemSettings() }
        result.accessibilityIdentifier = "\(type(of: self)).system_settings"
        
        return result
    }
    
    static func determineDeviceRTL() -> Bool {
        return (UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft)
    }
    
    // MARK: - Initialization

    init() {
        self.reportedApplicationState = .inactive
        self.createTemporaryDirectory()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground(notification:)),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground(notification:)),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive(notification:)),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(notification:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(notification:)),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Notifications
    
    @objc private func applicationWillEnterForeground(notification: NSNotification) {
        AssertIsOnMainThread()

        self.reportedApplicationState = .inactive
        OWSLogger.info("")

        NotificationCenter.default.post(
            name: .sessionWillEnterForeground,
            object: nil
        )
    }

    @objc private func applicationDidEnterBackground(notification: NSNotification) {
        AssertIsOnMainThread()
        
        self.reportedApplicationState = .background

        OWSLogger.info("")
        DDLog.flushLog()
        
        NotificationCenter.default.post(
            name: .sessionDidEnterBackground,
            object: nil
        )
    }

    @objc private func applicationWillResignActive(notification: NSNotification) {
        AssertIsOnMainThread()

        self.reportedApplicationState = .inactive

        OWSLogger.info("")
        DDLog.flushLog()

        NotificationCenter.default.post(
            name: .sessionWillResignActive,
            object: nil
        )
    }

    @objc private func applicationDidBecomeActive(notification: NSNotification) {
        AssertIsOnMainThread()

        self.reportedApplicationState = .active

        OWSLogger.info("")

        NotificationCenter.default.post(
            name: .sessionDidBecomeActive,
            object: nil
        )
    }

    @objc private func applicationWillTerminate(notification: NSNotification) {
        AssertIsOnMainThread()

        OWSLogger.info("")
        DDLog.flushLog()
    }
    
    // MARK: - AppContext Functions
    
    func setMainWindow(_ mainWindow: UIWindow) {
        self.mainWindow = mainWindow
    }
    
    func setStatusBarHidden(_ isHidden: Bool, animated isAnimated: Bool) {
        UIApplication.shared.setStatusBarHidden(isHidden, with: (isAnimated ? .slide : .none))
    }
    
    func isAppForegroundAndActive() -> Bool {
        return (reportedApplicationState == .active)
    }
    
    func isInBackground() -> Bool {
        return (reportedApplicationState == .background)
    }
    
    func beginBackgroundTask(expirationHandler: @escaping () -> ()) -> UIBackgroundTaskIdentifier {
        return UIApplication.shared.beginBackgroundTask(expirationHandler: expirationHandler)
    }
    
    func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
    }
        
    func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any]) {
        if UIApplication.shared.isIdleTimerDisabled != shouldBeBlocking {
            if shouldBeBlocking {
                var logString: String = "Blocking sleep because of: \(String(describing: blockingObjects.first))"
                
                if blockingObjects.count > 1 {
                    logString = "\(logString) (and \(blockingObjects.count - 1) others)"
                }
                OWSLogger.info(logString)
            }
            else {
                OWSLogger.info("Unblocking Sleep.")
            }
        }
        UIApplication.shared.isIdleTimerDisabled = shouldBeBlocking
    }
    
    func setNetworkActivityIndicatorVisible(_ value: Bool) {
        UIApplication.shared.isNetworkActivityIndicatorVisible = value
    }
}
