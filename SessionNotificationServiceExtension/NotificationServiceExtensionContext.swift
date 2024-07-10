//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//
// stringlint:disable

import UIKit
import SignalUtilitiesKit
import SessionUtilitiesKit

final class NotificationServiceExtensionContext: AppContext {
    var _temporaryDirectory: String?
    
    let appLaunchTime: Date = Date()
    let reportedApplicationState: UIApplication.State = .background
    let isRTL: Bool = false
    
    var openSystemSettingsAction: UIAlertAction?
    var wasWokenUpByPushNotification = true
    var shouldProcessIncomingMessages: Bool { true }

    func canPresentNotifications() -> Bool { true }
    func mainApplicationStateOnLaunch() -> UIApplication.State { .inactive }

    // MARK: - Currently Unused

    var mainWindow: UIWindow?

    func frontmostViewController() -> UIViewController? { nil }
    func setNetworkActivityIndicatorVisible(_ value: Bool) { }
    func setStatusBarHidden(_ isHidden: Bool, animated isAnimated: Bool) { }
}
