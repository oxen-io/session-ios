// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

final class ConversationTitleView: UIView {
    private static let leftInset: CGFloat = 8
    private static let leftInsetWithCallButton: CGFloat = 54
    
    private let dependencies: Dependencies
    private var oldSize: CGSize = .zero
    
    override var intrinsicContentSize: CGSize {
        return UIView.layoutFittingExpandedSize
    }
    
    private lazy var labelCarouselViewWidth = labelCarouselView.set(.width, to: 185)
    
    public var currentLabelType: SessionLabelCarouselView.LabelType? {
        return self.labelCarouselView.currentLabelType
    }

    // MARK: - UI Components
    
    private lazy var stackViewLeadingConstraint: NSLayoutConstraint = stackView.pin(.leading, to: .leading, of: self)
    private lazy var stackViewTrailingConstraint: NSLayoutConstraint = stackView.pin(.trailing, to: .trailing, of: self)
    
    private lazy var titleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.accessibilityIdentifier = "Conversation header name"
        result.accessibilityLabel = "Conversation header name"
        result.isAccessibilityElement = true
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byTruncatingTail
        
        return result
    }()
    
    private lazy var labelCarouselView: SessionLabelCarouselView = {
        let result = SessionLabelCarouselView(using: dependencies)
        return result
    }()
    
    private lazy var stackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ titleLabel, labelCarouselView ])
        result.axis = .vertical
        result.alignment = .center
        
        return result
    }()

    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init(frame: .zero)
        
        addSubview(stackView)
        
        stackView.pin(.top, to: .top, of: self)
        stackViewLeadingConstraint.isActive = true
        stackViewTrailingConstraint.isActive = true
        stackView.pin(.bottom, to: .bottom, of: self)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init() instead.")
    }

    // MARK: - Content
    
    public func initialSetup(
        with threadVariant: SessionThread.Variant,
        isNoteToSelf: Bool,
        isMessageRequest: Bool
    ) {
        self.update(
            with: " ",
            isNoteToSelf: isNoteToSelf,
            isMessageRequest: isMessageRequest,
            threadVariant: threadVariant,
            mutedUntilTimestamp: nil,
            onlyNotifyForMentions: false,
            userCount: (threadVariant != .contact ? 0 : nil),
            disappearingMessagesConfig: nil
        )
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        // There is an annoying issue where pushing seems to update the width of this
        // view resulting in the content shifting to the right during
        guard self.oldSize != .zero, self.oldSize != bounds.size else {
            self.oldSize = bounds.size
            return
        }
        
        let diff: CGFloat = (bounds.size.width - oldSize.width)
        self.stackViewTrailingConstraint.constant = -max(0, diff)
        self.oldSize = bounds.size
    }
    
    public func update(
        with name: String,
        isNoteToSelf: Bool,
        isMessageRequest: Bool,
        threadVariant: SessionThread.Variant,
        mutedUntilTimestamp: TimeInterval?,
        onlyNotifyForMentions: Bool,
        userCount: Int?,
        disappearingMessagesConfig: DisappearingMessagesConfiguration?
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.update(
                    with: name,
                    isNoteToSelf: isNoteToSelf,
                    isMessageRequest: isMessageRequest,
                    threadVariant: threadVariant,
                    mutedUntilTimestamp: mutedUntilTimestamp,
                    onlyNotifyForMentions: onlyNotifyForMentions,
                    userCount: userCount,
                    disappearingMessagesConfig: disappearingMessagesConfig
                )
            }
            return
        }
        
        let shouldHaveSubtitle: Bool = (
            !isMessageRequest && (
                Date().timeIntervalSince1970 <= (mutedUntilTimestamp ?? 0) ||
                onlyNotifyForMentions ||
                userCount != nil ||
                disappearingMessagesConfig?.isEnabled == true
            )
        )
        
        self.titleLabel.text = name
        self.titleLabel.accessibilityLabel = name
        self.titleLabel.font = .boldSystemFont(
            ofSize: (shouldHaveSubtitle ?
                Values.largeFontSize :
                Values.veryLargeFontSize
            )
        )
        self.labelCarouselView.isHidden = !shouldHaveSubtitle
        
        // Contact threads also have the call button to compensate for
        let shouldShowCallButton: Bool = (
            SessionCall.isEnabled &&
            !isNoteToSelf &&
            threadVariant == .contact
        )
        self.stackViewLeadingConstraint.constant = (shouldShowCallButton ?
            ConversationTitleView.leftInsetWithCallButton :
            ConversationTitleView.leftInset
        )
        self.stackViewTrailingConstraint.constant = 0
        
        // No need to add themed subtitle content if we aren't adding the subtitle carousel
        guard shouldHaveSubtitle else { return }
        
        ThemeManager.onThemeChange(observer: self.labelCarouselView) { [weak self] theme, _ in
            guard let textPrimary: UIColor = theme.color(for: .textPrimary) else { return }
            
            var labelInfos: [SessionLabelCarouselView.LabelInfo] = []
            
            if Date().timeIntervalSince1970 <= (mutedUntilTimestamp ?? 0) {
                let notificationSettingsLabelString = NSAttributedString(
                    string: FullConversationCell.mutePrefix,
                    attributes: [
                        .font: UIFont(name: "ElegantIcons", size: 8) as Any,
                        .foregroundColor: textPrimary
                    ]
                )
                .appending(string: "notificationsMuted".localized())
                
                labelInfos.append(
                    SessionLabelCarouselView.LabelInfo(
                        attributedText: notificationSettingsLabelString,
                        accessibility: nil, // TODO: Add accessibility
                        type: .notificationSettings
                    )
                )
            }
            else if onlyNotifyForMentions {
                let imageAttachment = NSTextAttachment()
                imageAttachment.image = UIImage(named: "NotifyMentions.png")?.withTint(textPrimary)
                imageAttachment.bounds = CGRect(
                    x: 0,
                    y: -2,
                    width: Values.miniFontSize,
                    height: Values.miniFontSize
                )
                
                let notificationSettingsLabelString = NSAttributedString(attachment: imageAttachment)
                    .appending(string: "  ")
                    .appending(string: "notificationsMentionsOnly".localized())
                
                labelInfos.append(
                    SessionLabelCarouselView.LabelInfo(
                        attributedText: notificationSettingsLabelString,
                        accessibility: nil, // TODO: Add accessibility
                        type: .notificationSettings
                    )
                )
            }
            
            if let userCount: Int = userCount {
                switch threadVariant {
                    case .contact: break
                        
                    case .legacyGroup, .group:
                        labelInfos.append(
                            SessionLabelCarouselView.LabelInfo(
                                attributedText: "members"
                                    .putNumber(userCount)
                                    .localizedFormatted(baseFont: .systemFont(ofSize: Values.miniFontSize)),
                                accessibility: nil, // TODO: Add accessibility
                                type: .userCount
                            )
                        )
                        
                    case .community:
                        labelInfos.append(
                            SessionLabelCarouselView.LabelInfo(
                                attributedText: "membersActive"
                                    .putNumber(userCount)
                                    .localizedFormatted(baseFont: .systemFont(ofSize: Values.miniFontSize)),
                                accessibility: nil, // TODO: Add accessibility
                                type: .userCount
                            )
                        )
                }
            }
            
            if let config = disappearingMessagesConfig, config.isEnabled == true {
                let imageAttachment = NSTextAttachment()
                imageAttachment.image = UIImage(systemName: "timer")?.withTint(textPrimary)
                imageAttachment.bounds = CGRect(
                    x: 0,
                    y: -2,
                    width: Values.miniFontSize,
                    height: Values.miniFontSize
                )
                
                labelInfos.append(
                    SessionLabelCarouselView.LabelInfo(
                        attributedText: NSAttributedString(attachment: imageAttachment)
                            .appending(string: " ")
                            .appending(
                                string: (config.type ?? .unknown)
                                    .localizedState(
                                        durationString: floor(config.durationSeconds).formatted(format: .short)
                                    )
                            ),
                        accessibility: Accessibility(
                            identifier: "Disappearing messages type and time",
                            label: "Disappearing messages type and time"
                        ),
                        type: .disappearingMessageSetting
                    )
                )
            }
            
            self?.labelCarouselView.update(
                with: labelInfos,
                labelSize: CGSize(
                    width: self?.labelCarouselViewWidth.constant ?? 0,
                    height: 12
                ),
                shouldAutoScroll: false
            )
            
            self?.labelCarouselView.isHidden = (labelInfos.count == 0)
        }
    }
    
    // MARK: - Interaction
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.stackView.frame.contains(point) {
            return self.labelCarouselView.scrollView
        }
        return super.hitTest(point, with: event)
    }
}
