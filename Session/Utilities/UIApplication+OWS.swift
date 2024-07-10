// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUtilitiesKit

@objc public extension UIApplication {

    var frontmostViewControllerIgnoringAlerts: UIViewController? {
        return findFrontmostViewController(ignoringAlerts: true)
    }

    var frontmostViewController: UIViewController? {
        return findFrontmostViewController(ignoringAlerts: false)
    }

    internal func findFrontmostViewController(ignoringAlerts: Bool) -> UIViewController? {
        guard
            Singleton.hasAppContext,
            let window: UIWindow = Singleton.appContext.mainWindow
        else { return nil }
        
        guard let viewController: UIViewController = window.rootViewController else {
            Log.error("[UIApplication] Missing root view controller.")
            return nil
        }
        return viewController.findFrontmostViewController(ignoringAlerts: ignoringAlerts)
    }

    func openSystemSettings() {
        open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
    }
}
