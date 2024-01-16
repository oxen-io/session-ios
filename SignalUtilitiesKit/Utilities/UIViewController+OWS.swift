// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

public extension UIViewController {
    func findFrontmostViewController(ignoringAlerts: Bool) -> UIViewController {
        var visitedViewControllers: [UIViewController] = []
        
        var viewController: UIViewController = self
        
        while true {
            visitedViewControllers.append(viewController)
            
            var nextViewController: UIViewController? = viewController.presentedViewController
            
            if
                let topBannerController: TopBannerController = nextViewController as? TopBannerController,
                !topBannerController.children.isEmpty
            {
                nextViewController = (
                    topBannerController.children[0].presentedViewController ??
                    topBannerController.children[0]
                )
            }
            
            if let nextViewController: UIViewController = nextViewController {
                if !ignoringAlerts || !(nextViewController is UIAlertController) {
                    if visitedViewControllers.contains(nextViewController) {
                        // Cycle detected
                        return viewController
                    }
                    
                    viewController = nextViewController
                    continue
                }
            }
            
            if let navController: UINavigationController = viewController as? UINavigationController {
                nextViewController = navController.topViewController
                
                if let nextViewController: UIViewController = nextViewController {
                    if !ignoringAlerts || !(nextViewController is UIAlertController) {
                        if visitedViewControllers.contains(nextViewController) {
                            // Cycle detected
                            return viewController
                        }
                        
                        viewController = nextViewController
                        continue
                    }
                }
                
                break
            }
            
            break
        }
        
        return viewController
    }
    
    static func createOWSBackButton(target: Any?, selector: Selector, using dependencies: Dependencies = Dependencies()) -> UIBarButtonItem {
        let backButton: UIButton = UIButton(type: .custom)

        // Nudge closer to the left edge to match default back button item.
        let extraLeftPadding: CGFloat = (Dependencies.isRTL ? 0 : -8)

        // Give some extra hit area to the back button. This is a little smaller
        // than the default back button, but makes sense for our left aligned title
        // view in the MessagesViewController
        let extraRightPadding: CGFloat = (Dependencies.isRTL ? -0 : 10)

        // Extra hit area above/below
        let extraHeightPadding: CGFloat = 8

        // Matching the default backbutton placement is tricky.
        // We can't just adjust the imageEdgeInsets on a UIBarButtonItem directly,
        // so we adjust the imageEdgeInsets on a UIButton, then wrap that
        // in a UIBarButtonItem.
        backButton.addTarget(target, action: selector, for: .touchUpInside)
        
        let config: UIImage.Configuration = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        backButton.setImage(
            UIImage(systemName: "chevron.backward", withConfiguration: config)?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        backButton.themeTintColor = .textPrimary
        backButton.contentHorizontalAlignment = .left
        backButton.imageEdgeInsets = (Dependencies.isRTL ?
            UIEdgeInsets(top: 0, left: 0, bottom: 0, right: extraLeftPadding) :
            UIEdgeInsets(top: 0, left: extraLeftPadding, bottom: 0, right: 0)
        )
        backButton.frame = CGRect(
            x: 0,
            y: 0,
            width: ((backButton.image(for: .normal)?.size.width ?? 0) + extraRightPadding),
            height: ((backButton.image(for: .normal)?.size.height ?? 0) + extraHeightPadding)
        )

        let backItem: UIBarButtonItem = UIBarButtonItem(customView: backButton)
        backButton.accessibilityIdentifier = "\(type(of: self)).back"
        backButton.accessibilityLabel = "\(type(of: self)).back"
        backItem.isAccessibilityElement = true
        backItem.width = backButton.frame.width

        return backItem;
    }
    
    // MARK: - Event Handling

    @objc func backButtonPressed() {
        self.navigationController?.popViewController(animated: true)
    }
}
