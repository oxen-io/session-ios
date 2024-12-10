// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SignalUtilitiesKit
import SessionUtilitiesKit
import SessionMessagingKit
import SessionUIKit

final class UnreadMarkerCell: MessageCell {
    public static let height: CGFloat = 32
    
    // MARK: - UI
    
    private let leftLine: UIView = {
        let result: UIView = UIView()
        result.themeBackgroundColor = .unreadMarker
        result.set(.height, to: 1)  // Intentionally 1 instead of 'separatorThickness'
        
        return result
    }()
    
    private lazy var titleLabel: UILabel = {
        let result = UILabel()
        result.font = .boldSystemFont(ofSize: Values.verySmallFontSize)
        result.text = "messageUnread".localized()
        result.themeTextColor = .unreadMarker
        result.textAlignment = .center
        
        return result
    }()
    
    private let rightLine: UIView = {
        let result: UIView = UIView()
        result.themeBackgroundColor = .unreadMarker
        result.set(.height, to: 1)  // Intentionally 1 instead of 'separatorThickness'
        
        return result
    }()
    
    // MARK: - Initialization
    
    override func setUpViewHierarchy() {
        super.setUpViewHierarchy()
        
        addSubview(leftLine)
        addSubview(titleLabel)
        addSubview(rightLine)
        
        leftLine.pin(.leading, to: .leading, of: self, withInset: Values.mediumSpacing)
        leftLine.pin(.trailing, to: .leading, of: titleLabel, withInset: -Values.smallSpacing)
        leftLine.center(.vertical, in: self)
        titleLabel.center(.horizontal, in: self)
        titleLabel.center(.vertical, in: self)
        titleLabel.pin(.top, to: .top, of: self, withInset: Values.smallSpacing)
        titleLabel.pin(.bottom, to: .bottom, of: self, withInset: -Values.smallSpacing)
        rightLine.pin(.leading, to: .trailing, of: titleLabel, withInset: Values.smallSpacing)
        rightLine.pin(.trailing, to: .trailing, of: self, withInset: -Values.mediumSpacing)
        rightLine.center(.vertical, in: self)
    }
    
    // MARK: - Updating
    
    override func update(
        with cellViewModel: MessageViewModel,
        mediaCache: NSCache<NSString, AnyObject>,
        playbackInfo: ConversationViewModel.PlaybackInfo?,
        showExpandedReactions: Bool,
        lastSearchText: String?,
        using dependencies: Dependencies
    ) {
        guard cellViewModel.cellType == .unreadMarker else { return }
    }
    
    override func dynamicUpdate(with cellViewModel: MessageViewModel, playbackInfo: ConversationViewModel.PlaybackInfo?) {}
}
