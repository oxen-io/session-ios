// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

public final class FullConversationCell: UITableViewCell, SwipeActionOptimisticCell {
    public static let mutePrefix: String = "\u{e067}  "
    public static let unreadCountViewSize: CGFloat = 20
    private static let statusIndicatorSize: CGFloat = 14
    
    // MARK: - UI
    
    private let accentLineView: UIView = UIView()

    private lazy var profilePictureView: ProfilePictureView = ProfilePictureView(size: .list)

    private lazy var displayNameLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byTruncatingTail
        
        return result
    }()

    private lazy var unreadCountView: UIView = {
        let result: UIView = UIView()
        result.clipsToBounds = true
        result.themeBackgroundColor = .conversationButton_unreadBubbleBackground
        result.layer.cornerRadius = (FullConversationCell.unreadCountViewSize / 2)
        result.set(.width, greaterThanOrEqualTo: FullConversationCell.unreadCountViewSize)
        result.set(.height, to: FullConversationCell.unreadCountViewSize)
        
        return result
    }()

    private lazy var unreadCountLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.verySmallFontSize)
        result.themeTextColor = .conversationButton_unreadBubbleText
        result.textAlignment = .center
        
        return result
    }()
    
    private lazy var unreadImageView: UIView = {
        let iconHeight: CGFloat = 12
        let indicatorSize: CGFloat = 6
        
        let result: UIView = UIView()
        
        let imageView: UIImageView = UIImageView(image: UIImage(systemName: "envelope"))
        imageView.contentMode = .scaleAspectFit
        imageView.themeTintColor = .textPrimary
        result.addSubview(imageView)
        
        // Note: We add a 2 inset to align the bottom of the image with the bottom of the text (looks
        // off otherwise)
        imageView.pin(.top, to: .top, of: result, withInset: 2)
        imageView.pin(.leading, to: .leading, of: result)
        imageView.pin(.trailing, to: .trailing, of: result)
        imageView.pin(.bottom, to: .bottom, of: result)
        
        // Note: For some weird reason if we dont '+ 4' here the height ends up getting set to '8'
        imageView.set(.height, to: (iconHeight + 4))
        imageView.set(.width, to: ((imageView.image?.size.width ?? 1) / (imageView.image?.size.height ?? 1) * iconHeight))
        
        let indicatorBackgroundView: UIView = UIView()
        indicatorBackgroundView.themeBackgroundColor = .conversationButton_unreadBackground
        indicatorBackgroundView.layer.cornerRadius = (indicatorSize / 2)
        result.addSubview(indicatorBackgroundView)

        indicatorBackgroundView.set(.width, to: indicatorSize)
        indicatorBackgroundView.set(.height, to: indicatorSize)
        indicatorBackgroundView.pin(.top, to: .top, of: result, withInset: 1)
        indicatorBackgroundView.pin(.trailing, to: .trailing, of: result, withInset: 1)
        
        let indicatorView: UIView = UIView()
        indicatorView.themeBackgroundColor = .conversationButton_unreadBubbleBackground
        indicatorView.layer.cornerRadius = ((indicatorSize - 2) / 2)
        result.addSubview(indicatorView)

        indicatorView.set(.width, to: (indicatorSize - 2))
        indicatorView.set(.height, to: (indicatorSize - 2))
        indicatorView.center(in: indicatorBackgroundView)
        
        return result
    }()

    private lazy var hasMentionView: UIView = {
        let result: UIView = UIView()
        result.clipsToBounds = true
        result.themeBackgroundColor = .conversationButton_unreadBubbleBackground
        result.layer.cornerRadius = (FullConversationCell.unreadCountViewSize / 2)
        result.set(.width, to: FullConversationCell.unreadCountViewSize)
        result.set(.height, to: FullConversationCell.unreadCountViewSize)
        
        return result
    }()

    private lazy var hasMentionLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.verySmallFontSize)
        result.themeTextColor = .conversationButton_unreadBubbleText
        result.text = "@"
        result.textAlignment = .center
        
        return result
    }()

    private lazy var isPinnedIcon: UIImageView = {
        let result: UIImageView = UIImageView(
            image: UIImage(named: "Pin")?
                .withRenderingMode(.alwaysTemplate)
        )
        result.clipsToBounds = true
        result.themeTintColor = .textSecondary
        result.contentMode = .scaleAspectFit
        result.set(.width, to: FullConversationCell.unreadCountViewSize)
        result.set(.height, to: FullConversationCell.unreadCountViewSize)
        
        return result
    }()

    private lazy var timestampLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.themeTextColor = .textSecondary
        result.lineBreakMode = .byTruncatingTail
        result.alpha = Values.lowOpacity
        
        return result
    }()

    private lazy var snippetLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byTruncatingTail
        
        return result
    }()

    private lazy var typingIndicatorView = TypingIndicatorView()

    private lazy var statusIndicatorView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.clipsToBounds = true
        result.contentMode = .scaleAspectFit
        
        return result
    }()

    private lazy var topLabelStackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.axis = .horizontal
        result.alignment = .center
        result.spacing = Values.smallSpacing / 2 // Effectively Values.smallSpacing because there'll be spacing before and after the invisible spacer
        
        return result
    }()

    private lazy var bottomLabelStackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.axis = .horizontal
        result.alignment = .center
        result.spacing = Values.smallSpacing / 2 // Effectively Values.smallSpacing because there'll be spacing before and after the invisible spacer
        
        return result
    }()

    // MARK: - Initialization
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        setUpViewHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViewHierarchy()
    }

    private func setUpViewHierarchy() {
        let cellHeight: CGFloat = 68
        
        // Background color
        themeBackgroundColor = .conversationButton_background
        
        // Highlight color
        let selectedBackgroundView = UIView()
        selectedBackgroundView.themeBackgroundColor = .highlighted(.conversationButton_background)
        self.selectedBackgroundView = selectedBackgroundView
        
        // Accent line view
        accentLineView.set(.width, to: Values.accentLineThickness)
        accentLineView.set(.height, to: cellHeight)
        
        // Unread count view
        unreadCountView.addSubview(unreadCountLabel)
        unreadCountView.setCompressionResistance(to: .required)
        unreadCountLabel.pin([ VerticalEdge.top, VerticalEdge.bottom ], to: unreadCountView)
        unreadCountView.pin(.leading, to: .leading, of: unreadCountLabel, withInset: -4)
        unreadCountView.pin(.trailing, to: .trailing, of: unreadCountLabel, withInset: 4)
        
        // Has mention view
        hasMentionView.addSubview(hasMentionLabel)
        hasMentionView.setCompressionResistance(to: .required)
        hasMentionLabel.pin(to: hasMentionView)
        
        // Label stack view
        let topLabelSpacer = UIView.hStretchingSpacer()
        [ displayNameLabel, isPinnedIcon, unreadCountView, unreadImageView, hasMentionView, topLabelSpacer, timestampLabel ].forEach{ view in
            topLabelStackView.addArrangedSubview(view)
        }
        
        let snippetLabelContainer = UIView()
        snippetLabelContainer.addSubview(snippetLabel)
        snippetLabelContainer.addSubview(typingIndicatorView)
        
        let bottomLabelSpacer = UIView.hStretchingSpacer()
        [ snippetLabelContainer, bottomLabelSpacer, statusIndicatorView ].forEach{ view in
            bottomLabelStackView.addArrangedSubview(view)
        }
        
        let labelContainerView = UIStackView(arrangedSubviews: [ topLabelStackView, bottomLabelStackView ])
        labelContainerView.axis = .vertical
        labelContainerView.alignment = .fill
        labelContainerView.spacing = 6
        labelContainerView.isUserInteractionEnabled = false
        
        // Main stack view
        let stackView = UIStackView(arrangedSubviews: [ accentLineView, profilePictureView, labelContainerView ])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = Values.mediumSpacing
        contentView.addSubview(stackView)
        
        // Constraints
        accentLineView.pin(.top, to: .top, of: contentView)
        accentLineView.pin(.bottom, to: .bottom, of: contentView)
        timestampLabel.setContentCompressionResistancePriority(.required, for: NSLayoutConstraint.Axis.horizontal)
        
        // HACK: The 4 lines below are part of a workaround for a weird layout bug
        topLabelStackView.set(.height, to: 20)
        topLabelSpacer.set(.height, to: 20)
        
        bottomLabelStackView.set(.height, to: 18)
        bottomLabelSpacer.set(.height, to: 18)
        
        statusIndicatorView.set(.width, to: FullConversationCell.statusIndicatorSize)
        statusIndicatorView.set(.height, to: FullConversationCell.statusIndicatorSize)
        
        snippetLabel.pin(to: snippetLabelContainer)
        
        typingIndicatorView.pin(.leading, to: .leading, of: snippetLabelContainer)
        typingIndicatorView.centerYAnchor.constraint(equalTo: snippetLabel.centerYAnchor).isActive = true
        
        stackView.pin([ UIView.VerticalEdge.bottom, UIView.VerticalEdge.top, UIView.HorizontalEdge.leading ], to: contentView)
        stackView.pin(.trailing, to: .trailing, of: contentView, withInset: -Values.mediumSpacing)
    }
    
    // MARK: - Content
    
    // MARK: --Search Results
    
    public func updateForMessageSearchResult(
        with cellViewModel: SessionThreadViewModel,
        searchText: String,
        using dependencies: Dependencies
    ) {
        profilePictureView.update(
            publicKey: cellViewModel.threadId,
            threadVariant: cellViewModel.threadVariant,
            displayPictureFilename: cellViewModel.displayPictureFilename,
            profile: cellViewModel.profile,
            additionalProfile: cellViewModel.additionalProfile
        )
        
        isPinnedIcon.isHidden = true
        unreadCountView.isHidden = true
        unreadImageView.isHidden = true
        hasMentionView.isHidden = true
        timestampLabel.isHidden = false
        timestampLabel.text = cellViewModel.lastInteractionDate.formattedForDisplay
        bottomLabelStackView.isHidden = false
        
        ThemeManager.onThemeChange(observer: displayNameLabel) { [weak displayNameLabel] theme, _ in
            guard let textColor: UIColor = theme.color(for: .textPrimary) else { return }
                
            displayNameLabel?.attributedText = NSMutableAttributedString(
                string: cellViewModel.displayName,
                attributes: [ .foregroundColor: textColor ]
            )
        }
        
        ThemeManager.onThemeChange(observer: displayNameLabel) { [weak self, weak snippetLabel] theme, _ in
            guard let textColor: UIColor = theme.color(for: .textPrimary) else { return }
            
            snippetLabel?.attributedText = self?.getHighlightedSnippet(
                content: Interaction.previewText(
                    variant: (cellViewModel.interactionVariant ?? .standardIncoming),
                    body: cellViewModel.interactionBody,
                    authorDisplayName: cellViewModel.authorName(for: .contact),
                    attachmentDescriptionInfo: cellViewModel.interactionAttachmentDescriptionInfo,
                    attachmentCount: cellViewModel.interactionAttachmentCount,
                    isOpenGroupInvitation: (cellViewModel.interactionIsOpenGroupInvitation == true),
                    using: dependencies
                ),
                authorName: (cellViewModel.authorId != cellViewModel.currentUserSessionId ?
                    cellViewModel.authorName(for: .contact) :
                    nil
                ),
                currentUserSessionId: cellViewModel.currentUserSessionId,
                currentUserBlinded15SessionId: cellViewModel.currentUserBlinded15SessionId,
                currentUserBlinded25SessionId: cellViewModel.currentUserBlinded25SessionId,
                searchText: searchText.lowercased(),
                fontSize: Values.smallFontSize,
                textColor: textColor
            )
        }
    }
    
    public func updateForContactAndGroupSearchResult(
        with cellViewModel: SessionThreadViewModel,
        searchText: String
    ) {
        profilePictureView.update(
            publicKey: cellViewModel.threadId,
            threadVariant: cellViewModel.threadVariant,
            displayPictureFilename: cellViewModel.displayPictureFilename,
            profile: cellViewModel.profile,
            additionalProfile: cellViewModel.additionalProfile
        )
        
        isPinnedIcon.isHidden = true
        unreadCountView.isHidden = true
        unreadImageView.isHidden = true
        hasMentionView.isHidden = true
        timestampLabel.isHidden = true
        
        ThemeManager.onThemeChange(observer: displayNameLabel) { [weak self, weak displayNameLabel] theme, _ in
            guard let textColor: UIColor = theme.color(for: .textPrimary) else { return }
            
            displayNameLabel?.attributedText = self?.getHighlightedSnippet(
                content: cellViewModel.displayName,
                currentUserSessionId: cellViewModel.currentUserSessionId,
                currentUserBlinded15SessionId: cellViewModel.currentUserBlinded15SessionId,
                currentUserBlinded25SessionId: cellViewModel.currentUserBlinded25SessionId,
                searchText: searchText.lowercased(),
                fontSize: Values.mediumFontSize,
                textColor: textColor
            )
        }
        
        switch cellViewModel.threadVariant {
            case .contact, .community: bottomLabelStackView.isHidden = true
                
            case .legacyGroup, .group:
                bottomLabelStackView.isHidden = (cellViewModel.threadMemberNames ?? "").isEmpty
        
                ThemeManager.onThemeChange(observer: displayNameLabel) { [weak self, weak snippetLabel] theme, _ in
                    guard let textColor: UIColor = theme.color(for: .textPrimary) else { return }
                    if cellViewModel.threadVariant == .legacyGroup || cellViewModel.threadVariant == .group {
                        snippetLabel?.attributedText = self?.getHighlightedSnippet(
                            content: (cellViewModel.threadMemberNames ?? ""),
                            currentUserSessionId: cellViewModel.currentUserSessionId,
                            currentUserBlinded15SessionId: cellViewModel.currentUserBlinded15SessionId,
                            currentUserBlinded25SessionId: cellViewModel.currentUserBlinded25SessionId,
                            searchText: searchText.lowercased(),
                            fontSize: Values.smallFontSize,
                            textColor: textColor
                        )
                    }
                }
        }
    }

    // MARK: --Standard
    
    public func update(with cellViewModel: SessionThreadViewModel, using dependencies: Dependencies) {
        let unreadCount: UInt = (cellViewModel.threadUnreadCount ?? 0)
        let threadIsUnread: Bool = (
            unreadCount > 0 ||
            cellViewModel.threadWasMarkedUnread == true
        )
        let themeBackgroundColor: ThemeValue = (threadIsUnread ?
            .conversationButton_unreadBackground :
            .conversationButton_background
        )
        self.themeBackgroundColor = themeBackgroundColor
        self.selectedBackgroundView?.themeBackgroundColor = .highlighted(themeBackgroundColor)
        
        if cellViewModel.threadIsBlocked == true {
            accentLineView.themeBackgroundColor = .danger
            accentLineView.alpha = 1
        }
        else {
            accentLineView.themeBackgroundColor = .conversationButton_unreadStripBackground
            accentLineView.alpha = (unreadCount > 0 ? 1 : 0)
        }
        
        isPinnedIcon.isHidden = (cellViewModel.threadPinnedPriority == 0)
        unreadCountView.isHidden = (unreadCount <= 0)
        unreadImageView.isHidden = (!unreadCountView.isHidden || !threadIsUnread)
        unreadCountLabel.text = (unreadCount <= 0 ?
            "" :
            (unreadCount < 10000 ? "\(unreadCount)" : "9999+")
        )
        unreadCountLabel.font = .boldSystemFont(
            ofSize: (unreadCount < 10000 ? Values.verySmallFontSize : 8)
        )
        hasMentionView.isHidden = !(
            ((cellViewModel.threadUnreadMentionCount ?? 0) > 0) && (
                cellViewModel.threadVariant == .legacyGroup ||
                cellViewModel.threadVariant == .group ||
                cellViewModel.threadVariant == .community
            )
        )
        profilePictureView.update(
            publicKey: cellViewModel.threadId,
            threadVariant: cellViewModel.threadVariant,
            displayPictureFilename: cellViewModel.displayPictureFilename,
            profile: cellViewModel.profile,
            additionalProfile: cellViewModel.additionalProfile
        )
        displayNameLabel.text = cellViewModel.displayName
        timestampLabel.text = cellViewModel.lastInteractionDate.formattedForDisplay
        
        if cellViewModel.threadContactIsTyping == true {
            snippetLabel.text = ""
            typingIndicatorView.isHidden = false
            typingIndicatorView.startAnimation()
        }
        else {
            displayNameLabel.themeTextColor = {
                guard cellViewModel.interactionVariant != .infoGroupCurrentUserLeaving else {
                    return .textSecondary
                }
                
                return .textPrimary
            }()
            typingIndicatorView.isHidden = true
            typingIndicatorView.stopAnimation()
            
            ThemeManager.onThemeChange(observer: snippetLabel) { [weak self, weak snippetLabel] theme, _ in
                if cellViewModel.interactionVariant == .infoGroupCurrentUserLeaving {
                    guard let textColor: UIColor = theme.color(for: .textSecondary) else { return }
                    
                    snippetLabel?.attributedText = self?.getSnippet(
                        cellViewModel: cellViewModel,
                        textColor: textColor,
                        using: dependencies
                    )
                } else if cellViewModel.interactionVariant == .infoGroupCurrentUserErrorLeaving {
                    guard let textColor: UIColor = theme.color(for: .danger) else { return }
                    
                    snippetLabel?.attributedText = self?.getSnippet(
                        cellViewModel: cellViewModel,
                        textColor: textColor,
                        using: dependencies
                    )
                } else {
                    guard let textColor: UIColor = theme.color(for: .textPrimary) else { return }
                    
                    snippetLabel?.attributedText = self?.getSnippet(
                        cellViewModel: cellViewModel,
                        textColor: textColor,
                        using: dependencies
                    )
                }
            }
        }
        
        let stateInfo = cellViewModel.interactionState?.statusIconInfo(
            variant: (cellViewModel.interactionVariant ?? .standardOutgoing),
            hasAtLeastOneReadReceipt: (cellViewModel.interactionHasAtLeastOneReadReceipt ?? false)
        )
        statusIndicatorView.image = stateInfo?.image
        statusIndicatorView.themeTintColor = stateInfo?.themeTintColor
        statusIndicatorView.isHidden = (
            cellViewModel.interactionVariant != .standardOutgoing &&
            cellViewModel.interactionState != .skipped
        )
    }
    
    // MARK: - SwipeActionOptimisticCell
    
    public func optimisticUpdate(
        isMuted: Bool?,
        isBlocked: Bool?,
        isPinned: Bool?,
        hasUnread: Bool?
    ) {
        // Note: This will result in the snippet being out of sync while the swipe action animation completes,
        // this means if the day/night mode changes while the animation is happening then the below optimistic
        // update might get reset (this should be rare and is a relatively minor bug so can be left in)
        if let isMuted: Bool = isMuted {
            let attrString: NSAttributedString = (self.snippetLabel.attributedText ?? NSAttributedString())
            let hasMutePrefix: Bool = attrString.string.starts(with: FullConversationCell.mutePrefix)
            
            switch (isMuted, hasMutePrefix) {
                case (true, false):
                    self.snippetLabel.attributedText = NSAttributedString(
                        string: FullConversationCell.mutePrefix,
                        attributes: [ .font: UIFont(name: "ElegantIcons", size: 10) as Any ]
                    )
                    .appending(attrString)
                    
                case (false, true):
                    self.snippetLabel.attributedText = attrString
                        .attributedSubstring(from: NSRange(location: FullConversationCell.mutePrefix.count, length: (attrString.length - FullConversationCell.mutePrefix.count)))
                    
                default: break
            }
        }
        
        if let isBlocked: Bool = isBlocked {
            if isBlocked {
                accentLineView.themeBackgroundColor = .danger
                accentLineView.alpha = 1
            }
            else {
                accentLineView.themeBackgroundColor = .conversationButton_unreadStripBackground
                accentLineView.alpha = (!unreadCountView.isHidden || !unreadImageView.isHidden ? 1 : 0)
            }
        }
        
        if let isPinned: Bool = isPinned {
            isPinnedIcon.isHidden = !isPinned
        }
        
        if let hasUnread: Bool = hasUnread {
            if hasUnread {
                unreadCountView.isHidden = false
                unreadCountLabel.text = "1"
                unreadCountLabel.font = .boldSystemFont(ofSize: Values.verySmallFontSize)
                accentLineView.alpha = 1
            } else {
                unreadCountView.isHidden = true
                accentLineView.alpha = 0
            }
        }
    }
    
    // MARK: - Snippet generation

    private func getSnippet(
        cellViewModel: SessionThreadViewModel,
        textColor: UIColor,
        using dependencies: Dependencies
    ) -> NSMutableAttributedString {
        // If we don't have an interaction then do nothing
        guard cellViewModel.interactionId != nil else { return NSMutableAttributedString() }
        
        let result = NSMutableAttributedString()
        
        if Date().timeIntervalSince1970 < (cellViewModel.threadMutedUntilTimestamp ?? 0) {
            result.append(NSAttributedString(
                string: FullConversationCell.mutePrefix,
                attributes: [
                    .font: UIFont(name: "ElegantIcons", size: 10) as Any,
                    .foregroundColor: textColor
                ]
            ))
        }
        else if cellViewModel.threadOnlyNotifyForMentions == true {
            let imageAttachment = NSTextAttachment()
            imageAttachment.image = UIImage(named: "NotifyMentions.png")?.withTint(textColor)
            imageAttachment.bounds = CGRect(x: 0, y: -2, width: Values.smallFontSize, height: Values.smallFontSize)
            
            let imageString = NSAttributedString(attachment: imageAttachment)
            result.append(imageString)
            result.append(NSAttributedString(
                string: "  ",
                attributes: [
                    .font: UIFont(name: "ElegantIcons", size: 10) as Any,
                    .foregroundColor: textColor
                ]
            ))
        }
        
        if
            (cellViewModel.threadVariant == .legacyGroup || cellViewModel.threadVariant == .group || cellViewModel.threadVariant == .community) &&
            (cellViewModel.interactionVariant?.isGroupControlMessage == false)
        {
            let authorName: String = cellViewModel.authorName(for: cellViewModel.threadVariant)
            
            result.append(NSAttributedString(
                string: "\(authorName): ",
                attributes: [ .foregroundColor: textColor ]
            ))
        }
        
        let previewText: String = {
            if cellViewModel.interactionVariant == .infoGroupCurrentUserErrorLeaving { return "group_leave_error".localized() }
            return Interaction.previewText(
                variant: (cellViewModel.interactionVariant ?? .standardIncoming),
                body: cellViewModel.interactionBody,
                threadContactDisplayName: cellViewModel.threadContactName(),
                authorDisplayName: cellViewModel.authorName(for: cellViewModel.threadVariant),
                attachmentDescriptionInfo: cellViewModel.interactionAttachmentDescriptionInfo,
                attachmentCount: cellViewModel.interactionAttachmentCount,
                isOpenGroupInvitation: (cellViewModel.interactionIsOpenGroupInvitation == true),
                using: dependencies
            )
        }()
        
        result.append(NSAttributedString(
            string: MentionUtilities.highlightMentionsNoAttributes(
                in: previewText,
                threadVariant: cellViewModel.threadVariant,
                currentUserSessionId: cellViewModel.currentUserSessionId,
                currentUserBlinded15SessionId: cellViewModel.currentUserBlinded15SessionId,
                currentUserBlinded25SessionId: cellViewModel.currentUserBlinded25SessionId
            ),
            attributes: [ .foregroundColor: textColor ]
        ))
            
        return result
    }
    
    private func getHighlightedSnippet(
        content: String,
        authorName: String? = nil,
        currentUserSessionId: String,
        currentUserBlinded15SessionId: String?,
        currentUserBlinded25SessionId: String?,
        searchText: String,
        fontSize: CGFloat,
        textColor: UIColor
    ) -> NSAttributedString {
        guard !content.isEmpty, content != "NOTE_TO_SELF".localized() else {
            return NSMutableAttributedString(
                string: (authorName != nil && authorName?.isEmpty != true ?
                    "\(authorName ?? ""): \(content)" :
                    content
                ),
                attributes: [ .foregroundColor: textColor ]
            )
        }
        
        // Replace mentions in the content
        //
        // Note: The 'threadVariant' is used for profile context but in the search results
        // we don't want to include the truncated id as part of the name so we exclude it
        let mentionReplacedContent: String = MentionUtilities.highlightMentionsNoAttributes(
            in: content,
            threadVariant: .contact,
            currentUserSessionId: currentUserSessionId,
            currentUserBlinded15SessionId: currentUserBlinded15SessionId,
            currentUserBlinded25SessionId: currentUserBlinded25SessionId
        )
        let result: NSMutableAttributedString = NSMutableAttributedString(
            string: mentionReplacedContent,
            attributes: [
                .foregroundColor: textColor
                    .withAlphaComponent(Values.lowOpacity)
            ]
        )
        
        // Bold each part of the searh term which matched
        let normalizedSnippet: String = mentionReplacedContent.lowercased()
        var firstMatchRange: Range<String.Index>?
        
        SessionThreadViewModel.searchTermParts(searchText)
            .map { part -> String in
                guard part.hasPrefix("\"") && part.hasSuffix("\"") else { return part }
                
                return part.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            .forEach { part in
                // Highlight all ranges of the text (Note: The search logic only finds results that start
                // with the term so we use the regex below to ensure we only highlight those cases)
                normalizedSnippet
                    .ranges(
                        of: (Dependencies.isRTL ?
                             "(\(part.lowercased()))(^|[^a-zA-Z0-9])" :
                             "(^|[^a-zA-Z0-9])(\(part.lowercased()))"
                        ),
                        options: [.regularExpression]
                    )
                    .forEach { range in
                        let targetRange: Range<String.Index> = {
                            let term: String = String(normalizedSnippet[range])
                            
                            // If the matched term doesn't actually match the "part" value then it means
                            // we've matched a term after a non-alphanumeric character so need to shift
                            // the range over by 1
                            guard term.starts(with: part.lowercased()) else {
                                return (normalizedSnippet.index(after: range.lowerBound)..<range.upperBound)
                            }
                            
                            return range
                        }()
                        
                        // Store the range of the first match so we can focus it in the content displayed
                        if firstMatchRange == nil {
                            firstMatchRange = targetRange
                        }
                        
                        let legacyRange: NSRange = NSRange(targetRange, in: normalizedSnippet)
                        result.addAttribute(.foregroundColor, value: textColor, range: legacyRange)
                        result.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: fontSize), range: legacyRange)
                    }
            }
        
        // Now that we have generated the focused snippet add the author name as a prefix (if provided)
        return authorName
            .map { authorName -> NSAttributedString? in
                guard !authorName.isEmpty else { return nil }
                
                let authorPrefix: NSAttributedString = NSAttributedString(
                    string: "\(authorName): ",
                    attributes: [ .foregroundColor: textColor ]
                )
                
                return authorPrefix.appending(result)
            }
            .defaulting(to: result)
    }
}
