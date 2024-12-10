// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUtilitiesKit

class MockAppContext: Mock<AppContext>, AppContext {
    var mainWindow: UIWindow? { mock() }
    var frontMostViewController: UIViewController? { mock() }
    
    var isValid: Bool { mock() }
    var appLaunchTime: Date { mock() }
    var isMainApp: Bool { mock() }
    var isMainAppAndActive: Bool { mock() }
    var isShareExtension: Bool { mock() }
    var reportedApplicationState: UIApplication.State { mock() }
    var backgroundTimeRemaining: TimeInterval { mock() }
    
    // Override the extension functions
    var isInBackground: Bool { mock() }
    var isAppForegroundAndActive: Bool { mock() }
    
    func setMainWindow(_ mainWindow: UIWindow) {
        mockNoReturn(args: [mainWindow])
    }
    
    func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any]) {
        mockNoReturn(args: [shouldBeBlocking, blockingObjects])
    }
    
    func beginBackgroundTask(expirationHandler: @escaping () -> ()) -> UIBackgroundTaskIdentifier {
        return mock(args: [expirationHandler])
    }
    
    func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier) {
        mockNoReturn(args: [backgroundTaskIdentifier])
    }
}
