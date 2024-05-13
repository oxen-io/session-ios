//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//
// stringlint:disable

import Foundation
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

    lazy var buildTime: Date = {
        guard let buildTimestamp = Bundle.main.object(forInfoDictionaryKey: "BuildTimestamp") as? TimeInterval, buildTimestamp > 0 else {
            SNLog("No build timestamp; assuming app never expires.")
            return .distantFuture
        }
        return .init(timeIntervalSince1970: buildTimestamp)
    }()

    func canPresentNotifications() -> Bool { true }
    func mainApplicationStateOnLaunch() -> UIApplication.State { .inactive }

    // MARK: - Currently Unused

    var mainWindow: UIWindow?

    func frontmostViewController() -> UIViewController? { nil }
    func setNetworkActivityIndicatorVisible(_ value: Bool) { }
    func setStatusBarHidden(_ isHidden: Bool, animated isAnimated: Bool) { }
}
