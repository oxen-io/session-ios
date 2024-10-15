// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit

// MARK: - Singleton

public extension Singleton {
    static let appContext: SingletonConfig<AppContext> = Dependencies.create(
        identifier: "appContext",
        createInstance: { _ in NoopAppContext() }
    )
}

// MARK: - AppContext

public protocol AppContext: AnyObject {
    var _temporaryDirectory: String? { get set }
    var isValid: Bool { get }
    var isMainApp: Bool { get }
    var isMainAppAndActive: Bool { get }
    var isShareExtension: Bool { get }
    var reportedApplicationState: UIApplication.State { get }
    var mainWindow: UIWindow? { get }
    var frontMostViewController: UIViewController? { get }
    var backgroundTimeRemaining: TimeInterval { get }
    
    func setMainWindow(_ mainWindow: UIWindow)
    func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any])
    func beginBackgroundTask(expirationHandler: @escaping () -> ()) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier)
    
    var temporaryDirectory: String { get }
    var temporaryDirectoryAccessibleAfterFirstAuth: String { get }
    
    /// **Note:** We need to call this method on launch _and_ every time the app becomes active,
    /// since file protection may prevent it from succeeding in the background.
    func clearOldTemporaryDirectories()
}

// MARK: - Defaults

public extension AppContext {
    var isValid: Bool { true }
    var isMainApp: Bool { false }
    var isMainAppAndActive: Bool { false }
    var isShareExtension: Bool { false }
    var mainWindow: UIWindow? { nil }
    var frontMostViewController: UIViewController? { nil }
    var backgroundTimeRemaining: TimeInterval { 0 }
    
    var isInBackground: Bool { reportedApplicationState == .background }
    var isAppForegroundAndActive: Bool { reportedApplicationState == .active }
    
    // MARK: - Functions
    
    func setMainWindow(_ mainWindow: UIWindow) {}
    func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any]) {}
    func beginBackgroundTask(expirationHandler: @escaping () -> ()) -> UIBackgroundTaskIdentifier { return .invalid }
    func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier) {}
    
    func createTemporaryDirectory() { _ = temporaryDirectory }
    func temporaryDirectory(using dependencies: Dependencies) -> String {
        if let dir: String = _temporaryDirectory { return dir }
        
        let dirName: String = "ows_temp_\(UUID().uuidString)"   // stringlint:disable
        let dirPath: String = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(dirName)
            .path
        _temporaryDirectory = dirPath
        FileSystem.temporaryDirectory.mutate { $0 = dirPath }
        try? FileSystem.ensureDirectoryExists(at: dirPath, fileProtectionType: .complete, using: dependencies)
        
        return dirPath
    }
    
    func temporaryDirectoryAccessibleAfterFirstAuth(using dependencies: Dependencies) -> String {
        let dirPath: String = NSTemporaryDirectory()
        try? FileSystem.ensureDirectoryExists(
            at: dirPath,
            fileProtectionType: .completeUntilFirstUserAuthentication,
            using: dependencies
        )
        
        return dirPath
    }
    
    func clearOldTemporaryDirectories() {}
}

private final class NoopAppContext: AppContext {
    var _temporaryDirectory: String? = nil
    let mainWindow: UIWindow? = nil
    let frontMostViewController: UIViewController? = nil
    
    var isValid: Bool { false }
    var isMainApp: Bool { false }
    var isMainAppAndActive: Bool { false }
    var isShareExtension: Bool { false }
    var reportedApplicationState: UIApplication.State { .inactive }
    var backgroundTimeRemaining: TimeInterval { 0 }
    
    // Override the extension functions
    var isInBackground: Bool { false }
    var isAppForegroundAndActive: Bool { false }
    
    func setMainWindow(_ mainWindow: UIWindow) {}
    func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any]) {}
    func beginBackgroundTask(expirationHandler: @escaping () -> ()) -> UIBackgroundTaskIdentifier { return .invalid }
    func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier) {}
    
    var temporaryDirectory: String { "" }
    var temporaryDirectoryAccessibleAfterFirstAuth: String { "" }
    func clearOldTemporaryDirectories() {}
}
