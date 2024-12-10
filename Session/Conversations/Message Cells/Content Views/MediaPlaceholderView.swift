// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionMessagingKit
import SessionUIKit

final class MediaPlaceholderView: UIView {
    private static let iconSize: CGFloat = 24
    private static let iconImageViewSize: CGFloat = 40
    
    // MARK: - Lifecycle
    
    init(cellViewModel: MessageViewModel, textColor: ThemeValue) {
        super.init(frame: CGRect.zero)
        self.accessibilityIdentifier = "Untrusted attachment message"
        self.isAccessibilityElement = true
        setUpViewHierarchy(cellViewModel: cellViewModel, textColor: textColor)
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(viewItem:textColor:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(viewItem:textColor:) instead.")
    }
    
    private func setUpViewHierarchy(
        cellViewModel: MessageViewModel,
        textColor: ThemeValue
    ) {
        let (iconName, attachmentDescription): (String, String) = {
            guard
                cellViewModel.variant == .standardIncoming,
                let attachment: Attachment = cellViewModel.attachments?.first
            else {
                return (
                    "actionsheet_document_black", // stringlint:ignore
                    "file".localized().lowercased()
                ) // Should never occur
            }
            
            switch (attachment.isAudio, (attachment.isImage || attachment.isVideo)) {
                case (true, _):
                    return (
                        "attachment_audio", // stringlint:ignore
                        "audio".localized().lowercased()
                    )
                    
                case (_, true):
                    return (
                        "actionsheet_camera_roll_black", // stringlint:ignore
                        "media".localized().lowercased()
                    )
                    
                default:
                    return (
                        "actionsheet_document_black", // stringlint:ignore
                        "file".localized().lowercased()
                    )
            }
        }()
        
        // Image view
        let imageContainerView: UIView = UIView()
        imageContainerView.set(.width, to: MediaPlaceholderView.iconImageViewSize)
        imageContainerView.set(.height, to: MediaPlaceholderView.iconImageViewSize)
        
        let imageView = UIImageView(image: UIImage(named: iconName)?.withRenderingMode(.alwaysTemplate))
        imageView.themeTintColor = textColor
        imageView.contentMode = .scaleAspectFit
        imageView.set(.width, to: MediaPlaceholderView.iconSize)
        imageView.set(.height, to: MediaPlaceholderView.iconSize)
        imageContainerView.addSubview(imageView)
        imageView.center(in: imageContainerView)
        
        // Body label
        let titleLabel = UILabel()
        titleLabel.font = .systemFont(ofSize: Values.mediumFontSize)
        titleLabel.text = "attachmentsTapToDownload"
            .put(key: "file_type", value: attachmentDescription)
            .localized()
        titleLabel.themeTextColor = textColor
        titleLabel.lineBreakMode = .byTruncatingTail
        
        // Stack view
        let stackView = UIStackView(arrangedSubviews: [ imageContainerView, titleLabel ])
        stackView.axis = .horizontal
        stackView.alignment = .center
        addSubview(stackView)
        stackView.pin(.top, to: .top, of: self, withInset: Values.smallSpacing)
        stackView.pin(.leading, to: .leading, of: self, withInset: Values.smallSpacing)
        stackView.pin(.trailing, to: .trailing, of: self, withInset: -Values.largeSpacing)
        stackView.pin(.bottom, to: .bottom, of: self, withInset: -Values.smallSpacing)
    }
}
