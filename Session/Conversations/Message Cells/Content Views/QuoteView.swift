// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

final class QuoteView: UIView {
    static let thumbnailSize: CGFloat = 48
    static let iconSize: CGFloat = 24
    static let labelStackViewSpacing: CGFloat = 2
    static let labelStackViewVMargin: CGFloat = 4
    static let cancelButtonSize: CGFloat = 33
    
    enum Mode {
        case regular
        case draft
    }
    enum Direction { case incoming, outgoing }
    
    // MARK: - Variables
    
    private let dependencies: Dependencies
    private let onCancel: (() -> ())?

    // MARK: - Lifecycle
    
    init(
        for mode: Mode,
        authorId: String,
        quotedText: String?,
        threadVariant: SessionThread.Variant,
        currentUserSessionId: String?,
        currentUserBlinded15SessionId: String?,
        currentUserBlinded25SessionId: String?,
        direction: Direction,
        attachment: Attachment?,
        using dependencies: Dependencies,
        onCancel: (() -> ())? = nil
    ) {
        self.dependencies = dependencies
        self.onCancel = onCancel
        
        super.init(frame: CGRect.zero)
        
        setUpViewHierarchy(
            mode: mode,
            authorId: authorId,
            quotedText: quotedText,
            threadVariant: threadVariant,
            currentUserSessionId: currentUserSessionId,
            currentUserBlinded15SessionId: currentUserBlinded15SessionId,
            currentUserBlinded25SessionId: currentUserBlinded25SessionId,
            direction: direction,
            attachment: attachment
        )
    }

    override init(frame: CGRect) {
        preconditionFailure("Use init(for:maxMessageWidth:) instead.")
    }

    required init?(coder: NSCoder) {
        preconditionFailure("Use init(for:maxMessageWidth:) instead.")
    }

    private func setUpViewHierarchy(
        mode: Mode,
        authorId: String,
        quotedText: String?,
        threadVariant: SessionThread.Variant,
        currentUserSessionId: String?,
        currentUserBlinded15SessionId: String?,
        currentUserBlinded25SessionId: String?,
        direction: Direction,
        attachment: Attachment?
    ) {
        // There's quite a bit of calculation going on here. It's a bit complex so don't make changes
        // if you don't need to. If you do then test:
        // • Quoted text in both private chats and group chats
        // • Quoted images and videos in both private chats and group chats
        // • Quoted voice messages and documents in both private chats and group chats
        // • All of the above in both dark mode and light mode
        let thumbnailSize = QuoteView.thumbnailSize
        let iconSize = QuoteView.iconSize
        let labelStackViewSpacing = QuoteView.labelStackViewSpacing
        let labelStackViewVMargin = QuoteView.labelStackViewVMargin
        let smallSpacing = Values.smallSpacing
        let cancelButtonSize = QuoteView.cancelButtonSize
        var body: String? = quotedText
        
        // Main stack view
        let mainStackView = UIStackView(arrangedSubviews: [])
        mainStackView.axis = .horizontal
        mainStackView.spacing = smallSpacing
        mainStackView.isLayoutMarginsRelativeArrangement = true
        mainStackView.layoutMargins = UIEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: smallSpacing)
        mainStackView.alignment = .center
        
        // Content view
        let contentView = UIView()
        addSubview(contentView)
        contentView.pin(to: self)
        
        if let attachment: Attachment = attachment {
            let isAudio: Bool = attachment.isAudio
            let fallbackImageName: String = (isAudio ? "attachment_audio" : "actionsheet_document_black") // stringlint:ignore
            let imageContainerView: UIView = UIView()
            imageContainerView.themeBackgroundColor = .messageBubble_overlay
            imageContainerView.layer.cornerRadius = VisibleMessageCell.smallCornerRadius
            imageContainerView.layer.masksToBounds = true
            imageContainerView.set(.width, to: thumbnailSize)
            imageContainerView.set(.height, to: thumbnailSize)
            mainStackView.addArrangedSubview(imageContainerView)
            
            let imageView: UIImageView = UIImageView(
                image: UIImage(named: fallbackImageName)?.withRenderingMode(.alwaysTemplate)
            )
            imageView.themeTintColor = {
                switch mode {
                    case .regular: return (direction == .outgoing ?
                        .messageBubble_outgoingText :
                        .messageBubble_incomingText
                    )
                    case .draft: return .textPrimary
                }
            }()
            imageView.contentMode = .scaleAspectFit
            imageView.set(.width, to: iconSize)
            imageView.set(.height, to: iconSize)
            imageContainerView.addSubview(imageView)
            imageView.center(in: imageContainerView)
            
            if (body ?? "").isEmpty {
                body = attachment.shortDescription
            }
            
            // Generate the thumbnail if needed
            if attachment.isVisualMedia {
                attachment.thumbnail(
                    size: .small,
                    using: dependencies,
                    success: { [imageView] image, _ in
                        guard Thread.isMainThread else {
                            DispatchQueue.main.async {
                                imageView.image = image
                                imageView.contentMode = .scaleAspectFill
                            }
                            return
                        }
                        
                        imageView.image = image
                        imageView.contentMode = .scaleAspectFill
                    },
                    failure: {}
                )
            }
        }
        else {
            // Line view
            let lineColor: ThemeValue = {
                switch mode {
                    case .regular: return (direction == .outgoing ? .messageBubble_outgoingText : .primary)
                    case .draft: return .primary
                }
            }()
            let lineView = UIView()
            lineView.themeBackgroundColor = lineColor
            mainStackView.addArrangedSubview(lineView)
            
            lineView.pin(.top, to: .top, of: mainStackView)
            lineView.pin(.bottom, to: .bottom, of: mainStackView)
            lineView.set(.width, to: Values.accentLineThickness)
        }
        
        // Body label
        let bodyLabel = TappableLabel()
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.numberOfLines = 2
        
        let targetThemeColor: ThemeValue = {
            switch mode {
                case .regular: return (direction == .outgoing ?
                    .messageBubble_outgoingText :
                    .messageBubble_incomingText
                )
                case .draft: return .textPrimary
            }
        }()
        bodyLabel.font = .systemFont(ofSize: Values.smallFontSize)
        
        ThemeManager.onThemeChange(observer: bodyLabel) { [weak bodyLabel, dependencies] theme, primaryColor in
            guard let textColor: UIColor = theme.color(for: targetThemeColor) else { return }
            
            bodyLabel?.attributedText = body
                .map {
                    MentionUtilities.highlightMentions(
                        in: $0,
                        threadVariant: threadVariant,
                        currentUserSessionId: currentUserSessionId,
                        currentUserBlinded15SessionId: currentUserBlinded15SessionId,
                        currentUserBlinded25SessionId: currentUserBlinded25SessionId,
                        location: {
                            switch (mode, direction) {
                                case (.draft, _): return .quoteDraft
                                case (_, .outgoing): return .outgoingQuote
                                case (_, .incoming): return .incomingQuote
                            }
                        }(),
                        textColor: textColor,
                        theme: theme,
                        primaryColor: primaryColor,
                        attributes: [
                            .foregroundColor: textColor
                        ],
                        using: dependencies
                    )
                }
                .defaulting(
                    to: attachment.map {
                        NSAttributedString(string: $0.shortDescription, attributes: [ .foregroundColor: textColor ])
                    }
                )
                .defaulting(to: NSAttributedString(string: "messageErrorOriginal".localized(), attributes: [ .foregroundColor: textColor ]))
        }
        
        // Label stack view
        let isCurrentUser: Bool = [
            currentUserSessionId,
            currentUserBlinded15SessionId,
            currentUserBlinded25SessionId
        ]
        .compactMap { $0 }
        .asSet()
        .contains(authorId)
        
        let authorLabel = UILabel()
        authorLabel.font = .boldSystemFont(ofSize: Values.smallFontSize)
        authorLabel.text = {
            guard !isCurrentUser else { return "you".localized() }
            guard body != nil else {
                // When we can't find the quoted message we want to hide the author label
                return Profile.displayNameNoFallback(
                    id: authorId,
                    threadVariant: threadVariant,
                    using: dependencies
                )
            }
            
            return Profile.displayName(
                id: authorId,
                threadVariant: threadVariant,
                using: dependencies
            )
        }()
        authorLabel.themeTextColor = targetThemeColor
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.isHidden = (authorLabel.text == nil)
        authorLabel.numberOfLines = 1
        
        let labelStackView = UIStackView(arrangedSubviews: [ authorLabel, bodyLabel ])
        labelStackView.axis = .vertical
        labelStackView.spacing = labelStackViewSpacing
        labelStackView.distribution = .equalCentering
        labelStackView.isLayoutMarginsRelativeArrangement = true
        labelStackView.layoutMargins = UIEdgeInsets(top: labelStackViewVMargin, left: 0, bottom: labelStackViewVMargin, right: 0)
        mainStackView.addArrangedSubview(labelStackView)
        
        // Constraints
        contentView.addSubview(mainStackView)
        mainStackView.pin(to: contentView)
        
        if mode == .draft {
            // Cancel button
            let cancelButton = UIButton(type: .custom)
            cancelButton.setImage(UIImage(named: "X")?.withRenderingMode(.alwaysTemplate), for: .normal)
            cancelButton.themeTintColor = .textPrimary
            cancelButton.set(.width, to: cancelButtonSize)
            cancelButton.set(.height, to: cancelButtonSize)
            cancelButton.addTarget(self, action: #selector(cancel), for: UIControl.Event.touchUpInside)
            
            mainStackView.addArrangedSubview(cancelButton)
            cancelButton.center(.vertical, in: self)
        }
    }

    // MARK: - Interaction
    
    @objc private func cancel() {
        onCancel?()
    }
}
