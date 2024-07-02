// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SessionUIKit

extension ContextMenuVC {
    struct ExpirationInfo {
        let expiresStartedAtMs: Double?
        let expiresInSeconds: TimeInterval?
    }
    
    struct Action {
        let icon: UIImage?
        let title: String
        let expirationInfo: ExpirationInfo?
        let themeColor: ThemeValue
        let isEmojiAction: Bool
        let isEmojiPlus: Bool
        let isDismissAction: Bool
        let accessibilityLabel: String?
        let work: () -> Void
        
        // MARK: - Initialization
        
        init(
            icon: UIImage? = nil,
            title: String = "",
            expirationInfo: ExpirationInfo? = nil,
            themeColor: ThemeValue = .textPrimary,
            isEmojiAction: Bool = false,
            isEmojiPlus: Bool = false,
            isDismissAction: Bool = false,
            accessibilityLabel: String? = nil,
            work: @escaping () -> Void
        ) {
            self.icon = icon
            self.title = title
            self.expirationInfo = expirationInfo
            self.themeColor = themeColor
            self.isEmojiAction = isEmojiAction
            self.isEmojiPlus = isEmojiPlus
            self.isDismissAction = isDismissAction
            self.accessibilityLabel = accessibilityLabel
            self.work = work
        }
        
        // MARK: - Actions
        
        static func info(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?, using dependencies: Dependencies) -> Action {
            return Action(
                icon: UIImage(named: "ic_info"),
                title: "context_menu_info".localized(),
                accessibilityLabel: "Message info"
            ) { delegate?.info(cellViewModel, using: dependencies) }
        }

        static func retry(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?, using dependencies: Dependencies) -> Action {
            return Action(
                icon: UIImage(systemName: "arrow.triangle.2.circlepath"),
                title: (cellViewModel.state == .failedToSync ?
                    "context_menu_resync".localized() :
                    "context_menu_resend".localized()
                ),
                accessibilityLabel: (cellViewModel.state == .failedToSync ? "Resync message" : "Resend message")
            ) { delegate?.retry(cellViewModel, using: dependencies) }
        }

        static func reply(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?, using dependencies: Dependencies) -> Action {
            return Action(
                icon: UIImage(named: "ic_reply"),
                title: "context_menu_reply".localized(),
                accessibilityLabel: "Reply to message"
            ) { delegate?.reply(cellViewModel, using: dependencies) }
        }

        static func copy(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?, using dependencies: Dependencies) -> Action {
            return Action(
                icon: UIImage(named: "ic_copy"),
                title: "copy".localized(),
                accessibilityLabel: "Copy text"
            ) { delegate?.copy(cellViewModel, using: dependencies) }
        }

        static func copySessionID(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_copy"),
                title: "accountIDCopy".localized(),
                accessibilityLabel: "Copy Session ID"
                
            ) { delegate?.copySessionID(cellViewModel) }
        }

        static func delete(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?, using dependencies: Dependencies) -> Action {
            return Action(
                icon: UIImage(named: "ic_trash"),
                title: "TXT_DELETE_TITLE".localized(),
                expirationInfo: ExpirationInfo(
                    expiresStartedAtMs: cellViewModel.expiresStartedAtMs,
                    expiresInSeconds: cellViewModel.expiresInSeconds
                ),
                themeColor: .danger,
                accessibilityLabel: "Delete message"
            ) { delegate?.delete(cellViewModel, using: dependencies) }
        }

        static func save(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?, using dependencies: Dependencies) -> Action {
            return Action(
                icon: UIImage(named: "ic_download"),
                title: "context_menu_save".localized(),
                accessibilityLabel: "Save attachment"
            ) { delegate?.save(cellViewModel, using: dependencies) }
        }

        static func ban(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?, using dependencies: Dependencies) -> Action {
            return Action(
                icon: UIImage(named: "ic_block"),
                title: "context_menu_ban_user".localized(),
                themeColor: .danger,
                accessibilityLabel: "Ban user"
            ) { delegate?.ban(cellViewModel, using: dependencies) }
        }
        
        static func banAndDeleteAllMessages(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?, using dependencies: Dependencies) -> Action {
            return Action(
                icon: UIImage(named: "ic_block"),
                title: "context_menu_ban_and_delete_all".localized(),
                themeColor: .danger,
                accessibilityLabel: "Ban user and delete"
            ) { delegate?.banAndDeleteAllMessages(cellViewModel, using: dependencies) }
        }
        
        static func react(_ cellViewModel: MessageViewModel, _ emoji: EmojiWithSkinTones, _ delegate: ContextMenuActionDelegate?, using dependencies: Dependencies) -> Action {
            return Action(
                title: emoji.rawValue,
                isEmojiAction: true
            ) { delegate?.react(cellViewModel, with: emoji, using: dependencies) }
        }
        
        static func emojiPlusButton(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?, using dependencies: Dependencies) -> Action {
            return Action(
                isEmojiPlus: true,
                accessibilityLabel: "Add emoji"
            ) { delegate?.showFullEmojiKeyboard(cellViewModel, using: dependencies) }
        }
        
        static func dismiss(_ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                isDismissAction: true
            ) { delegate?.contextMenuDismissed() }
        }
    }
    
    static func viewModelCanReply(_ cellViewModel: MessageViewModel) -> Bool {
        return (
            cellViewModel.variant == .standardIncoming || (
                cellViewModel.variant == .standardOutgoing &&
                cellViewModel.state != .failed &&
                cellViewModel.state != .sending
            )
        )
    }

    static func actions(
        for cellViewModel: MessageViewModel,
        recentEmojis: [EmojiWithSkinTones],
        currentUserPublicKey: String,
        currentUserBlinded15PublicKey: String?,
        currentUserBlinded25PublicKey: String?,
        currentUserIsOpenGroupModerator: Bool,
        currentThreadIsMessageRequest: Bool,
        forMessageInfoScreen: Bool,
        delegate: ContextMenuActionDelegate?,
        using dependencies: Dependencies = Dependencies()
    ) -> [Action]? {
        switch cellViewModel.variant {
            case .standardIncomingDeleted, .infoCall,
                .infoScreenshotNotification, .infoMediaSavedNotification,
                .infoClosedGroupCreated, .infoClosedGroupUpdated,
                .infoClosedGroupCurrentUserLeft, .infoClosedGroupCurrentUserLeaving, .infoClosedGroupCurrentUserErrorLeaving,
                .infoMessageRequestAccepted, .infoDisappearingMessagesUpdate:
                // Let the user delete info messages and unsent messages
                return [ Action.delete(cellViewModel, delegate, using: dependencies) ]
                
            case .standardOutgoing, .standardIncoming: break
        }
        
        let canRetry: Bool = (
            cellViewModel.variant == .standardOutgoing && (
                cellViewModel.state == .failed || (
                    cellViewModel.threadVariant == .contact &&
                    cellViewModel.state == .failedToSync
                )
            )
        )
        let canCopy: Bool = (
            cellViewModel.cellType == .textOnlyMessage || (
                (
                    cellViewModel.cellType == .genericAttachment ||
                    cellViewModel.cellType == .mediaMessage
                ) &&
                (cellViewModel.attachments ?? []).count == 1 &&
                (cellViewModel.attachments ?? []).first?.isVisualMedia == true &&
                (cellViewModel.attachments ?? []).first?.isValid == true && (
                    (cellViewModel.attachments ?? []).first?.state == .downloaded ||
                    (cellViewModel.attachments ?? []).first?.state == .uploaded
                )
            )
        )
        let canSave: Bool = (
            cellViewModel.cellType == .mediaMessage &&
            (cellViewModel.attachments ?? [])
                .filter { attachment in
                    attachment.isValid &&
                    attachment.isVisualMedia && (
                        attachment.state == .downloaded ||
                        attachment.state == .uploaded
                    )
                }.isEmpty == false
        )
        let canCopySessionId: Bool = (
            cellViewModel.variant == .standardIncoming &&
            cellViewModel.threadVariant != .community
        )
        let canDelete: Bool = (
            cellViewModel.threadVariant != .community ||
            currentUserIsOpenGroupModerator ||
            cellViewModel.authorId == currentUserPublicKey ||
            cellViewModel.authorId == currentUserBlinded15PublicKey ||
            cellViewModel.authorId == currentUserBlinded25PublicKey ||
            cellViewModel.state == .failed
        )
        let canBan: Bool = (
            cellViewModel.threadVariant == .community &&
            currentUserIsOpenGroupModerator
        )
        
        let shouldShowEmojiActions: Bool = {
            if cellViewModel.threadVariant == .community {
                return OpenGroupManager.doesOpenGroupSupport(
                    capability: .reactions,
                    on: cellViewModel.threadOpenGroupServer
                )
            }
            return !currentThreadIsMessageRequest && !forMessageInfoScreen
        }()
        
        let generatedActions: [Action] = [
            (canRetry ? Action.retry(cellViewModel, delegate, using: dependencies) : nil),
            (viewModelCanReply(cellViewModel) ? Action.reply(cellViewModel, delegate, using: dependencies) : nil),
            (canCopy ? Action.copy(cellViewModel, delegate, using: dependencies) : nil),
            (canSave ? Action.save(cellViewModel, delegate, using: dependencies) : nil),
            (canCopySessionId ? Action.copySessionID(cellViewModel, delegate) : nil),
            (canDelete ? Action.delete(cellViewModel, delegate, using: dependencies) : nil),
            (canBan ? Action.ban(cellViewModel, delegate, using: dependencies) : nil),
            (canBan ? Action.banAndDeleteAllMessages(cellViewModel, delegate, using: dependencies) : nil),
            (forMessageInfoScreen ? nil : Action.info(cellViewModel, delegate, using: dependencies)),
        ]
        .appending(
            contentsOf: (shouldShowEmojiActions ? recentEmojis : [])
                .map { Action.react(cellViewModel, $0, delegate, using: dependencies) }
        )
        .appending(forMessageInfoScreen ? nil : Action.emojiPlusButton(cellViewModel, delegate, using: dependencies))
        .compactMap { $0 }
        
        guard !generatedActions.isEmpty else { return [] }
        
        return generatedActions.appending(forMessageInfoScreen ? nil : Action.dismiss(delegate))
    }
}

// MARK: - Delegate

protocol ContextMenuActionDelegate {
    func info(_ cellViewModel: MessageViewModel, using dependencies: Dependencies)
    func retry(_ cellViewModel: MessageViewModel, using dependencies: Dependencies)
    func reply(_ cellViewModel: MessageViewModel, using dependencies: Dependencies)
    func copy(_ cellViewModel: MessageViewModel, using dependencies: Dependencies)
    func copySessionID(_ cellViewModel: MessageViewModel)
    func delete(_ cellViewModel: MessageViewModel, using dependencies: Dependencies)
    func save(_ cellViewModel: MessageViewModel, using dependencies: Dependencies)
    func ban(_ cellViewModel: MessageViewModel, using dependencies: Dependencies)
    func banAndDeleteAllMessages(_ cellViewModel: MessageViewModel, using dependencies: Dependencies)
    func react(_ cellViewModel: MessageViewModel, with emoji: EmojiWithSkinTones, using dependencies: Dependencies)
    func showFullEmojiKeyboard(_ cellViewModel: MessageViewModel, using dependencies: Dependencies)
    func contextMenuDismissed()
}
