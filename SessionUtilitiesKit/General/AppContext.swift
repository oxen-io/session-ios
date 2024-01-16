// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit

// MARK: - Singleton

public extension Singleton {
    static let appContext: SingletonConfig<AppContext> = Dependencies.create(
        identifier: "appContext",
        createInstance: { _ in preconditionFailure("The AppContext must be set manually before accessing it") }
    )
}

// MARK: - AppContext

public protocol AppContext: AnyObject {
    var _temporaryDirectory: String? { get set }
    var isMainApp: Bool { get }
    var isMainAppAndActive: Bool { get }
    var isShareExtension: Bool { get }
    var reportedApplicationState: UIApplication.State { get }
    var mainWindow: UIWindow? { get }
    var frontmostViewController: UIViewController? { get }
    
    static func determineDeviceRTL() -> Bool
    
    func setMainWindow(_ mainWindow: UIWindow)
    func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any])
    func beginBackgroundTask(expirationHandler: @escaping () -> ()) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier)
    
    /// **Note:** We need to call this method on launch _and_ every time the app becomes active,
    /// since file protection may prevent it from succeeding in the background.
    func clearOldTemporaryDirectories()
}

// MARK: - Defaults

public extension AppContext {
    var isMainApp: Bool { false }
    var isMainAppAndActive: Bool { false }
    var isShareExtension: Bool { false }
    var mainWindow: UIWindow? { nil }
    var frontmostViewController: UIViewController? { nil }
    
    var isInBackground: Bool { reportedApplicationState == .background }
    var isAppForegroundAndActive: Bool { reportedApplicationState == .active }
    
    // MARK: - Paths
    
    var temporaryDirectory: String {
        if let dir: String = _temporaryDirectory { return dir }
        
        let dirName: String = "ows_temp_\(UUID().uuidString)"   // stringlint:disable
        let dirPath: String = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(dirName)
            .path
        _temporaryDirectory = dirPath
        FileSystem.temporaryDirectory.mutate { $0 = dirPath }
        try? FileSystem.ensureDirectoryExists(at: dirPath, fileProtectionType: .complete)
        
        return dirPath
    }
    
    var temporaryDirectoryAccessibleAfterFirstAuth: String {
        let dirPath: String = NSTemporaryDirectory()
        try? FileSystem.ensureDirectoryExists(at: dirPath, fileProtectionType: .completeUntilFirstUserAuthentication)
        
        return dirPath
    }
    
    // MARK: - Functions
    
    func setMainWindow(_ mainWindow: UIWindow) {}
    func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any]) {}
    func beginBackgroundTask(expirationHandler: @escaping () -> ()) -> UIBackgroundTaskIdentifier { return .invalid }
    func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier) {}
    
    func createTemporaryDirectory() { _ = temporaryDirectory }
    func clearOldTemporaryDirectories() {}
}
