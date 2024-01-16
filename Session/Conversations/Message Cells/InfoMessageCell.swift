// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

final class InfoMessageCell: MessageCell {
    private static let iconSize: CGFloat = 12
    public static let inset = Values.mediumSpacing
    
    private var isHandlingLongPress: Bool = false
    
    override var contextSnapshotView: UIView? { return label }
    
    // MARK: - UI
    
    private lazy var iconContainerViewWidthConstraint = iconContainerView.set(.width, to: InfoMessageCell.iconSize)
    private lazy var iconContainerViewHeightConstraint = iconContainerView.set(.height, to: InfoMessageCell.iconSize)
    
    private lazy var iconImageView: UIImageView = UIImageView()
    private lazy var timerView: DisappearingMessageTimerView = DisappearingMessageTimerView()
    
    private lazy var iconContainerView: UIView = {
        let result: UIView = UIView()
        result.addSubview(iconImageView)
        result.addSubview(timerView)
        iconImageView.pin(to: result)
        timerView.pin(to: result)
        
        return result
    }()

    private lazy var label: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.verySmallFontSize)
        result.themeTextColor = .textSecondary
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        
        return result
    }()

    private lazy var stackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [ iconContainerView, label ])
        result.axis = .vertical
        result.alignment = .center
        result.spacing = Values.smallSpacing
        
        return result
    }()

    // MARK: - Lifecycle
    
    override func setUpViewHierarchy() {
        super.setUpViewHierarchy()
        
        iconContainerViewWidthConstraint.isActive = true
        iconContainerViewHeightConstraint.isActive = true
        addSubview(stackView)
        
        stackView.pin(.left, to: .left, of: self, withInset: Values.massiveSpacing)
        stackView.pin(.top, to: .top, of: self, withInset: InfoMessageCell.inset)
        stackView.pin(.right, to: .right, of: self, withInset: -Values.massiveSpacing)
        stackView.pin(.bottom, to: .bottom, of: self, withInset: -InfoMessageCell.inset)
    }
    
    override func setUpGestureRecognizers() {
        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        addGestureRecognizer(longPressRecognizer)
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
        guard cellViewModel.variant.isInfoMessage else { return }
        
        self.accessibilityIdentifier = "Control message"
        self.isAccessibilityElement = true
        self.viewModel = cellViewModel
        
        let icon: UIImage? = {
            switch cellViewModel.variant {
                case .infoDisappearingMessagesUpdate:
                    return UIImage(systemName: "timer")
                    
                case .infoMediaSavedNotification: return UIImage(named: "ic_download")
                    
                default: return nil
            }
        }()
        
        if let icon = icon {
            iconImageView.image = icon.withRenderingMode(.alwaysTemplate)
            iconImageView.themeTintColor = .textSecondary
        }
        
        switch cellViewModel.attributedBody(using: dependencies) {
            case .some(let attrText): self.label.attributedText = attrText
            case .none: self.label.text = cellViewModel.body
        }
        
        self.label.themeTextColor = (cellViewModel.variant == .infoGroupCurrentUserErrorLeaving ?
            .danger :
            .textSecondary
        )
        
        let shouldShowIcon: Bool = (icon != nil) || ((cellViewModel.expiresInSeconds ?? 0) > 0)
        
        iconContainerViewWidthConstraint.constant = (shouldShowIcon ? InfoMessageCell.iconSize : 0)
        iconContainerViewHeightConstraint.constant = (shouldShowIcon ? InfoMessageCell.iconSize : 0)
        
        guard shouldShowIcon else { return }
        
        // Timer
        if
            let expiresStartedAtMs: Double = cellViewModel.expiresStartedAtMs,
            let expiresInSeconds: TimeInterval = cellViewModel.expiresInSeconds
        {
            let expirationTimestampMs: Double = (expiresStartedAtMs + (expiresInSeconds * 1000))
            
            timerView.configure(
                expirationTimestampMs: expirationTimestampMs,
                initialDurationSeconds: expiresInSeconds
            )
            timerView.themeTintColor = .textSecondary
            timerView.isHidden = false
            iconImageView.isHidden = true
        }
        else {
            timerView.isHidden = true
            iconImageView.isHidden = false
        }
    }
    
    override func dynamicUpdate(with cellViewModel: MessageViewModel, playbackInfo: ConversationViewModel.PlaybackInfo?) {
    }
    
    // MARK: - Interaction
    
    @objc func handleLongPress(_ gestureRecognizer: UITapGestureRecognizer) {
        if [ .ended, .cancelled, .failed ].contains(gestureRecognizer.state) {
            isHandlingLongPress = false
            return
        }
        guard !isHandlingLongPress, let cellViewModel: MessageViewModel = self.viewModel else { return }
        
        delegate?.handleItemLongPressed(cellViewModel)
        isHandlingLongPress = true
    }
}
