// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit
import UIKit
import SignalCoreKit

public extension UIApplication {

    var frontmostViewControllerIgnoringAlerts: UIViewController? {
        return findFrontmostViewController(ignoringAlerts: true)
    }

    var frontmostViewController: UIViewController? {
        return findFrontmostViewController(ignoringAlerts: false)
    }

    internal func findFrontmostViewController(
        ignoringAlerts: Bool,
        using dependencies: Dependencies = Dependencies()
    ) -> UIViewController? {
        guard
            dependencies.hasInitialised(singleton: .appContext),
            let window: UIWindow = dependencies[singleton: .appContext].mainWindow
        else { return nil }
        
        guard let viewController: UIViewController = window.rootViewController else {
            owsFailDebug("Missing root view controller.")
            return nil
        }
        return viewController.findFrontmostViewController(ignoringAlerts: ignoringAlerts)
    }

    func openSystemSettings() {
        open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
    }
}
