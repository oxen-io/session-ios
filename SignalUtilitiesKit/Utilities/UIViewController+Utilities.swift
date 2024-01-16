import UIKit
import SessionUIKit

public final class ViewControllerUtilities {
    public static func setUpDefaultSessionStyle(for vc: UIViewController, title: String?, hasCustomBackButton: Bool) {
        // Customize title
        if let title = title {
            let titleLabel = UILabel()
            titleLabel.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
            titleLabel.text = title
            titleLabel.themeTextColor = .textPrimary
            vc.navigationItem.titleView = titleLabel
        }
        
        // Set up back button
        if hasCustomBackButton {
            let backButton = UIBarButtonItem(title: "", style: .plain, target: nil, action: nil)
            backButton.themeTintColor = .textPrimary
            vc.navigationItem.backBarButtonItem = backButton
        }
    }
}
