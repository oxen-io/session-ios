// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import YYImage
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit
import SessionSnodeKit

class ThreadSettingsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private let threadId: String
    private let threadVariant: SessionThread.Variant
    private let didTriggerSearch: () -> ()
    private var updatedName: String?
    private var updatedDescription: String?
    private var onDisplayPictureSelected: ((ConfirmationModal.ValueUpdate) -> Void)?
    private lazy var imagePickerHandler: ImagePickerHandler = ImagePickerHandler(
        onTransition: { [weak self] in self?.transitionToScreen($0, transitionType: $1) },
        onImageDataPicked: { [weak self] resultImageData in
            self?.onDisplayPictureSelected?(.image(resultImageData))
        }
    )
    
    // MARK: - Initialization
    
    init(
        threadId: String,
        threadVariant: SessionThread.Variant,
        didTriggerSearch: @escaping () -> (),
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.threadVariant = threadVariant
        self.didTriggerSearch = didTriggerSearch
    }
    
    // MARK: - Config
    
    enum NavState {
        case standard
        case editing
    }
    
    enum NavItem: Equatable {
        case edit
        case cancel
        case done
    }
    
    public enum Section: SessionTableSection {
        case conversationInfo
        case content
        case adminActions
        case destructiveActions
        
        public var style: SessionTableSectionStyle {
            switch self {
                case .destructiveActions: return .padding
                default: return .none
            }
        }
    }
    
    public enum TableItem: Differentiable {
        case avatar
        case displayName
        case threadDescription
        case sessionId
        
        case copyThreadId
        case allMedia
        case searchConversation
        case addToOpenGroup
        case disappearingMessages
        case disappearingMessagesDuration
        case groupMembers
        case editGroup
        case promoteAdmins
        case leaveGroup
        case notificationMentionsOnly
        case notificationMute
        case blockUser
        
        case debugDeleteBeforeNow
        case debugDeleteAttachmentsBeforeNow
    }
    
    // MARK: - Content
    
    private struct State: Equatable {
        let threadViewModel: SessionThreadViewModel?
        let disappearingMessagesConfig: DisappearingMessagesConfiguration
    }
    
    var title: String {
        switch threadVariant {
            case .contact: return "sessionSettings".localized()
            case .legacyGroup, .group, .community: return "deleteAfterGroupPR1GroupSettings".localized()
        }
    }
    
    lazy var observation: TargetObservation = ObservationBuilder
        .databaseObservation(self) { [dependencies, threadId = self.threadId] db -> State in
            let userSessionId: SessionId = dependencies[cache: .general].sessionId
            let threadViewModel: SessionThreadViewModel? = try SessionThreadViewModel
                .conversationSettingsQuery(threadId: threadId, userSessionId: userSessionId)
                .fetchOne(db)
            let disappearingMessagesConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
                .fetchOne(db, id: threadId)
                .defaulting(to: DisappearingMessagesConfiguration.defaultWith(threadId))
            
            return State(
                threadViewModel: threadViewModel,
                disappearingMessagesConfig: disappearingMessagesConfig
            )
        }
        .compactMapWithPrevious { [weak self] prev, current -> [SectionModel]? in self?.content(prev, current) }
    
    private func content(_ previous: State?, _ current: State) -> [SectionModel] {
        // If we don't get a `SessionThreadViewModel` then it means the thread was probably deleted
        // so dismiss the screen
        guard let threadViewModel: SessionThreadViewModel = current.threadViewModel else {
            self.dismissScreen(type: .popToRoot)
            return []
        }
        
        let currentUserIsClosedGroupMember: Bool = (
            (
                threadViewModel.threadVariant == .legacyGroup ||
                threadViewModel.threadVariant == .group
            ) &&
            threadViewModel.currentUserIsClosedGroupMember == true
        )
        let currentUserIsClosedGroupAdmin: Bool = (
            (
                threadViewModel.threadVariant == .legacyGroup ||
                threadViewModel.threadVariant == .group
            ) &&
            threadViewModel.currentUserIsClosedGroupAdmin == true
        )
        let editIcon: UIImage? = UIImage(systemName: "pencil")
        let canEditDisplayName: Bool = (
            threadViewModel.threadIsNoteToSelf != true && (
                threadViewModel.threadVariant == .contact ||
                currentUserIsClosedGroupAdmin
            )
        )
        
        let conversationInfoSection: SectionModel = SectionModel(
            model: .conversationInfo,
            elements: [
                SessionCell.Info(
                    id: .avatar,
                    accessory: .profile(
                        id: threadViewModel.id,
                        size: .hero,
                        threadVariant: threadViewModel.threadVariant,
                        displayPictureFilename: threadViewModel.displayPictureFilename,
                        profile: threadViewModel.profile,
                        profileIcon: {
                            guard
                                threadViewModel.threadVariant == .group &&
                                currentUserIsClosedGroupAdmin &&
                                dependencies[feature: .updatedGroupsAllowDisplayPicture]
                            else { return .none }
                            
                            // If we already have a display picture then the main profile gets the icon
                            return (threadViewModel.displayPictureFilename != nil ? .rightPlus : .none)
                        }(),
                        additionalProfile: threadViewModel.additionalProfile,
                        additionalProfileIcon: {
                            guard
                                threadViewModel.threadVariant == .group &&
                                currentUserIsClosedGroupAdmin &&
                                dependencies[feature: .updatedGroupsAllowDisplayPicture]
                            else { return .none }
                            
                            // No display picture means the dual-profile so the additionalProfile gets the icon
                            return .rightPlus
                        }(),
                        accessibility: nil
                    ),
                    styling: SessionCell.StyleInfo(
                        alignment: .centerHugging,
                        customPadding: SessionCell.Padding(bottom: Values.smallSpacing),
                        backgroundStyle: .noBackground
                    ),
                    onTap: { [weak self] in
                        switch (threadViewModel.threadVariant, threadViewModel.displayPictureFilename, currentUserIsClosedGroupAdmin) {
                            case (.contact, _, _): self?.viewDisplayPicture(threadViewModel: threadViewModel)
                            case (.group, _, true):
                                self?.updateGroupDisplayPicture(currentFileName: threadViewModel.displayPictureFilename)
                            
                            case (_, .some, _): self?.viewDisplayPicture(threadViewModel: threadViewModel)
                            default: break
                        }
                        
                    }
                ),
                SessionCell.Info(
                    id: .displayName,
                    leadingAccessory: (!canEditDisplayName ? nil :
                        .icon(
                            editIcon?.withRenderingMode(.alwaysTemplate),
                            size: .mediumAspectFill,
                            customTint: .textSecondary,
                            shouldFill: true
                        )
                    ),
                    title: SessionCell.TextInfo(
                        threadViewModel.displayName,
                        font: .titleLarge,
                        alignment: .center
                    ),
                    styling: SessionCell.StyleInfo(
                        alignment: .centerHugging,
                        customPadding: SessionCell.Padding(
                            top: Values.smallSpacing,
                            leading: (!canEditDisplayName ? nil :
                                -((IconSize.medium.size + (Values.smallSpacing * 2)) / 2)
                            ),
                            bottom: {
                                guard threadViewModel.threadVariant != .contact else { return Values.smallSpacing }
                                guard threadViewModel.threadDescription == nil else { return Values.smallSpacing }
                                
                                return Values.largeSpacing
                            }()
                        ),
                        backgroundStyle: .noBackground
                    ),
                    accessibility: Accessibility(
                        identifier: "Username",
                        label: threadViewModel.displayName
                    ),
                    onTap: { [weak self] in
                        guard !threadViewModel.threadIsNoteToSelf else { return }
                        
                        switch (threadViewModel.threadVariant, currentUserIsClosedGroupAdmin) {
                            case (.contact, _):
                                self?.updateNickname(
                                    current: threadViewModel.profile?.nickname,
                                    displayName: (
                                        /// **Note:** We want to use the `profile` directly rather than `threadViewModel.displayName`
                                        /// as the latter would use the `nickname` here which is incorrect
                                        threadViewModel.profile?.displayName(ignoringNickname: true) ??
                                        Profile.truncated(id: threadViewModel.threadId, truncating: .middle)
                                    )
                                )
                            
                            case (.group, true), (.legacyGroup, true):
                                self?.updateGroupNameAndDescription(
                                    currentName: threadViewModel.displayName,
                                    currentDescription: threadViewModel.threadDescription,
                                    isUpdatedGroup: (threadViewModel.threadVariant == .group)
                                )
                            
                            case (.community, _), (.legacyGroup, false), (.group, false): break
                        }
                    }
                ),
                
                threadViewModel.threadDescription.map { threadDescription in
                    SessionCell.Info(
                        id: .threadDescription,
                        subtitle: SessionCell.TextInfo(
                            threadDescription,
                            font: .subtitle,
                            alignment: .center
                        ),
                        styling: SessionCell.StyleInfo(
                            tintColor: .textSecondary,
                            customPadding: SessionCell.Padding(
                                top: 0,
                                bottom: (threadViewModel.threadVariant != .contact ? Values.largeSpacing : nil)
                            ),
                            backgroundStyle: .noBackground
                        ),
                        accessibility: Accessibility(
                            identifier: "Description",
                            label: threadDescription
                        )
                    )
                },

                (threadViewModel.threadVariant != .contact ? nil :
                    SessionCell.Info(
                        id: .sessionId,
                        subtitle: SessionCell.TextInfo(
                            threadViewModel.id,
                            font: .monoSmall,
                            alignment: .center,
                            interaction: .copy
                        ),
                        styling: SessionCell.StyleInfo(
                            customPadding: SessionCell.Padding(
                                top: Values.smallSpacing,
                                bottom: Values.largeSpacing
                            ),
                            backgroundStyle: .noBackground
                        ),
                        accessibility: Accessibility(
                            identifier: "Session ID",
                            label: threadViewModel.id
                        )
                    )
                )
            ].compactMap { $0 }
        )
        let standardActionsSection: SectionModel = SectionModel(
            model: .content,
            elements: [
                (threadViewModel.threadVariant == .legacyGroup || threadViewModel.threadVariant == .group ? nil :
                    SessionCell.Info(
                        id: .copyThreadId,
                        leadingAccessory: .icon(
                            UIImage(named: "ic_copy")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: (threadViewModel.threadVariant == .community ?
                            "communityUrlCopy".localized() :
                            "accountIDCopy".localized()
                        ),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).copy_thread_id",
                            label: "Copy Session ID"
                        ),
                        onTap: { [weak self] in
                            switch threadViewModel.threadVariant {
                                case .contact, .legacyGroup, .group:
                                    UIPasteboard.general.string = threadViewModel.threadId

                                case .community:
                                    guard
                                        let urlString: String = LibSession.communityUrlFor(
                                            server: threadViewModel.openGroupServer,
                                            roomToken: threadViewModel.openGroupRoomToken,
                                            publicKey: threadViewModel.openGroupPublicKey
                                        )
                                    else { return }

                                    UIPasteboard.general.string = urlString
                            }

                            self?.showToast(
                                text: "copied".localized(),
                                backgroundColor: .backgroundSecondary
                            )
                        }
                    )
                ),

                SessionCell.Info(
                    id: .allMedia,
                    leadingAccessory: .icon(
                        UIImage(named: "actionsheet_camera_roll_black")?
                            .withRenderingMode(.alwaysTemplate)
                    ),
                    title: "conversationsSettingsAllMedia".localized(),
                    accessibility: Accessibility(
                        identifier: "\(ThreadSettingsViewModel.self).all_media",
                        label: "All media"
                    ),
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
                            MediaGalleryViewModel.createAllMediaViewController(
                                threadId: threadViewModel.threadId,
                                threadVariant: threadViewModel.threadVariant,
                                focusedAttachmentId: nil,
                                using: dependencies
                            )
                        )
                    }
                ),

                SessionCell.Info(
                    id: .searchConversation,
                    leadingAccessory: .icon(
                        UIImage(named: "conversation_settings_search")?
                            .withRenderingMode(.alwaysTemplate)
                    ),
                    title: "searchConversation".localized(),
                    accessibility: Accessibility(
                        identifier: "\(ThreadSettingsViewModel.self).search",
                        label: "Search"
                    ),
                    onTap: { [weak self] in self?.didTriggerSearch() }
                ),

                (threadViewModel.threadVariant != .community ? nil :
                    SessionCell.Info(
                        id: .addToOpenGroup,
                        leadingAccessory: .icon(
                            UIImage(named: "ic_plus_24")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "membersInvite".localized(),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).add_to_open_group"
                        ),
                        onTap: { [weak self] in self?.inviteUsersToCommunity(threadViewModel: threadViewModel) }
                    )
                ),

                (threadViewModel.threadVariant == .community || threadViewModel.threadIsBlocked == true ? nil :
                    SessionCell.Info(
                        id: .disappearingMessages,
                        leadingAccessory: .icon(
                            UIImage(systemName: "timer")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "disappearingMessages".localized(),
                        subtitle: {
                            guard current.disappearingMessagesConfig.isEnabled else {
                                return "off".localized()
                            }
                            
                            return (current.disappearingMessagesConfig.type ?? .unknown)
                                .localizedState(
                                    durationString: current.disappearingMessagesConfig.durationString
                                )
                        }(),
                        accessibility: Accessibility(
                            identifier: "Disappearing messages",
                            label: "\(ThreadSettingsViewModel.self).disappearing_messages"
                        ),
                        onTap: { [weak self, dependencies] in
                            self?.transitionToScreen(
                                SessionTableViewController(
                                    viewModel: ThreadDisappearingMessagesSettingsViewModel(
                                        threadId: threadViewModel.threadId,
                                        threadVariant: threadViewModel.threadVariant,
                                        currentUserIsClosedGroupMember: threadViewModel.currentUserIsClosedGroupMember,
                                        currentUserIsClosedGroupAdmin: threadViewModel.currentUserIsClosedGroupAdmin,
                                        config: current.disappearingMessagesConfig,
                                        using: dependencies
                                    )
                                )
                            )
                        }
                    )
                ),

                (!currentUserIsClosedGroupMember ? nil :
                    SessionCell.Info(
                        id: .groupMembers,
                        leadingAccessory: .icon(
                            UIImage(named: "icon_members")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "groupMembers".localized(),
                        accessibility: Accessibility(
                            identifier: "Group members",
                            label: "Group members"
                        ),
                        onTap: { [weak self] in self?.viewMembers() }
                    )
                ),

                (!currentUserIsClosedGroupAdmin ? nil :
                    SessionCell.Info(
                        id: .editGroup,
                        leadingAccessory: .icon(
                            UIImage(named: "table_ic_group_edit")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "groupEdit".localized(),
                        accessibility: Accessibility(
                            identifier: "Edit group",
                            label: "Edit group"
                        ),
                        onTap: { [weak self, dependencies] in
                            self?.transitionToScreen(
                                SessionTableViewController(
                                    viewModel: EditGroupViewModel(
                                        threadId: threadViewModel.threadId,
                                        using: dependencies
                                    )
                                )
                            )
                        }
                    )
                ),
                
                (!currentUserIsClosedGroupAdmin || !dependencies[feature: .updatedGroupsAllowPromotions] ? nil :
                    SessionCell.Info(
                        id: .promoteAdmins,
                        leadingAccessory: .icon(
                            UIImage(named: "table_ic_group_edit")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "adminPromote".localized(),
                        accessibility: Accessibility(
                            identifier: "Promote admins",
                            label: "Promote admins"
                        ),
                        onTap: { [weak self] in self?.promoteAdmins() }
                    )
                ),

                (!currentUserIsClosedGroupMember ? nil :
                    SessionCell.Info(
                        id: .leaveGroup,
                        leadingAccessory: .icon(
                            UIImage(named: "table_ic_group_leave")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "groupLeave".localized(),
                        accessibility: Accessibility(
                            identifier: "Leave group",
                            label: "Leave group"
                        ),
                        confirmationInfo: ConfirmationModal.Info(
                            title: "groupLeave".localized(),
                            body: (currentUserIsClosedGroupAdmin ?
                                .attributedText(
                                    "groupLeaveDescriptionAdmin"
                                        .put(key: "group_name", value: threadViewModel.displayName)
                                        .localizedFormatted(baseFont: .boldSystemFont(ofSize: Values.smallFontSize))
                                ) :
                                .attributedText(
                                    "groupLeaveDescription"
                                        .put(key: "group_name", value: threadViewModel.displayName)
                                        .localizedFormatted(baseFont: .boldSystemFont(ofSize: Values.smallFontSize))
                                )
                            ),
                            confirmTitle: "leave".localized(),
                            confirmStyle: .danger,
                            cancelStyle: .alert_text
                        ),
                        onTap: { [dependencies] in
                            dependencies[singleton: .storage].write { db in
                                try SessionThread.deleteOrLeave(
                                    db,
                                    type: .leaveGroupAsync,
                                    threadId: threadViewModel.threadId,
                                    threadVariant: threadViewModel.threadVariant,
                                    calledFromConfig: nil,
                                    using: dependencies
                                )
                            }
                        }
                    )
                ),
                
                (threadViewModel.threadVariant == .contact ? nil :
                    SessionCell.Info(
                        id: .notificationMentionsOnly,
                        leadingAccessory: .icon(
                            UIImage(named: "NotifyMentions")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "deleteAfterGroupPR1MentionsOnly".localized(),
                        subtitle: "deleteAfterGroupPR1MentionsOnlyDescription".localized(),
                            trailingAccessory: .toggle(
                                threadViewModel.threadOnlyNotifyForMentions == true,
                                oldValue: (previous?.threadViewModel?.threadOnlyNotifyForMentions == true),
                            accessibility: Accessibility(
                                identifier: "Notify for Mentions Only - Switch"
                            )
                        ),
                        isEnabled: (
                            (
                                threadViewModel.threadVariant != .legacyGroup &&
                                threadViewModel.threadVariant != .group
                            ) ||
                            currentUserIsClosedGroupMember
                        ),
                        accessibility: Accessibility(
                            identifier: "Mentions only notification setting",
                            label: "Mentions only"
                        ),
                        onTap: { [dependencies] in
                            let newValue: Bool = !(threadViewModel.threadOnlyNotifyForMentions == true)
                            
                            dependencies[singleton: .storage].writeAsync { db in
                                try SessionThread
                                    .filter(id: threadViewModel.threadId)
                                    .updateAll(
                                        db,
                                        SessionThread.Columns.onlyNotifyForMentions
                                            .set(to: newValue)
                                    )
                            }
                        }
                    )
                ),
                
                (threadViewModel.threadIsNoteToSelf ? nil :
                    SessionCell.Info(
                        id: .notificationMute,
                        leadingAccessory: .icon(
                            UIImage(named: "Mute")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "notificationsMute".localized(),
                        trailingAccessory: .toggle(
                            threadViewModel.threadMutedUntilTimestamp != nil,
                            oldValue: (previous?.threadViewModel?.threadMutedUntilTimestamp != nil),
                            accessibility: Accessibility(
                                identifier: "Mute - Switch"
                            )
                        ),
                        isEnabled: (
                            (
                                threadViewModel.threadVariant != .legacyGroup &&
                                threadViewModel.threadVariant != .group
                            ) ||
                            currentUserIsClosedGroupMember
                        ),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).mute",
                            label: "Mute notifications"
                        ),
                        onTap: { [dependencies] in
                            dependencies[singleton: .storage].writeAsync { db in
                                let currentValue: TimeInterval? = try SessionThread
                                    .filter(id: threadViewModel.threadId)
                                    .select(.mutedUntilTimestamp)
                                    .asRequest(of: TimeInterval.self)
                                    .fetchOne(db)
                                
                                try SessionThread
                                    .filter(id: threadViewModel.threadId)
                                    .updateAll(
                                        db,
                                        SessionThread.Columns.mutedUntilTimestamp.set(
                                            to: (currentValue == nil ?
                                                Date.distantFuture.timeIntervalSince1970 :
                                                nil
                                            )
                                        )
                                    )
                            }
                        }
                    )
                ),
                
                (threadViewModel.threadIsNoteToSelf || threadViewModel.threadVariant != .contact ? nil :
                    SessionCell.Info(
                        id: .blockUser,
                        leadingAccessory: .icon(
                            UIImage(named: "table_ic_block")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "deleteAfterGroupPR1BlockThisUser".localized(),
                            trailingAccessory: .toggle(
                            threadViewModel.threadIsBlocked == true,
                            oldValue: (previous?.threadViewModel?.threadIsBlocked == true),
                            accessibility: Accessibility(
                                identifier: "Block This User - Switch"
                            )
                        ),
                        accessibility: Accessibility(
                            identifier: "\(ThreadSettingsViewModel.self).block",
                            label: "Block"
                        ),
                        confirmationInfo: ConfirmationModal.Info(
                            title: {
                                guard threadViewModel.threadIsBlocked == true else {
                                    return String(
                                        format: "block".localized(),
                                        threadViewModel.displayName
                                    )
                                }
                                
                                return String(
                                    format: "blockUnblock".localized(),
                                    threadViewModel.displayName
                                )
                            }(),
                            body: (threadViewModel.threadIsBlocked == true ?
                                .attributedText(
                                    "blockUnblockName"
                                        .put(key: "name", value: threadViewModel.displayName)
                                        .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize))
                                ) :
                                .attributedText(
                                    "blockDescription"
                                        .put(key: "name", value: threadViewModel.displayName)
                                        .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize))
                                )
                            ),
                            confirmTitle: (threadViewModel.threadIsBlocked == true ?
                                "blockUnblock".localized() :
                                "block".localized()
                            ),
                            confirmStyle: .danger,
                            cancelStyle: .alert_text
                        ),
                        onTap: { [weak self] in
                            let isBlocked: Bool = (threadViewModel.threadIsBlocked == true)
                            
                            self?.updateBlockedState(
                                from: isBlocked,
                                isBlocked: !isBlocked,
                                threadId: threadViewModel.threadId,
                                displayName: threadViewModel.displayName
                            )
                        }
                    )
                )
            ].compactMap { $0 }
        )
        let adminActionsSection: SectionModel? = nil
        let destructiveActionsSection: SectionModel?
        
        if dependencies[feature: .updatedGroupsDeleteBeforeNow] || dependencies[feature: .updatedGroupsDeleteAttachmentsBeforeNow] {
            destructiveActionsSection = SectionModel(
                model: .destructiveActions,
                elements: [
                    // FIXME: [GROUPS REBUILD] Need to build this properly in a future release
                    (!dependencies[feature: .updatedGroupsDeleteBeforeNow] || threadViewModel.threadVariant != .group ? nil :
                        SessionCell.Info(
                            id: .debugDeleteBeforeNow,
                            leadingAccessory: .icon(
                                UIImage(named: "ic_bin")?
                                    .withRenderingMode(.alwaysTemplate),
                                customTint: .danger
                            ),
                            title: "[DEBUG] Delete all messages before now",    // stringlint:disable
                            styling: SessionCell.StyleInfo(
                                tintColor: .danger
                            ),
                            confirmationInfo: ConfirmationModal.Info(
                                title: "delete".localized(),
                                body: .text("Are you sure you want to delete all messages sent before now for all group members?"),   // stringlint:disable
                                confirmTitle: "delete".localized(),
                                confirmStyle: .danger,
                                cancelStyle: .alert_text
                            ),
                            onTap: { [weak self] in self?.deleteAllMessagesBeforeNow() }
                        )
                    ),
                    // FIXME: [GROUPS REBUILD] Need to build this properly in a future release
                    (!dependencies[feature: .updatedGroupsDeleteAttachmentsBeforeNow] || threadViewModel.threadVariant != .group ? nil :
                        SessionCell.Info(
                            id: .debugDeleteAttachmentsBeforeNow,
                            leadingAccessory: .icon(
                                UIImage(named: "ic_bin")?
                                    .withRenderingMode(.alwaysTemplate),
                                customTint: .danger
                            ),
                            title: "[DEBUG] Delete all arrachments before now",    // stringlint:disable
                            styling: SessionCell.StyleInfo(
                                tintColor: .danger
                            ),
                            confirmationInfo: ConfirmationModal.Info(
                                title: "delete".localized(),
                                body: .text("Are you sure you want to delete all attachments (and their associated messages) sent before now for all group members?"),   // stringlint:disable
                                confirmTitle: "delete".localized(),
                                confirmStyle: .danger,
                                cancelStyle: .alert_text
                            ),
                            onTap: { [weak self] in self?.deleteAllAttachmentsBeforeNow() }
                        )
                     )
                ].compactMap { $0 }
            )
        }
        else {
            destructiveActionsSection = nil
        }
        
        return [
            conversationInfoSection,
            standardActionsSection,
            adminActionsSection,
            destructiveActionsSection
        ].compactMap { $0 }
    }
    
    // MARK: - Functions
    
    private func viewDisplayPicture(threadViewModel: SessionThreadViewModel) {
        let displayPictureData: Data
        let ownerId: DisplayPictureManager.OwnerId = {
            switch threadViewModel.threadVariant {
                case .contact: .user(threadViewModel.threadId)
                case .group, .legacyGroup: .group(threadViewModel.threadId)
                case .community: .community(threadViewModel.threadId)
            }
        }()
        
        switch threadViewModel.threadVariant {
            case .legacyGroup: return   // No display pictures for legacy groups
            case .contact:
                guard
                    let profile: Profile = threadViewModel.profile,
                    let imageData: Data = DisplayPictureManager.displayPicture(owner: .user(profile), using: dependencies)
                else { return }
                
                displayPictureData = imageData
            
            default:
                guard
                    threadViewModel.displayPictureFilename != nil,
                    let imageData: Data = dependencies[singleton: .storage].read({ [dependencies] db in
                        DisplayPictureManager.displayPicture(db, id: ownerId, using: dependencies)
                    })
                else { return }
                
                displayPictureData = imageData
        }
        
        let format: ImageFormat = displayPictureData.guessedImageFormat
        let navController: UINavigationController = StyledNavigationController(
            rootViewController: ProfilePictureVC(
                image: (format == .gif || format == .webp ?
                    nil :
                    UIImage(data: displayPictureData)
                ),
                animatedImage: (format != .gif && format != .webp ?
                    nil :
                    YYImage(data: displayPictureData)
                ),
                title: threadViewModel.displayName
            )
        )
        navController.modalPresentationStyle = .fullScreen
        
        self.transitionToScreen(navController, transitionType: .present)
    }
    
    private func inviteUsersToCommunity(threadViewModel: SessionThreadViewModel) {
        guard
            let name: String = threadViewModel.openGroupName,
            let communityUrl: String = LibSession.communityUrlFor(
                server: threadViewModel.openGroupServer,
                roomToken: threadViewModel.openGroupRoomToken,
                publicKey: threadViewModel.openGroupPublicKey
            )
        else { return }
        
        self.transitionToScreen(
            SessionTableViewController(
                viewModel: UserListViewModel<Contact>(
                    title: "membersInvite".localized(),
                    emptyState: "contactNone".localized(),
                    showProfileIcons: false,
                    request: Contact
                        .filter(Contact.Columns.isApproved == true)
                        .filter(Contact.Columns.didApproveMe == true)
                        .filter(Contact.Columns.id != threadViewModel.currentUserSessionId),
                    footerTitle: "membersInvite".localized(),
                    onSubmit: .publisher { [dependencies] _, selectedUserInfo in
                        dependencies[singleton: .storage]
                            .writePublisher { db in
                                try selectedUserInfo.forEach { userInfo in
                                    let thread: SessionThread = try SessionThread.fetchOrCreate(
                                        db,
                                        id: userInfo.profileId,
                                        variant: .contact,
                                        creationDateTimestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000),
                                        shouldBeVisible: nil,
                                        calledFromConfig: nil,
                                        using: dependencies
                                    )
                                    
                                    try LinkPreview(
                                        url: communityUrl,
                                        variant: .openGroupInvitation,
                                        title: name,
                                        using: dependencies
                                    )
                                    .upsert(db)
                                    
                                    let interaction: Interaction = try Interaction(
                                        threadId: thread.id,
                                        threadVariant: thread.variant,
                                        authorId: userInfo.profileId,
                                        variant: .standardOutgoing,
                                        timestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs(),
                                        expiresInSeconds: try? DisappearingMessagesConfiguration
                                            .select(.durationSeconds)
                                            .filter(id: userInfo.profileId)
                                            .filter(DisappearingMessagesConfiguration.Columns.isEnabled == true)
                                            .asRequest(of: TimeInterval.self)
                                            .fetchOne(db),
                                        linkPreviewUrl: communityUrl,
                                        using: dependencies
                                    )
                                    .inserted(db)
                                    
                                    try MessageSender.send(
                                        db,
                                        interaction: interaction,
                                        threadId: thread.id,
                                        threadVariant: thread.variant,
                                        using: dependencies
                                    )
                                    
                                    // Trigger disappear after read
                                    dependencies[singleton: .jobRunner].upsert(
                                        db,
                                        job: DisappearingMessagesJob.updateNextRunIfNeeded(
                                            db,
                                            interaction: interaction,
                                            startedAtMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs(),
                                            using: dependencies
                                        ),
                                        canStartJob: true
                                    )
                                }
                            }
                            .mapError { UserListError.error($0.localizedDescription) }
                            .eraseToAnyPublisher()
                    },
                    using: dependencies
                )
            ),
            transitionType: .push
        )
    }
    
    private func viewMembers() {
        self.transitionToScreen(
            SessionTableViewController(
                viewModel: UserListViewModel(
                    title: "groupMembers".localized(),
                    showProfileIcons: true,
                    request: GroupMember
                        .select(
                            GroupMember.Columns.groupId,
                            GroupMember.Columns.profileId,
                            max(GroupMember.Columns.role).forKey(GroupMember.Columns.role.name),
                            GroupMember.Columns.roleStatus,
                            GroupMember.Columns.isHidden
                        )
                        .filter(GroupMember.Columns.groupId == threadId)
                        .group(GroupMember.Columns.profileId),
                    onTap: .callback { [weak self, dependencies] _, memberInfo in
                        dependencies[singleton: .storage].write { db in
                            try SessionThread.fetchOrCreate(
                                db,
                                id: memberInfo.profileId,
                                variant: .contact,
                                creationDateTimestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000),
                                shouldBeVisible: nil,
                                calledFromConfig: nil,
                                using: dependencies
                            )
                        }
                        
                        self?.transitionToScreen(
                            ConversationVC(
                                threadId: memberInfo.profileId,
                                threadVariant: .contact,
                                using: dependencies
                            ),
                            transitionType: .push
                        )
                    },
                    using: dependencies
                )
            )
        )
    }
    
    private func promoteAdmins() {
        guard dependencies[feature: .updatedGroupsAllowPromotions] else { return }
        
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        
        /// Submitting and resending using the same logic
        func send(
            _ viewModel: UserListViewModel<GroupMember>?,
            _ memberInfo: [(id: String, profile: Profile?)],
            isResend: Bool
        ) {
            MessageSender.promoteGroupMembers(
                groupSessionId: SessionId(.group, hex: threadId),
                members: memberInfo,
                sendAdminChangedMessage: !isResend,
                using: dependencies
            )
            viewModel?.showToast(
                text: "adminSendingPromotion"
                    .putNumber(memberInfo.count)
                    .localized(),
                backgroundColor: .backgroundSecondary
            )
        }
        
        /// Show the selection list
        self.transitionToScreen(
            SessionTableViewController(
                viewModel: UserListViewModel<GroupMember>(
                    title: "promote".localized(),
                    // FIXME: Localise this
                    emptyState: "There are no group members which can be promoted.",
                    showProfileIcons: true,
                    request: SQLRequest("""
                        SELECT \(groupMember.allColumns)
                        FROM \(groupMember)
                        WHERE (
                            \(groupMember[.groupId]) == \(threadId) AND (
                                \(groupMember[.role]) == \(GroupMember.Role.admin) OR
                                (
                                    \(groupMember[.role]) != \(GroupMember.Role.admin) AND
                                    \(groupMember[.roleStatus]) == \(GroupMember.RoleStatus.accepted)
                                )
                            )
                        )
                        GROUP BY \(groupMember[.profileId])
                    """),
                    footerTitle: "promote".localized(),
                    onTap: .conditionalAction(
                        action: { memberInfo in
                            guard memberInfo.profileId != memberInfo.currentUserSessionId.hexString else {
                                return .none
                            }
                            
                            switch (memberInfo.value.role, memberInfo.value.roleStatus) {
                                case (.standard, _): return .radio
                                default:
                                    return .custom(
                                        trailingAccessory: { _ in
                                            .highlightingBackgroundLabel(
                                                title: "resend".localized()
                                            )
                                        },
                                        onTap: { viewModel, info in
                                            send(viewModel, [(info.profileId, info.profile)], isResend: true)
                                        }
                                    )
                            }
                        }
                    ),
                    onSubmit: .callback { viewModel, selectedInfo in
                        send(viewModel, selectedInfo.map { ($0.profileId, $0.profile) }, isResend: false)
                    },
                    using: dependencies
                )
            ),
            transitionType: .push
        )
    }
    
    private func updateNickname(current: String?, displayName: String) {
        /// Set `updatedName` to `current` so we can disable the "save" button when there are no changes and don't need to worry
        /// about retrieving them in the confirmation closure
        self.updatedName = current
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "nicknameSet".localized(),
                    body: .input(
                        explanation: "nicknameDescription"
                            .put(key: "name", value: displayName)
                            .localizedFormatted(baseFont: ConfirmationModal.explanationFont),
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "nicknameEnter".localized(),
                            initialValue: current
                        ),
                        onChange: { [weak self] updatedName in self?.updatedName = updatedName }
                    ),
                    confirmTitle: "save".localized(),
                    confirmEnabled: .afterChange { [weak self] _ in
                        self?.updatedName != current &&
                        self?.updatedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    },
                    cancelTitle: "remove".localized(),
                    cancelStyle: .danger,
                    cancelEnabled: .bool(current?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false),
                    hasCloseButton: true,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self, dependencies, threadId] modal in
                        guard
                            let finalNickname: String = (self?.updatedName ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .nullIfEmpty
                        else { return }
                        
                        /// Check if the data violates the size constraints
                        guard !Profile.isTooLong(profileName: finalNickname) else {
                            self?.transitionToScreen(
                                ConfirmationModal(
                                    info: ConfirmationModal.Info(
                                        title: "theError".localized(),
                                        body: .text("nicknameErrorShorter".localized()),
                                        cancelTitle: "okay".localized(),
                                        cancelStyle: .alert_text,
                                        dismissType: .single
                                    )
                                ),
                                transitionType: .present
                            )
                            return
                        }
                        
                        /// Update the nickname
                        dependencies[singleton: .storage].writeAsync { db in
                            try Profile
                                .filter(id: threadId)
                                .updateAllAndConfig(
                                    db,
                                    Profile.Columns.nickname.set(to: finalNickname),
                                    calledFromConfig: nil,
                                    using: dependencies
                                )
                        }
                        modal.dismiss(animated: true)
                    },
                    onCancel: { [dependencies, threadId] modal in
                        /// Remove the nickname
                        dependencies[singleton: .storage].writeAsync { db in
                            try Profile
                                .filter(id: threadId)
                                .updateAllAndConfig(
                                    db,
                                    Profile.Columns.nickname.set(to: nil),
                                    calledFromConfig: nil,
                                    using: dependencies
                                )
                        }
                        modal.dismiss(animated: true)
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func updateGroupNameAndDescription(
        currentName: String,
        currentDescription: String?,
        isUpdatedGroup: Bool
    ) {
        /// Set the `updatedName` and `updatedDescription` values to the current values so we can disable the "save" button when there are
        /// no changes and don't need to worry about retrieving them in the confirmation closure
        self.updatedName = currentName
        self.updatedDescription = currentDescription
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "groupInformationSet".localized(),
                    body: { [weak self, dependencies] in
                        guard isUpdatedGroup && dependencies[feature: .updatedGroupsAllowDescriptionEditing] else {
                            return .input(
                                explanation: NSAttributedString(string: "groupNameVisible".localized()),
                                info: ConfirmationModal.Info.Body.InputInfo(
                                    placeholder: "groupNameEnter".localized(),
                                    initialValue: currentName
                                ),
                                onChange: { updatedName in self?.updatedName = updatedName }
                            )
                        }
                        
                        return .dualInput(
                            // FIXME: Localise this
                            explanation: NSAttributedString(string: "Group name and description are visible to all group members."),
                            firstInfo: ConfirmationModal.Info.Body.InputInfo(
                                placeholder: "groupNameEnter".localized(),
                                initialValue: currentName
                            ),
                            secondInfo: ConfirmationModal.Info.Body.InputInfo(
                                placeholder: "groupDescriptionEnter".localized(),
                                initialValue: currentDescription
                            ),
                            onChange: { updatedName, updatedDescription in
                                self?.updatedName = updatedName
                                self?.updatedDescription = updatedDescription
                            }
                        )
                    }(),
                    confirmTitle: "save".localized(),
                    confirmEnabled: .afterChange { [weak self] _ in
                        self?.updatedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && (
                            self?.updatedName != currentName ||
                            self?.updatedDescription != currentDescription
                        )
                    },
                    cancelStyle: .danger,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self, dependencies, threadId] modal in
                        guard
                            let finalName: String = (self?.updatedName ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .nullIfEmpty
                        else { return }
                        
                        let finalDescription: String? = self?.updatedDescription
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        
                        /// Check if the data violates any of the size constraints
                        let maybeErrorString: String? = {
                            guard !LibSession.isTooLong(groupName: finalName) else {
                                return "groupNameEnterShorter".localized()
                            }
                            guard !LibSession.isTooLong(groupDescription: (finalDescription ?? "")) else {
                                // FIXME: Localise this
                                return "Please enter a shorter group description."
                            }
                            
                            return nil  // No error has occurred
                        }()
                        
                        if let errorString: String = maybeErrorString {
                            self?.transitionToScreen(
                                ConfirmationModal(
                                    info: ConfirmationModal.Info(
                                        title: "theError".localized(),
                                        body: .text(errorString),
                                        cancelTitle: "okay".localized(),
                                        cancelStyle: .alert_text,
                                        dismissType: .single
                                    )
                                ),
                                transitionType: .present
                            )
                            return
                        }
                        
                        /// Update the group appropriately
                        MessageSender
                            .updateGroup(
                                groupSessionId: threadId,
                                name: finalName,
                                groupDescription: finalDescription,
                                using: dependencies
                            )
                            .sinkUntilComplete(
                                receiveCompletion: { [weak self] result in
                                    switch result {
                                        case .finished: modal.dismiss(animated: true)
                                        case .failure:
                                            self?.transitionToScreen(
                                                ConfirmationModal(
                                                    info: ConfirmationModal.Info(
                                                        title: "theError".localized(),
                                                        body: .text("deleteAfterLegacyGroupsGroupUpdateErrorTitle".localized()),
                                                        cancelTitle: "okay".localized(),
                                                        cancelStyle: .alert_text
                                                    )
                                                ),
                                                transitionType: .present
                                            )
                                    }
                                }
                            )
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func updateGroupDisplayPicture(currentFileName: String?) {
        guard dependencies[feature: .updatedGroupsAllowDisplayPicture] else { return }
        
        let existingImageData: Data? = dependencies[singleton: .storage].read { [threadId, dependencies] db in
            DisplayPictureManager.displayPicture(db, id: .group(threadId), using: dependencies)
        }
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "groupSetDisplayPicture".localized(),
                    body: .image(
                        placeholderData: UIImage(named: "profile_placeholder")?.pngData(),
                        valueData: existingImageData,
                        icon: .rightPlus,
                        style: .circular,
                        accessibility: Accessibility(
                            identifier: "Image picker",
                            label: "Image picker"
                        ),
                        onClick: { [weak self] onDisplayPictureSelected in
                            self?.onDisplayPictureSelected = onDisplayPictureSelected
                            self?.showPhotoLibraryForAvatar()
                        }
                    ),
                    confirmTitle: "save".localized(),
                    confirmEnabled: .afterChange { info in
                        switch info.body {
                            case .image(_, let valueData, _, _, _, _): return (valueData != nil)
                            default: return false
                        }
                    },
                    cancelTitle: "remove".localized(),
                    cancelEnabled: .bool(existingImageData != nil),
                    hasCloseButton: true,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self] modal in
                        switch modal.info.body {
                            case .image(_, .some(let valueData), _, _, _, _):
                                self?.updateGroupDisplayPicture(
                                    displayPictureUpdate: .groupUploadImageData(valueData),
                                    onComplete: { [weak modal] in modal?.close() }
                                )
                                
                            default: modal.close()
                        }
                    },
                    onCancel: { [weak self] modal in
                        self?.updateGroupDisplayPicture(
                            displayPictureUpdate: .groupRemove,
                            onComplete: { [weak modal] in modal?.close() }
                        )
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func showPhotoLibraryForAvatar() {
        Permissions.requestLibraryPermissionIfNeeded(isSavingMedia: false, using: dependencies) { [weak self] in
            DispatchQueue.main.async {
                let picker: UIImagePickerController = UIImagePickerController()
                picker.sourceType = .photoLibrary
                picker.mediaTypes = [ "public.image" ]  // stringlint:disable
                picker.delegate = self?.imagePickerHandler
                
                self?.transitionToScreen(picker, transitionType: .present)
            }
        }
    }
    
    private func updateGroupDisplayPicture(
        displayPictureUpdate: DisplayPictureManager.Update,
        onComplete: @escaping () -> ()
    ) {
        switch displayPictureUpdate {
            case .none: onComplete()
            default: break
        }
        
        func performChanges(_ viewController: ModalActivityIndicatorViewController, _ displayPictureUpdate: DisplayPictureManager.Update) {
            let existingFileName: String? = dependencies[singleton: .storage].read { [threadId] db in
                try? ClosedGroup
                    .filter(id: threadId)
                    .select(.displayPictureFilename)
                    .asRequest(of: String.self)
                    .fetchOne(db)
            }
            
            MessageSender
                .updateGroup(
                    groupSessionId: threadId,
                    displayPictureUpdate: displayPictureUpdate,
                    using: dependencies
                )
                .sinkUntilComplete(
                    receiveCompletion: { [dependencies] result in
                        // Remove any cached avatar image value
                        if let existingFileName: String = existingFileName {
                            dependencies.mutate(cache: .displayPicture) { $0.imageData[existingFileName] = nil }
                        }
                        
                        DispatchQueue.main.async {
                            viewController.dismiss(completion: {
                                onComplete()
                            })
                        }
                    }
                )
        }
        
        let viewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self, dependencies] viewController in
            switch displayPictureUpdate {
                case .none, .currentUserRemove, .currentUserUploadImageData, .currentUserUpdateTo,
                    .contactRemove, .contactUpdateTo:
                    viewController.dismiss(animated: true) // Shouldn't get called
                
                case .groupRemove, .groupUpdateTo: performChanges(viewController, displayPictureUpdate)
                case .groupUploadImageData(let data):
                    DisplayPictureManager.prepareAndUploadDisplayPicture(
                        queue: DispatchQueue.global(qos: .background),
                        imageData: data,
                        success: { url, fileName, key in
                            performChanges(viewController, .groupUpdateTo(url: url, key: key, fileName: fileName))
                        },
                        failure: { error in
                            DispatchQueue.main.async {
                                viewController.dismiss {
                                    let message: String = {
                                        switch (displayPictureUpdate, error) {
                                            case (.groupRemove, _): return "profileDisplayPictureRemoveError".localized()
                                            case (_, .uploadMaxFileSizeExceeded):
                                                return "profileDisplayPictureSizeError".localized()
                                            
                                            default: return "errorConnection".localized()
                                        }
                                    }()
                                    
                                    self?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "deleteAfterLegacyGroupsGroupUpdateErrorTitle".localized(),
                                                body: .text(message),
                                                cancelTitle: "okay".localized(),
                                                cancelStyle: .alert_text,
                                                dismissType: .single
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                }
                            }
                        },
                        using: dependencies
                    )
            }
        }
        self.transitionToScreen(viewController, transitionType: .present)
    }
    
    private func updateBlockedState(
        from oldBlockedState: Bool,
        isBlocked: Bool,
        threadId: String,
        displayName: String
    ) {
        guard oldBlockedState != isBlocked else { return }
        
        dependencies[singleton: .storage].writeAsync { [dependencies] db in
            try Contact
                .filter(id: threadId)
                .updateAllAndConfig(
                    db,
                    Contact.Columns.isBlocked.set(to: isBlocked),
                    calledFromConfig: nil,
                    using: dependencies
                )
        }
    }
    
    private func deleteAllMessagesBeforeNow() {
        guard threadVariant == .group else { return }
        
        dependencies[singleton: .storage].writeAsync { [threadId, dependencies] db in
            try LibSession.deleteMessagesBefore(
                db,
                groupSessionId: SessionId(.group, hex: threadId),
                timestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000),
                using: dependencies
            )
        }
    }
    
    private func deleteAllAttachmentsBeforeNow() {
        guard threadVariant == .group else { return }
        
        dependencies[singleton: .storage].writeAsync { [threadId, dependencies] db in
            try LibSession.deleteAttachmentsBefore(
                db,
                groupSessionId: SessionId(.group, hex: threadId),
                timestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000),
                using: dependencies
            )
        }
    }
}
