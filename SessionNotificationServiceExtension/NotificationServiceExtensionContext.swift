//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//
// stringlint:disable

import UIKit
import SignalUtilitiesKit
import SessionUtilitiesKit

final class NotificationServiceExtensionContext: AppContext {
    private let dependencies: Dependencies
    let appLaunchTime: Date = Date()
    let reportedApplicationState: UIApplication.State = .background
    
    var openSystemSettingsAction: UIAlertAction?
    var wasWokenUpByPushNotification = true
    var shouldProcessIncomingMessages: Bool { true }

    func canPresentNotifications() -> Bool { true }
    func mainApplicationStateOnLaunch() -> UIApplication.State { .inactive }
    
    // MARK: - Initialization

    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Currently Unused

    var mainWindow: UIWindow?

    static func determineDeviceRTL() -> Bool { false }
}
