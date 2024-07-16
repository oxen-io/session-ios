// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

struct QuoteView_SwiftUI: View {
    public enum Mode { case regular, draft }
    public enum Direction { case incoming, outgoing }
    public struct Info {
        var mode: Mode
        var authorId: String
        var quotedText: String?
        var threadVariant: SessionThread.Variant
        var currentUserSessionId: String?
        var currentUserBlinded15SessionId: String?
        var currentUserBlinded25SessionId: String?
        var direction: Direction
        var attachment: Attachment?
    }
    
    @State private var thumbnail: UIImage? = nil
    
    private static let thumbnailSize: CGFloat = 48
    private static let iconSize: CGFloat = 24
    private static let labelStackViewSpacing: CGFloat = 2
    private static let labelStackViewVMargin: CGFloat = 4
    private static let cancelButtonSize: CGFloat = 33
    private static let cornerRadius: CGFloat = 4
    
    private let dependencies: Dependencies
    private var info: Info
    private var onCancel: (() -> ())?
    
    private var isCurrentUser: Bool {
        return [
            info.currentUserSessionId,
            info.currentUserBlinded15SessionId,
            info.currentUserBlinded25SessionId
        ]
        .compactMap { $0 }
        .asSet()
        .contains(info.authorId)
    }
    private var quotedText: String? {
        if let quotedText = info.quotedText, !quotedText.isEmpty {
            return quotedText
        }
        
        if let attachment = info.attachment {
            return attachment.shortDescription
        }
        
        return nil
    }
    private var author: String? {
        guard !isCurrentUser else { return "MEDIA_GALLERY_SENDER_NAME_YOU".localized() }
        guard quotedText != nil else {
            // When we can't find the quoted message we want to hide the author label
            return Profile.displayNameNoFallback(
                id: info.authorId,
                threadVariant: info.threadVariant,
                using: dependencies
            )
        }
        
        return Profile.displayName(
            id: info.authorId,
            threadVariant: info.threadVariant,
            using: dependencies
        )
    }
    
    public init(info: Info, using dependencies: Dependencies, onCancel: (() -> ())? = nil) {
        self.dependencies = dependencies
        self.info = info
        self.onCancel = onCancel
        
        if let attachment = info.attachment, attachment.isVisualMedia {
            attachment.thumbnail(
                size: .small,
                using: dependencies,
                success: { [self] image, _ in
                    self.thumbnail = image
                },
                failure: {}
            )
        }
    }
    
    var body: some View {
        HStack(
            alignment: .center,
            spacing: Values.smallSpacing
        ) {
            if let attachment: Attachment = info.attachment {
                // Attachment thumbnail
                if let image: UIImage = {
                    if let thumbnail = self.thumbnail {
                        return thumbnail
                    }
                    
                    let fallbackImageName: String = (MimeTypeUtil.isAudio(attachment.contentType) ? "attachment_audio" : "actionsheet_document_black")
                    return UIImage(named: fallbackImageName)?
                        .resized(to: CGSize(width: Self.iconSize, height: Self.iconSize))?
                        .withRenderingMode(.alwaysTemplate)
                }() {
                    Image(uiImage: image)
                        .foregroundColor(themeColor: {
                            switch info.mode {
                                case .regular: return (info.direction == .outgoing ?
                                        .messageBubble_outgoingText :
                                        .messageBubble_incomingText
                                    )
                                case .draft: return .textPrimary
                            }
                        }())
                        .frame(
                            width: Self.thumbnailSize,
                            height: Self.thumbnailSize,
                            alignment: .center
                        )
                        .background(themeColor: .messageBubble_overlay)
                        .cornerRadius(Self.cornerRadius)
                }
            } else {
                // Line view
                let lineColor: ThemeValue = {
                    switch info.mode {
                        case .regular: return (info.direction == .outgoing ? .messageBubble_outgoingText : .primary)
                        case .draft: return .primary
                    }
                }()
                
                Rectangle()
                    .foregroundColor(themeColor: lineColor)
                    .frame(width: Values.accentLineThickness)
            }
            
            // Quoted text and author
            VStack(
                alignment: .leading,
                spacing: Self.labelStackViewSpacing
            ) {
                let targetThemeColor: ThemeValue = {
                    switch info.mode {
                        case .regular: return (info.direction == .outgoing ?
                            .messageBubble_outgoingText :
                            .messageBubble_incomingText
                        )
                        case .draft: return .textPrimary
                    }
                }()
                
                if let author = self.author {
                    Text(author)
                        .bold()
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: targetThemeColor)
                }
                
                if let quotedText = self.quotedText, let textColor = ThemeManager.currentTheme.color(for: targetThemeColor) {
                    AttributedText(
                        MentionUtilities.highlightMentions(
                            in: quotedText,
                            threadVariant: info.threadVariant,
                            currentUserSessionId: info.currentUserSessionId,
                            currentUserBlinded15SessionId: info.currentUserBlinded15SessionId,
                            currentUserBlinded25SessionId: info.currentUserBlinded25SessionId,
                            isOutgoingMessage: (info.direction == .outgoing),
                            textColor: textColor,
                            theme: ThemeManager.currentTheme,
                            primaryColor: ThemeManager.primaryColor,
                            attributes: [
                                .foregroundColor: textColor,
                                .font: UIFont.systemFont(ofSize: Values.smallFontSize)
                            ],
                            using: dependencies
                        )
                    )
                    .lineLimit(2)
                } else {
                    Text("QUOTED_MESSAGE_NOT_FOUND".localized())
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: targetThemeColor)
                }
            }
            .padding(.vertical, Self.labelStackViewVMargin)
            
            if info.mode == .draft {
                // Cancel button
                Button(
                    action: {
                        onCancel?()
                    },
                    label: {
                        if let image = UIImage(named: "X")?.withRenderingMode(.alwaysTemplate) {
                            Image(uiImage: image)
                                .foregroundColor(themeColor: .textPrimary)
                                .frame(
                                    width: Self.cancelButtonSize,
                                    height: Self.cancelButtonSize,
                                    alignment: .center
                                )
                        }
                    }
                )
            }
        }
        .padding(.trailing, Values.smallSpacing)
    }
}

struct QuoteView_SwiftUI_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            if #available(iOS 14.0, *) {
                ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
            } else {
                ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary)
            }
            
            QuoteView_SwiftUI(
                info: QuoteView_SwiftUI.Info(
                    mode: .draft,
                    authorId: "",
                    threadVariant: .contact,
                    direction: .outgoing
                ),
                using: Dependencies.createEmpty()
            )
            .frame(height: 40)
        }
    }
}
