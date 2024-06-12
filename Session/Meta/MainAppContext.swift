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
    
    private static var _isRTL: Bool = {
        return (UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft)
    }()
    
    var isRTL: Bool { return MainAppContext._isRTL }
    
    var statusBarHeight: CGFloat { UIApplication.shared.statusBarFrame.size.height }
    var openSystemSettingsAction: UIAlertAction? {
        let result = UIAlertAction(
            title: "OPEN_SETTINGS_BUTTON".localized(),
            style: .default
        ) { _ in UIApplication.shared.openSystemSettings() }
        result.accessibilityIdentifier = "\(type(of: self)).system_settings"
        
        return result
    }
    
    // MARK: - Initialization

    init() {
        self.reportedApplicationState = .inactive
        
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
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Notifications
    
    @objc private func applicationWillEnterForeground(notification: NSNotification) {
        AssertIsOnMainThread()

        self.reportedApplicationState = .inactive

        NotificationCenter.default.post(
            name: .sessionWillEnterForeground,
            object: nil
        )
    }

    @objc private func applicationDidEnterBackground(notification: NSNotification) {
        AssertIsOnMainThread()
        
        self.reportedApplicationState = .background

        NotificationCenter.default.post(
            name: .sessionDidEnterBackground,
            object: nil
        )
    }

    @objc private func applicationWillResignActive(notification: NSNotification) {
        AssertIsOnMainThread()

        self.reportedApplicationState = .inactive

        NotificationCenter.default.post(
            name: .sessionWillResignActive,
            object: nil
        )
    }

    @objc private func applicationDidBecomeActive(notification: NSNotification) {
        AssertIsOnMainThread()

        self.reportedApplicationState = .active

        NotificationCenter.default.post(
            name: .sessionDidBecomeActive,
            object: nil
        )
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
                Log.info(logString)
            }
            else {
                Log.info("Unblocking Sleep.")
            }
        }
        UIApplication.shared.isIdleTimerDisabled = shouldBeBlocking
    }
    
    func setNetworkActivityIndicatorVisible(_ value: Bool) {
        UIApplication.shared.isNetworkActivityIndicatorVisible = value
    }
    
    // MARK: -
    
    func clearOldTemporaryDirectories() {
        // We use the lowest priority queue for this, and wait N seconds
        // to avoid interfering with app startup.
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + .seconds(3)) { [weak self] in
            guard
                self?.isAppForegroundAndActive == true,   // Abort if app not active
                let thresholdDate: Date = self?.appLaunchTime
            else { return }
                    
            // Ignore the "current" temp directory.
            let currentTempDirName: String = URL(fileURLWithPath: Singleton.appContext.temporaryDirectory).lastPathComponent
            let dirPath = NSTemporaryDirectory()
            
            guard let fileNames: [String] = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { return }
            
            fileNames.forEach { fileName in
                guard fileName != currentTempDirName else { return }
                
                // Delete files with either:
                //
                // a) "ows_temp" name prefix.
                // b) modified time before app launch time.
                let filePath: String = URL(fileURLWithPath: dirPath).appendingPathComponent(fileName).path
                
                if !fileName.hasPrefix("ows_temp") {
                    // It's fine if we can't get the attributes (the file may have been deleted since we found it),
                    // also don't delete files which were created in the last N minutes
                    guard
                        let attributes: [FileAttributeKey: Any] = try? FileManager.default.attributesOfItem(atPath: filePath),
                        let modificationDate: Date = attributes[.modificationDate] as? Date,
                        modificationDate.timeIntervalSince1970 <= thresholdDate.timeIntervalSince1970
                    else { return }
                }
                
                if (!OWSFileSystem.deleteFile(filePath)) {
                    // This can happen if the app launches before the phone is unlocked.
                    // Clean up will occur when app becomes active.
                }
            }
        }
    }
}
