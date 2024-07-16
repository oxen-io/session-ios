//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//
// stringlint:disable

import UIKit
import SignalUtilitiesKit
import SessionUtilitiesKit

final class NotificationServiceExtensionContext: AppContext {
    private let dependencies: Dependencies
    var _temporaryDirectory: String?
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
        self.createTemporaryDirectory()
    }

    // MARK: - Currently Unused

    var mainWindow: UIWindow?

    static func determineDeviceRTL() -> Bool { false }
    
    // MARK: - Temporary Directories
    
    var temporaryDirectory: String { temporaryDirectory(using: dependencies) }
    var temporaryDirectoryAccessibleAfterFirstAuth: String {
        temporaryDirectoryAccessibleAfterFirstAuth(using: dependencies)
    }
}
