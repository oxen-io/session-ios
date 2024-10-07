// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SignalUtilitiesKit
import SessionUtilitiesKit

public extension UIApplication {
    func frontMostViewController(
        ignoringAlerts: Bool = false,
        using dependencies: Dependencies
    ) -> UIViewController? {
        guard let window: UIWindow = dependencies[singleton: .appContext].mainWindow else { return nil }
        
        guard let viewController: UIViewController = window.rootViewController else {
            Log.error("[UIApplication] Missing root view controller.")
            return nil
        }
        return viewController.findFrontMostViewController(ignoringAlerts: ignoringAlerts)
    }

    func openSystemSettings() {
        open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
    }
}
