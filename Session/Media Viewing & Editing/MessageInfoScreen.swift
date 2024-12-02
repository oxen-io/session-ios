// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit
import SessionMessagingKit

struct MessageInfoScreen: View {
    @EnvironmentObject var host: HostWrapper
    
    @State var index = 1
    
    static private let cornerRadius: CGFloat = 17
    
    var actions: [ContextMenuVC.Action]
    var messageViewModel: MessageViewModel
    let dependencies: Dependencies
    var isMessageFailed: Bool {
        return [.failed, .failedToSync].contains(messageViewModel.state)
    }
    
    var body: some View {
        ZStack (alignment: .topLeading) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(
                    alignment: .leading,
                    spacing: 10
                ) {
                    // Message bubble snapshot
                    MessageBubble(
                        messageViewModel: messageViewModel,
                        dependencies: dependencies
                    )
                    .background(
                        RoundedRectangle(cornerRadius: Self.cornerRadius)
                            .fill(
                                themeColor: (messageViewModel.variant == .standardIncoming || messageViewModel.variant == .standardIncomingDeleted || messageViewModel.variant == .standardIncomingDeletedLocally ?
                                    .messageBubble_incomingBackground :
                                    .messageBubble_outgoingBackground)
                            )
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Values.smallSpacing)
                    .padding(.bottom, Values.verySmallSpacing)
                    .padding(.horizontal, Values.largeSpacing)
                    
                    
                    if isMessageFailed {
                        let (image, statusText, tintColor) = messageViewModel.state.statusIconInfo(
                            variant: messageViewModel.variant,
                            hasBeenReadByRecipient: messageViewModel.hasBeenReadByRecipient,
                            hasAttachments: (messageViewModel.attachments?.isEmpty == false)
                        )
                        
                        HStack(spacing: 6) {
                            if let image: UIImage = image?.withRenderingMode(.alwaysTemplate) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .foregroundColor(themeColor: tintColor)
                                    .frame(width: 13, height: 12)
                            }
                            
                            if let statusText: String = statusText {
                                Text(statusText)
                                    .font(.system(size: Values.verySmallFontSize))
                                    .foregroundColor(themeColor: tintColor)
                            }
                        }
                        .padding(.top, -Values.smallSpacing)
                        .padding(.bottom, Values.verySmallSpacing)
                        .padding(.horizontal, Values.largeSpacing)
                    }
                    
                    if let attachments = messageViewModel.attachments,
                       messageViewModel.cellType == .mediaMessage
                    {
                        let attachment: Attachment = attachments[(index - 1 + attachments.count) % attachments.count]
                        
                        ZStack(alignment: .bottomTrailing) {
                            if attachments.count > 1 {
                                // Attachment carousel view
                                SessionCarouselView_SwiftUI(
                                    index: $index,
                                    isOutgoing: (messageViewModel.variant == .standardOutgoing),
                                    contentInfos: attachments,
                                    using: dependencies
                                )
                                .frame(
                                    maxWidth: .infinity,
                                    maxHeight: .infinity,
                                    alignment: .topLeading
                                )
                            } else {
                                MediaView_SwiftUI(
                                    attachment: attachments[0],
                                    isOutgoing: (messageViewModel.variant == .standardOutgoing),
                                    shouldSupressControls: true, 
                                    cornerRadius: 0,
                                    using: dependencies
                                )
                                .frame(
                                    maxWidth: .infinity,
                                    maxHeight: .infinity,
                                    alignment: .topLeading
                                )
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 15))
                                .padding(.horizontal, Values.largeSpacing)
                            }
                            
                            if [ .downloaded, .uploaded ].contains(attachment.state) {
                                Button {
                                    self.showMediaFullScreen(attachment: attachment)
                                } label: {
                                    ZStack {
                                        Circle()
                                            .foregroundColor(.init(white: 0, opacity: 0.4))
                                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                                            .font(.system(size: 13))
                                            .foregroundColor(.white)
                                    }
                                    .frame(width: 26, height: 26)
                                }
                                .padding(.bottom, Values.smallSpacing)
                                .padding(.trailing, 38)
                            }
                        }
                        .padding(.vertical, Values.verySmallSpacing)
                        
                        // Attachment Info
                        ZStack {
                            VStack(
                                alignment: .leading,
                                spacing: Values.mediumSpacing
                            ) {
                                InfoBlock(title: "attachmentsFileId".localized()) {
                                    Text(attachment.serverId ?? "")
                                        .font(.system(size: Values.mediumFontSize))
                                        .foregroundColor(themeColor: .textPrimary)
                                }
                                
                                HStack(
                                    alignment: .center
                                ) {
                                    InfoBlock(title: "attachmentsFileType".localized()) {
                                        Text(attachment.contentType)
                                            .font(.system(size: Values.mediumFontSize))
                                            .foregroundColor(themeColor: .textPrimary)
                                    }
                                    
                                    Spacer()
                                    
                                    InfoBlock(title: "attachmentsFileSize".localized()) {
                                        Text(Format.fileSize(attachment.byteCount))
                                            .font(.system(size: Values.mediumFontSize))
                                            .foregroundColor(themeColor: .textPrimary)
                                    }
                                    
                                    Spacer()
                                }
                                HStack(
                                    alignment: .center
                                ) {
                                    let resolution: String = {
                                        guard let width = attachment.width, let height = attachment.height else { return "attachmentsNa".localized() }
                                        return "\(width)×\(height)"
                                    }()
                                    InfoBlock(title: "attachmentsResolution".localized()) {
                                        Text(resolution)
                                            .font(.system(size: Values.mediumFontSize))
                                            .foregroundColor(themeColor: .textPrimary)
                                    }
                                    
                                    Spacer()
                                    
                                    let duration: String = {
                                        guard let duration = attachment.duration else { return "attachmentsNa".localized() }
                                        return floor(duration).formatted(format: .videoDuration)
                                    }()
                                    InfoBlock(title: "attachmentsDuration".localized()) {
                                        Text(duration)
                                            .font(.system(size: Values.mediumFontSize))
                                            .foregroundColor(themeColor: .textPrimary)
                                    }
                                    
                                    Spacer()
                                }
                            }
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .topLeading
                            )
                            .padding(.all, Values.largeSpacing)
                        }
                        .frame(maxHeight: .infinity)
                        .backgroundColor(themeColor: .backgroundSecondary)
                        .cornerRadius(Self.cornerRadius)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Values.verySmallSpacing)
                        .padding(.horizontal, Values.largeSpacing)
                    }

                    // Message Info
                    ZStack {
                        VStack(
                            alignment: .leading,
                            spacing: Values.mediumSpacing
                        ) {
                            InfoBlock(title: "sent".localized()) {
                                Text(messageViewModel.dateForUI.fromattedForMessageInfo)
                                    .font(.system(size: Values.mediumFontSize))
                                    .foregroundColor(themeColor: .textPrimary)
                            }
                            
                            InfoBlock(title: "received".localized()) {
                                Text(messageViewModel.receivedDateForUI.fromattedForMessageInfo)
                                    .font(.system(size: Values.mediumFontSize))
                                    .foregroundColor(themeColor: .textPrimary)
                            }
                            
                            if isMessageFailed {
                                let failureText: String = messageViewModel.mostRecentFailureText ?? "messageStatusFailedToSend".localized()
                                InfoBlock(title: "theError".localized() + ":") {
                                    Text(failureText)
                                        .font(.system(size: Values.mediumFontSize))
                                        .foregroundColor(themeColor: .danger)
                                }
                            }
                            
                            InfoBlock(title: "from".localized()) {
                                HStack(
                                    spacing: 10
                                ) {
                                    let (info, additionalInfo) = ProfilePictureView.getProfilePictureInfo(
                                        size: .message,
                                        publicKey: messageViewModel.authorId,
                                        threadVariant: .contact,    // Always show the display picture in 'contact' mode
                                        displayPictureFilename: nil,
                                        profile: messageViewModel.profile,
                                        profileIcon: (messageViewModel.isSenderOpenGroupModerator ? .crown : .none),
                                        using: dependencies
                                    )
                                    
                                    let size: ProfilePictureView.Size = .list
                                    
                                    if let info: ProfilePictureView.Info = info {
                                        ProfilePictureSwiftUI(
                                            size: size,
                                            info: info,
                                            additionalInfo: additionalInfo
                                        )
                                        .frame(
                                            width: size.viewSize,
                                            height: size.viewSize,
                                            alignment: .topLeading
                                        )
                                    }
                                    
                                    VStack(
                                        alignment: .leading,
                                        spacing: Values.verySmallSpacing
                                    ) {
                                        if !messageViewModel.authorName.isEmpty  {
                                            Text(messageViewModel.authorName)
                                                .bold()
                                                .font(.system(size: Values.mediumLargeFontSize))
                                                .foregroundColor(themeColor: .textPrimary)
                                        }
                                        Text(messageViewModel.authorId)
                                            .font(.spaceMono(size: Values.smallFontSize))
                                            .foregroundColor(themeColor: .textPrimary)
                                    }
                                }
                            }
                        }
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .padding(.all, Values.largeSpacing)
                    }
                    .frame(maxHeight: .infinity)
                    .backgroundColor(themeColor: .backgroundSecondary)
                    .cornerRadius(Self.cornerRadius)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Values.verySmallSpacing)
                    .padding(.horizontal, Values.largeSpacing)

                    // Actions
                    if !actions.isEmpty {
                        ZStack {
                            VStack(
                                alignment: .leading,
                                spacing: 0
                            ) {
                                ForEach(
                                    0...(actions.count - 1),
                                    id: \.self
                                ) { index in
                                    let tintColor: ThemeValue = actions[index].themeColor
                                    Button(
                                        action: {
                                            actions[index].work()
                                            dismiss()
                                        },
                                        label: {
                                            HStack(spacing: Values.largeSpacing) {
                                                Image(uiImage: actions[index].icon!.withRenderingMode(.alwaysTemplate))
                                                    .resizable()
                                                    .scaledToFit()
                                                    .foregroundColor(themeColor: tintColor)
                                                    .frame(width: 26, height: 26)
                                                Text(actions[index].title)
                                                    .bold()
                                                    .font(.system(size: Values.mediumLargeFontSize))
                                                    .foregroundColor(themeColor: tintColor)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .topLeading)
                                        }
                                    )
                                    .frame(height: 60)
                                    
                                    if index < (actions.count - 1) {
                                        Divider()
                                            .foregroundColor(themeColor: .borderSeparator)
                                    }
                                }
                            }
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .topLeading
                            )
                            .padding(.horizontal, Values.largeSpacing)
                        }
                        .frame(maxHeight: .infinity)
                        .backgroundColor(themeColor: .backgroundSecondary)
                        .cornerRadius(Self.cornerRadius)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Values.verySmallSpacing)
                        .padding(.horizontal, Values.largeSpacing)
                    }
                }
            }
        }
        .backgroundColor(themeColor: .backgroundPrimary)
    }
    
    private func showMediaFullScreen(attachment: Attachment) {
        if let mediaGalleryView = MediaGalleryViewModel.createDetailViewController(
            for: messageViewModel.threadId,
            threadVariant: messageViewModel.threadVariant,
            interactionId: messageViewModel.id,
            selectedAttachmentId: attachment.id,
            options: [ .sliderEnabled ],
            useTransitioningDelegate: false,
            using: dependencies
        ) {
            self.host.controller?.present(mediaGalleryView, animated: true)
        }
    }
    
    func dismiss() {
        self.host.controller?.navigationController?.popViewController(animated: true)
    }
}

struct MessageBubble: View {
    @State private var maxWidth: CGFloat?
    
    static private let cornerRadius: CGFloat = 18
    static private let inset: CGFloat = 12
    
    let messageViewModel: MessageViewModel
    let dependencies: Dependencies
    
    var bodyLabelTextColor: ThemeValue {
        messageViewModel.variant == .standardOutgoing ?
            .messageBubble_outgoingText :
            .messageBubble_incomingText
    }
    
    var body: some View {
        ZStack {
            switch messageViewModel.cellType {
                case .textOnlyMessage:
                    let maxWidth: CGFloat = (VisibleMessageCell.getMaxWidth(for: messageViewModel) - 2 * Self.inset)
                    
                    VStack(
                        alignment: .leading,
                        spacing: 0
                    ) {
                        if let linkPreview: LinkPreview = messageViewModel.linkPreview {
                            switch linkPreview.variant {
                            case .standard:
                                LinkPreviewView_SwiftUI(
                                    state: LinkPreview.SentState(
                                        linkPreview: linkPreview,
                                        imageAttachment: messageViewModel.linkPreviewAttachment,
                                        using: dependencies
                                    ),
                                    isOutgoing: (messageViewModel.variant == .standardOutgoing),
                                    maxWidth: maxWidth,
                                    messageViewModel: messageViewModel,
                                    bodyLabelTextColor: bodyLabelTextColor,
                                    lastSearchText: nil
                                )
                                
                            case .openGroupInvitation:
                                OpenGroupInvitationView_SwiftUI(
                                    name: (linkPreview.title ?? ""),
                                    url: linkPreview.url,
                                    textColor: bodyLabelTextColor,
                                    isOutgoing: (messageViewModel.variant == .standardOutgoing))
                            }
                        }
                        else {
                            if let quote = messageViewModel.quote {
                                QuoteView_SwiftUI(
                                    info: .init(
                                        mode: .regular,
                                        authorId: quote.authorId,
                                        quotedText: quote.body,
                                        threadVariant: messageViewModel.threadVariant,
                                        currentUserSessionId: messageViewModel.currentUserSessionId,
                                        currentUserBlinded15SessionId: messageViewModel.currentUserBlinded15SessionId,
                                        currentUserBlinded25SessionId: messageViewModel.currentUserBlinded25SessionId,
                                        direction: (messageViewModel.variant == .standardOutgoing ? .outgoing : .incoming),
                                        attachment: messageViewModel.quoteAttachment
                                    ),
                                    using: dependencies
                                )
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, Self.inset)
                                .padding(.horizontal, Self.inset)
                                .padding(.bottom, -Values.smallSpacing)
                            }
                        }
                        
                        if let bodyText: NSAttributedString = VisibleMessageCell.getBodyAttributedText(
                            for: messageViewModel,
                            theme: ThemeManager.currentTheme,
                            primaryColor: ThemeManager.primaryColor,
                            textColor: bodyLabelTextColor,
                            searchText: nil,
                            using: dependencies
                        ) {
                            AttributedText(bodyText)
                                .padding(.all, Self.inset)
                        }
                    }
                case .mediaMessage:
                    if let bodyText: NSAttributedString = VisibleMessageCell.getBodyAttributedText(
                        for: messageViewModel,
                        theme: ThemeManager.currentTheme,
                        primaryColor: ThemeManager.primaryColor,
                        textColor: bodyLabelTextColor,
                        searchText: nil,
                        using: dependencies
                    ) {
                        AttributedText(bodyText)
                            .padding(.all, Self.inset)
                    }
                case .voiceMessage:
                    if let attachment: Attachment = messageViewModel.attachments?.first(where: { $0.isAudio }){
                        // TODO: Playback Info and check if playing function is needed
                        VoiceMessageView_SwiftUI(attachment: attachment)
                    }
                case .audio, .genericAttachment:
                    if let attachment: Attachment = messageViewModel.attachments?.first {
                        VStack(
                            alignment: .leading,
                            spacing: Values.smallSpacing
                        ) {
                            DocumentView_SwiftUI(
                                maxWidth: $maxWidth,
                                attachment: attachment,
                                textColor: bodyLabelTextColor
                            )
                            .modifier(MaxWidthEqualizer.notify)
                            .frame(
                                width: maxWidth,
                                alignment: .leading
                            )
                            
                            if let bodyText: NSAttributedString = VisibleMessageCell.getBodyAttributedText(
                                for: messageViewModel,
                                theme: ThemeManager.currentTheme,
                                primaryColor: ThemeManager.primaryColor,
                                textColor: bodyLabelTextColor,
                                searchText: nil,
                                using: dependencies
                            ) {
                                ZStack{
                                    AttributedText(bodyText)
                                        .padding(.horizontal, Self.inset)
                                        .padding(.bottom, Self.inset)
                                }
                                .modifier(MaxWidthEqualizer.notify)
                                .frame(
                                    width: maxWidth,
                                    alignment: .leading
                                )
                            }
                        }
                        .modifier(MaxWidthEqualizer(width: $maxWidth))
                    }
                default: EmptyView()
            }
        }
    }
}

struct InfoBlock<Content>: View where Content: View {
    let title: String
    let content: () -> Content
    
    private let minWidth: CGFloat = 100
    
    var body: some View {
        VStack(
            alignment: .leading,
            spacing: Values.verySmallSpacing
        ) {
            Text(self.title)
                .bold()
                .font(.system(size: Values.mediumLargeFontSize))
                .foregroundColor(themeColor: .textPrimary)
            self.content()
        }
        .frame(
            minWidth: minWidth,
            alignment: .leading
        )
    }
}

final class MessageInfoViewController: SessionHostingViewController<MessageInfoScreen> {
    init(
        actions: [ContextMenuVC.Action],
        messageViewModel: MessageViewModel,
        using dependencies: Dependencies
    ) {
        let messageInfoView = MessageInfoScreen(
            actions: actions,
            messageViewModel: messageViewModel,
            dependencies: dependencies
        )
        
        super.init(rootView: messageInfoView)
    }
    
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let customTitleFontSize = Values.largeFontSize
        setNavBarTitle("messageInfo".localized(), customFontSize: customTitleFontSize)
    }
}

struct MessageInfoView_Previews: PreviewProvider {
    static var messageViewModel: MessageViewModel {
        let dependencies: Dependencies = .createEmpty()
        let result = MessageViewModel(
            optimisticMessageId: UUID(),
            threadId: "d4f1g54sdf5g1d5f4g65ds4564df65f4g65d54gdfsg",
            threadVariant: .contact,
            threadExpirationType: nil,
            threadExpirationTimer: nil,
            threadOpenGroupServer: nil,
            threadOpenGroupPublicKey: nil,
            threadContactNameInternal: "Test",
            timestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs(),
            receivedAtTimestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs(),
            authorId: "d4f1g54sdf5g1d5f4g65ds4564df65f4g65d54gdfsg",
            authorNameInternal: "Test",
            body: "Mauris sapien dui, sagittis et fringilla eget, tincidunt vel mauris. Mauris bibendum quis ipsum ac pulvinar. Integer semper elit vitae placerat efficitur. Quisque blandit scelerisque orci, a fringilla dui. In a sollicitudin tortor. Vivamus consequat sollicitudin felis, nec pretium dolor bibendum sit amet. Integer non congue risus, id imperdiet diam. Proin elementum enim at felis commodo semper. Pellentesque magna magna, laoreet nec hendrerit in, suscipit sit amet risus. Nulla et imperdiet massa. Donec commodo felis quis arcu dignissim lobortis. Praesent nec fringilla felis, ut pharetra sapien. Donec ac dignissim nisi, non lobortis justo. Nulla congue velit nec sodales bibendum. Nullam feugiat, mauris ac consequat posuere, eros sem dignissim nulla, ac convallis dolor sem rhoncus dolor. Cras ut luctus risus, quis viverra mauris.",
            expiresStartedAtMs: nil,
            expiresInSeconds: nil,
            state: .failed,
            isSenderOpenGroupModerator: false,
            currentUserProfile: Profile.fetchOrCreateCurrentUser(using: dependencies),
            quote: nil,
            quoteAttachment: nil,
            linkPreview: nil,
            linkPreviewAttachment: nil,
            attachments: nil
        )
        
        return result
    }
    
    static var actions: [ContextMenuVC.Action] {
        return [
            .reply(messageViewModel, nil),
            .retry(messageViewModel, nil),
            .delete(messageViewModel, nil)
        ]
    }
    
    static var previews: some View {
        MessageInfoScreen(
            actions: actions,
            messageViewModel: messageViewModel,
            dependencies: Dependencies.createEmpty()
        )
    }
}
