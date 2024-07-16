// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

protocol ApprovalRailCellViewDelegate: AnyObject {
    func approvalRailCellView(_ approvalRailCellView: ApprovalRailCellView, didRemoveItem attachmentItem: SignalAttachmentItem)
    func canRemoveApprovalRailCellView(_ approvalRailCellView: ApprovalRailCellView) -> Bool
}

// MARK: -

public class ApprovalRailCellView: GalleryRailCellView {

    weak var approvalRailCellDelegate: ApprovalRailCellViewDelegate?

    lazy var deleteButton: UIButton = {
        let button = OWSButton { [weak self] in
            guard let strongSelf = self else { return }

            guard let attachmentItem = strongSelf.item as? SignalAttachmentItem else {
                Log.error("[ApprovalRailCellView] attachmentItem was unexpectedly nil")
                return
            }

            strongSelf.approvalRailCellDelegate?.approvalRailCellView(strongSelf, didRemoveItem: attachmentItem)
        }

        button.setImage(UIImage(named: "x-24")?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.themeTintColor = .white
        button.themeShadowColor = .black
        button.layer.shadowRadius = 2
        button.layer.shadowOpacity = 0.66
        button.layer.shadowOffset = .zero
        button.set(.width, to: 24)
        button.set(.height, to: 24)

        return button
    }()

    lazy var captionIndicator: UIView = {
        let image = UIImage(named: "image_editor_caption")?.withRenderingMode(.alwaysTemplate)
        let imageView = UIImageView(image: image)
        imageView.themeTintColor = .white
        imageView.themeShadowColor = .black
        imageView.layer.shadowRadius = 2
        imageView.layer.shadowOpacity = 0.66
        imageView.layer.shadowOffset = .zero
        
        return imageView
    }()

    override func setIsSelected(_ isSelected: Bool) {
        super.setIsSelected(isSelected)

        if isSelected {
            if let approvalRailCellDelegate = self.approvalRailCellDelegate,
                approvalRailCellDelegate.canRemoveApprovalRailCellView(self) {

                addSubview(deleteButton)
                deleteButton.pin(.top, to: .top, of: self, withInset: cellBorderWidth)
                deleteButton.pin(.trailing, to: .trailing, of: self, withInset: -(cellBorderWidth + 4))
            }
        } else {
            deleteButton.removeFromSuperview()
        }
    }

    override func configure(item: GalleryRailItem, delegate: GalleryRailCellViewDelegate, using dependencies: Dependencies) {
        super.configure(item: item, delegate: delegate, using: dependencies)

        var hasCaption = false
        if let attachmentItem = item as? SignalAttachmentItem {
            if let captionText = attachmentItem.captionText {
                hasCaption = captionText.count > 0
            }
        } else {
            Log.error("[ApprovalRailCellView] Invalid item")
        }

        if hasCaption {
            addSubview(captionIndicator)

            captionIndicator.pin(.top, to: .top, of: self, withInset: cellBorderWidth)
            captionIndicator.pin(.leading, to: .leading, of: self, withInset: cellBorderWidth + 4)
        } else {
            captionIndicator.removeFromSuperview()
        }
    }
}
