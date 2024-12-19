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
    var isValid: Bool { get }
    var appLaunchTime: Date { get }
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
    
    // Note: CallKit will make the app state as .inactive
    var isInBackground: Bool { reportedApplicationState == .background }
    var isNotInForeground: Bool { reportedApplicationState != .active }
    var isAppForegroundAndActive: Bool { reportedApplicationState == .active }
    
    // MARK: - Functions
    
    func setMainWindow(_ mainWindow: UIWindow) {}
    func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any]) {}
    func beginBackgroundTask(expirationHandler: @escaping () -> ()) -> UIBackgroundTaskIdentifier { return .invalid }
    func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier) {}
}

private final class NoopAppContext: AppContext {
    let mainWindow: UIWindow? = nil
    let frontMostViewController: UIViewController? = nil
    
    var isValid: Bool { false }
    var appLaunchTime: Date { Date(timeIntervalSince1970: 0) }
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
}
