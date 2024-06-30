// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit
import SessionMessagingKit

struct MessageInfoView: View {
    @Environment(\.viewController) private var viewControllerHolder: UIViewController?
    
    @State var index = 1
    @State var showingAttachmentFullScreen = false
    
    var actions: [ContextMenuVC.Action]
    var messageViewModel: MessageViewModel
    var isMessageFailed: Bool {
        return [.failed, .failedToSync].contains(messageViewModel.state)
    }
    
    var dismiss: (() -> Void)?
    
    var body: some View {
        NavigationView {
            ZStack (alignment: .topLeading) {
                if #available(iOS 14.0, *) {
                    ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
                } else {
                    ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary)
                }
                
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(
                        alignment: .leading,
                        spacing: 10
                    ) {
                        // Message bubble snapshot
                        if let body: String = messageViewModel.body, !body.isEmpty {
                            let (bubbleBackgroundColor, bubbleTextColor): (ThemeValue, ThemeValue) = (
                                messageViewModel.variant == .standardIncoming ||
                                messageViewModel.variant == .standardIncomingDeleted
                            ) ?
                            (.messageBubble_incomingBackground, .messageBubble_incomingText) :
                            (.messageBubble_outgoingBackground, .messageBubble_outgoingText)
                            
                            ZStack {
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(themeColor: bubbleBackgroundColor)
                                
                                Text(body)
                                    .foregroundColor(themeColor: bubbleTextColor)
                                    .padding(
                                        EdgeInsets(
                                            top: 8,
                                            leading: 16,
                                            bottom: 8,
                                            trailing: 16
                                        )
                                    )
                            }
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .topLeading
                            )
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(
                                EdgeInsets(
                                    top: 8,
                                    leading: 30,
                                    bottom: 4,
                                    trailing: 30
                                )
                            )
                        }
                        
                        if isMessageFailed {
                            let (image, statusText, tintColor) = messageViewModel.state.statusIconInfo(
                                variant: messageViewModel.variant,
                                hasAtLeastOneReadReceipt: messageViewModel.hasAtLeastOneReadReceipt
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
                                        .font(.system(size: 11))
                                        .foregroundColor(themeColor: tintColor)
                                }
                            }
                            .padding(
                                EdgeInsets(
                                    top: -8,
                                    leading: 30,
                                    bottom: 4,
                                    trailing: 30
                                )
                            )
                        }
                        
                        if let attachments = messageViewModel.attachments {
                            let attachment: Attachment = attachments[(index - 1 + attachments.count) % attachments.count]
                            
                            ZStack(alignment: .bottomTrailing) {
                                if attachments.count > 1 {
                                    // Attachment carousel view
                                    SessionCarouselView_SwiftUI(
                                        index: $index,
                                        isOutgoing: (messageViewModel.variant == .standardOutgoing),
                                        contentInfos: attachments
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
                                        cornerRadius: 0
                                    )
                                    .frame(
                                        maxWidth: .infinity,
                                        maxHeight: .infinity,
                                        alignment: .topLeading
                                    )
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 15))
                                    .padding(
                                        EdgeInsets(
                                            top: 0,
                                            leading: 30,
                                            bottom: 0,
                                            trailing: 30
                                        )
                                    )
                                }
                                
                                Button {
                                    self.viewControllerHolder?.present(style: .fullScreen) {
                                        MediaGalleryViewModel.createDetailViewSwiftUI(
                                            for: messageViewModel.threadId,
                                            threadVariant: messageViewModel.threadVariant,
                                            interactionId: messageViewModel.id,
                                            selectedAttachmentId: attachment.id,
                                            options: [ .sliderEnabled ]
                                        )
                                    }
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
                                .padding(
                                    EdgeInsets(
                                        top: 0,
                                        leading: 0,
                                        bottom: 8,
                                        trailing: 38
                                    )
                                )
                            }
                            .padding(
                                EdgeInsets(
                                    top: 4,
                                    leading: 0,
                                    bottom: 4,
                                    trailing: 0
                                )
                            )
                            
                            // Attachment Info
                            ZStack {
                                RoundedRectangle(cornerRadius: 17)
                                    .fill(themeColor: .backgroundSecondary)
                                    
                                VStack(
                                    alignment: .leading,
                                    spacing: 16
                                ) {
                                    InfoBlock(title: "attachmentsFileId".localized()) {
                                        Text(attachment.serverId ?? "")
                                            .font(.system(size: 16))
                                            .foregroundColor(themeColor: .textPrimary)
                                    }
                                    
                                    HStack(
                                        alignment: .center
                                    ) {
                                        InfoBlock(title: "attachmentsFileType".localized()) {
                                            Text(attachment.contentType)
                                                .font(.system(size: 16))
                                                .foregroundColor(themeColor: .textPrimary)
                                        }
                                        
                                        Spacer()
                                        
                                        InfoBlock(title: "attachmentsFileSize".localized()) {
                                            Text(Format.fileSize(attachment.byteCount))
                                                .font(.system(size: 16))
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
                                                .font(.system(size: 16))
                                                .foregroundColor(themeColor: .textPrimary)
                                        }
                                        
                                        Spacer()
                                        
                                        let duration: String = {
                                            guard let duration = attachment.duration else { return "attachmentsNa".localized() }
                                            return floor(duration).formatted(format: .videoDuration)
                                        }()
                                        InfoBlock(title: "attachmentsDuration".localized()) {
                                            Text(duration)
                                                .font(.system(size: 16))
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
                                .padding(
                                    EdgeInsets(
                                        top: 24,
                                        leading: 24,
                                        bottom: 24,
                                        trailing: 24
                                    )
                                )
                            }
                            .frame(maxHeight: .infinity)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(
                                EdgeInsets(
                                    top: 4,
                                    leading: 30,
                                    bottom: 4,
                                    trailing: 30
                                )
                            )
                        }

                        // Message Info
                        ZStack {
                            RoundedRectangle(cornerRadius: 17)
                                .fill(themeColor: .backgroundSecondary)
                                
                            VStack(
                                alignment: .leading,
                                spacing: 16
                            ) {
                                InfoBlock(title: "sent".localized()) {
                                    Text(messageViewModel.dateForUI.fromattedForMessageInfo)
                                        .font(.system(size: 16))
                                        .foregroundColor(themeColor: .textPrimary)
                                }
                                
                                InfoBlock(title: "received".localized()) {
                                    Text(messageViewModel.receivedDateForUI.fromattedForMessageInfo)
                                        .font(.system(size: 16))
                                        .foregroundColor(themeColor: .textPrimary)
                                }
                                
                                if isMessageFailed {
                                    let failureText: String = messageViewModel.mostRecentFailureText ?? "Message failed to send"
                                    InfoBlock(title: "theError".localized() + ":") {
                                        Text(failureText)
                                            .font(.system(size: 16))
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
                                            customImageData: nil,
                                            profile: messageViewModel.profile,
                                            profileIcon: (messageViewModel.isSenderOpenGroupModerator ? .crown : .none)
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
                                            spacing: 4
                                        ) {
                                            if !messageViewModel.authorName.isEmpty  {
                                                Text(messageViewModel.authorName)
                                                    .bold()
                                                    .font(.system(size: 18))
                                                    .foregroundColor(themeColor: .textPrimary)
                                            }
                                            Text(messageViewModel.authorId)
                                                .font(.spaceMono(size: 16))
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
                            .padding(
                                EdgeInsets(
                                    top: 24,
                                    leading: 24,
                                    bottom: 24,
                                    trailing: 24
                                )
                            )
                        }
                        .frame(maxHeight: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(
                            EdgeInsets(
                                top: 4,
                                leading: 30,
                                bottom: 4,
                                trailing: 30
                            )
                        )

                        // Actions
                        if !actions.isEmpty {
                            ZStack {
                                RoundedRectangle(cornerRadius: 17)
                                    .fill(themeColor: .backgroundSecondary)
                                
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
                                                dismiss?()
                                            },
                                            label: {
                                                HStack(spacing: 24) {
                                                    Image(uiImage: actions[index].icon!.withRenderingMode(.alwaysTemplate))
                                                        .resizable()
                                                        .scaledToFit()
                                                        .foregroundColor(themeColor: tintColor)
                                                        .frame(width: 26, height: 26)
                                                    Text(actions[index].title)
                                                        .bold()
                                                        .font(.system(size: 18))
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
                                .padding(
                                    EdgeInsets(
                                        top: 0,
                                        leading: 24,
                                        bottom: 0,
                                        trailing: 24
                                    )
                                )
                            }
                            .frame(maxHeight: .infinity)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(
                                EdgeInsets(
                                    top: 4,
                                    leading: 30,
                                    bottom: 4,
                                    trailing: 30
                                )
                            )
                        }
                    }
                }
            }
        }
    }
}

struct InfoBlock<Content>: View where Content: View {
    let title: String
    let content: () -> Content
    
    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 4
        ) {
            Text(self.title)
                .bold()
                .font(.system(size: 18))
                .foregroundColor(themeColor: .textPrimary)
            self.content()
        }
        .frame(
            minWidth: 100,
            alignment: .leading
        )
    }
}

final class MessageInfoViewController: SessionHostingViewController<MessageInfoView> {
    init(actions: [ContextMenuVC.Action], messageViewModel: MessageViewModel) {
        let messageInfoView = MessageInfoView(
            actions: actions,
            messageViewModel: messageViewModel
        )
        
        super.init(rootView: messageInfoView)
        rootView.content.dismiss = dismiss
    }
    
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let customTitleFontSize = Values.largeFontSize
        setNavBarTitle("messageInfo".localized(), customFontSize: customTitleFontSize)
    }
    
    func dismiss() {
        self.navigationController?.popViewController(animated: true)
    }
}

struct MessageInfoView_Previews: PreviewProvider {
    static var messageViewModel: MessageViewModel {
        let result = MessageViewModel(
            optimisticMessageId: UUID(),
            threadId: "d4f1g54sdf5g1d5f4g65ds4564df65f4g65d54gdfsg",
            threadVariant: .contact,
            threadExpirationType: nil,
            threadExpirationTimer: nil,
            threadOpenGroupServer: nil,
            threadOpenGroupPublicKey: nil,
            threadContactNameInternal: "Test",
            timestampMs: SnodeAPI.currentOffsetTimestampMs(),
            receivedAtTimestampMs: SnodeAPI.currentOffsetTimestampMs(),
            authorId: "d4f1g54sdf5g1d5f4g65ds4564df65f4g65d54gdfsg",
            authorNameInternal: "Test",
            body: "Test Message",
            expiresStartedAtMs: nil,
            expiresInSeconds: nil,
            state: .failed,
            isSenderOpenGroupModerator: false,
            currentUserProfile: Profile.fetchOrCreateCurrentUser(),
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
            .reply(messageViewModel, nil, using: Dependencies()),
            .retry(messageViewModel, nil, using: Dependencies()),
            .delete(messageViewModel, nil, using: Dependencies())
        ]
    }
    
    static var previews: some View {
        MessageInfoView(
            actions: actions,
            messageViewModel: messageViewModel
        )
    }
}
