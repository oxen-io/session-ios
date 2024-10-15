// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

final class MainAppContext: AppContext {
    private let dependencies: Dependencies
    var _temporaryDirectory: String?
    var reportedApplicationState: UIApplication.State
    
    let appLaunchTime = Date()
    let isMainApp: Bool = true
    var isMainAppAndActive: Bool {
        var result: Bool = false
        
        switch Thread.isMainThread {
            case true: result = (UIApplication.shared.applicationState == .active)
            case false:
                DispatchQueue.main.sync {
                    result = (UIApplication.shared.applicationState == .active)
                }
        }
        
        return result
    }
    var frontMostViewController: UIViewController? {
        UIApplication.shared.frontMostViewController(ignoringAlerts: true, using: dependencies)
    }
    var backgroundTimeRemaining: TimeInterval { UIApplication.shared.backgroundTimeRemaining }
    
    var mainWindow: UIWindow?
    var wasWokenUpByPushNotification: Bool = false
    
    var statusBarHeight: CGFloat { UIApplication.shared.statusBarFrame.size.height }
    var openSystemSettingsAction: UIAlertAction? {
        let result = UIAlertAction(
            title: "sessionSettings".localized(),
            style: .default
        ) { _ in UIApplication.shared.openSystemSettings() }
        result.accessibilityIdentifier = "\(type(of: self)).system_settings"
        
        return result
    }
    
    static func determineDeviceRTL() -> Bool {
        return (UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft)
    }
    
    // MARK: - Initialization

    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
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
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Notifications
    
    @objc private func applicationWillEnterForeground(notification: NSNotification) {
        Log.assertOnMainThread()

        self.reportedApplicationState = .inactive

        NotificationCenter.default.post(
            name: .sessionWillEnterForeground,
            object: nil
        )
    }

    @objc private func applicationDidEnterBackground(notification: NSNotification) {
        Log.assertOnMainThread()
        
        self.reportedApplicationState = .background

        NotificationCenter.default.post(
            name: .sessionDidEnterBackground,
            object: nil
        )
    }

    @objc private func applicationWillResignActive(notification: NSNotification) {
        Log.assertOnMainThread()

        self.reportedApplicationState = .inactive

        NotificationCenter.default.post(
            name: .sessionWillResignActive,
            object: nil
        )
    }

    @objc private func applicationDidBecomeActive(notification: NSNotification) {
        Log.assertOnMainThread()

        self.reportedApplicationState = .active

        NotificationCenter.default.post(
            name: .sessionDidBecomeActive,
            object: nil
        )
    }
    
    // MARK: - AppContext Functions
    
    func setMainWindow(_ mainWindow: UIWindow) {
        self.mainWindow = mainWindow
        
        // Store in SessionUIKit to avoid needing the SessionUtilitiesKit dependency
        SNUIKit.setMainWindow(mainWindow)
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
                var logString: String = "Blocking sleep because of: \(String(describing: blockingObjects.first))" // stringlint:disable
                
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
    
    // MARK: - Temporary Directories
    
    var temporaryDirectory: String { temporaryDirectory(using: dependencies) }
    var temporaryDirectoryAccessibleAfterFirstAuth: String {
        temporaryDirectoryAccessibleAfterFirstAuth(using: dependencies)
    }
    
    func clearOldTemporaryDirectories() {
        // We use the lowest priority queue for this, and wait N seconds
        // to avoid interfering with app startup.
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + .seconds(3)) { [weak self, dependencies] in
            guard
                self?.isAppForegroundAndActive == true,   // Abort if app not active
                let thresholdDate: Date = self?.appLaunchTime
            else { return }
            
            // Ignore the "current" temp directory.
            let currentTempDirName: String = URL(fileURLWithPath: dependencies[singleton: .appContext].temporaryDirectory).lastPathComponent
            let dirPath = NSTemporaryDirectory()
            
            guard let fileNames: [String] = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { return }
            
            fileNames.forEach { fileName in
                guard fileName != currentTempDirName else { return }
                
                // Delete files with either:
                //
                // a) "ows_temp" name prefix.
                // b) modified time before app launch time.
                let filePath: String = URL(fileURLWithPath: dirPath).appendingPathComponent(fileName).path
                
                if !fileName.hasPrefix("ows_temp") { // stringlint:disable
                    // It's fine if we can't get the attributes (the file may have been deleted since we found it),
                    // also don't delete files which were created in the last N minutes
                    guard
                        let attributes: [FileAttributeKey: Any] = try? FileManager.default.attributesOfItem(atPath: filePath),
                        let modificationDate: Date = attributes[.modificationDate] as? Date,
                        modificationDate.timeIntervalSince1970 <= thresholdDate.timeIntervalSince1970
                    else { return }
                }
                
                // This can happen if the app launches before the phone is unlocked.
                // Clean up will occur when app becomes active.
                try? FileSystem.deleteFile(at: filePath)
            }
        }
    }
}
