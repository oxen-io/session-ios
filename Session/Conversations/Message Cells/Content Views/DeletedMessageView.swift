// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

final class DeletedMessageView: UIView {
    private static let iconSize: CGFloat = 18
    private static let iconImageViewSize: CGFloat = 30
    
    // MARK: - Lifecycle
    
    init(textColor: ThemeValue, variant: Interaction.Variant) {
        super.init(frame: CGRect.zero)
        accessibilityIdentifier = "Deleted message"
        isAccessibilityElement = true
        setUpViewHierarchy(textColor: textColor, variant: variant)
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(textColor:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(textColor:) instead.")
    }
    
    private func setUpViewHierarchy(textColor: ThemeValue, variant: Interaction.Variant) {
        // Image view
        let imageContainerView: UIView = UIView()
        imageContainerView.set(.width, to: DeletedMessageView.iconImageViewSize)
        imageContainerView.set(.height, to: DeletedMessageView.iconImageViewSize)
        
        let imageView = UIImageView(image: UIImage(named: "ic_trash")?.withRenderingMode(.alwaysTemplate))
        imageView.themeTintColor = textColor
        imageView.contentMode = .scaleAspectFit
        imageView.set(.width, to: DeletedMessageView.iconSize)
        imageView.set(.height, to: DeletedMessageView.iconSize)
        imageContainerView.addSubview(imageView)
        imageView.center(in: imageContainerView)
        
        // Body label
        let titleLabel = UILabel()
        titleLabel.font = .systemFont(ofSize: Values.smallFontSize)
        titleLabel.text = {
            switch variant {
                case .standardIncomingDeletedLocally, .standardOutgoingDeletedLocally:
                    return "deleteMessageDeletedLocally".localized()
                
                default: return "deleteMessageDeletedGlobally".localized()
            }
        }()
        titleLabel.themeTextColor = textColor
        titleLabel.lineBreakMode = .byTruncatingTail
        
        // Stack view
        let stackView = UIStackView(arrangedSubviews: [ imageContainerView, titleLabel ])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.layoutMargins = UIEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 6)
        addSubview(stackView)
        
        stackView.pin(to: self, withInset: Values.smallSpacing)
        stackView.set(.height, to: .height, of: imageView)
    }
}
