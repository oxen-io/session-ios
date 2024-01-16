// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import YYImage
import DifferenceKit
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

class EditGroupViewModel: SessionTableViewModel, NavigatableStateHolder, EditableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let editableState: EditableState<TableItem> = EditableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    private let selectedIdsSubject: CurrentValueSubject<Set<String>, Never> = CurrentValueSubject([])
    
    private let threadId: String
    private let userSessionId: SessionId
    private lazy var imagePickerHandler: ImagePickerHandler = ImagePickerHandler(
        onTransition: { [weak self] in self?.transitionToScreen($0, transitionType: $1) },
        onImageDataPicked: { [weak self] resultImageData in
            self?.updatedDisplayPictureSelected(update: .uploadImageData(resultImageData))
        }
    )
    fileprivate var newDisplayName: String?
    fileprivate var newGroupDescription: String?
    private var editDisplayPictureModal: ConfirmationModal?
    private var editDisplayPictureModalInfo: ConfirmationModal.Info?
    
    // MARK: - Initialization
    
    init(threadId: String, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.userSessionId = getUserSessionId(using: dependencies)
    }
    
    // MARK: - Config
    
    public enum Section: SessionTableSection {
        case groupInfo
        case invite
        case members
        
        public var title: String? {
            switch self {
                case .members: return "GROUP_MEMBERS".localized()
                default: return nil
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .members: return .titleEdgeToEdgeContent
                default: return .none
            }
        }
    }
    
    public enum TableItem: Equatable, Hashable, Differentiable {
        case avatar
        case groupName
        case groupDescription
        
        case invite
        
        case member(String)
    }

    // MARK: - Content
    
    private struct State: Equatable {
        let group: ClosedGroup
        let profileFront: Profile?
        let profileBack: Profile?
        let members: [WithProfile<GroupMember>]
        let isValid: Bool
        
        static let invalidState: State = State(
            group: ClosedGroup(threadId: "", name: "", formationTimestamp: 0, shouldPoll: false, invited: false),
            profileFront: nil,
            profileBack: nil,
            members: [],
            isValid: false
        )
    }
    
    let title: String = "EDIT_GROUP_ACTION".localized()
    
    lazy var observation: TargetObservation = ObservationBuilder
        .databaseObservation(self) { [dependencies, threadId, userSessionId] db -> State in
            guard let group: ClosedGroup = try ClosedGroup.fetchOne(db, id: threadId) else {
                return State.invalidState
            }
            
            var profileFront: Profile?
            var profileBack: Profile?
            
            if group.displayPictureFilename == nil {
                let frontProfileId: String? = try GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .filter(GroupMember.Columns.role == GroupMember.Role.standard)
                    .filter(GroupMember.Columns.profileId != userSessionId.hexString)
                    .select(min(GroupMember.Columns.profileId))
                    .asRequest(of: String.self)
                    .fetchOne(db)
                let backProfileId: String? = try GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .filter(GroupMember.Columns.role == GroupMember.Role.standard)
                    .filter(GroupMember.Columns.profileId != userSessionId.hexString)
                    .filter(GroupMember.Columns.profileId != frontProfileId)
                    .select(max(GroupMember.Columns.profileId))
                    .asRequest(of: String.self)
                    .fetchOne(db)
                
                profileFront = try frontProfileId.map { try Profile.fetchOne(db, id: $0) }
                profileBack = try Profile.fetchOne(db, id: backProfileId ?? userSessionId.hexString)
            }
            
            return State(
                group: group,
                profileFront: profileFront,
                profileBack: profileBack,
                members: try GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .fetchAllWithProfiles(db),
                isValid: true
            )
        }
        .compactMap { [weak self] state -> [SectionModel]? in self?.content(state) }
    
    private func content(_ state: State) -> [SectionModel] {
        guard state.isValid else {
            return [
                SectionModel(
                    model: .groupInfo,
                    elements: [
                        SessionCell.Info(
                            id: .groupName,
                            title: SessionCell.TextInfo(
                                "ERROR_UNABLE_TO_FIND_DATA".localized(),
                                font: .subtitle,
                                alignment: .center
                            ),
                            styling: SessionCell.StyleInfo(
                                tintColor: .textSecondary,
                                alignment: .centerHugging,
                                customPadding: SessionCell.Padding(top: Values.smallSpacing),
                                backgroundStyle: .noBackground
                            )
                        )
                    ]
                )
            ]
        }
        
        let isUpdatedGroup: Bool = (((try? SessionId.Prefix(from: threadId)) ?? .group) == .group)
        let editIcon: UIImage? = UIImage(systemName: "pencil")
        let sortedMembers: [WithProfile<GroupMember>] = {
            guard !isUpdatedGroup else { return state.members }
            
            // FIXME: Remove this once legacy groups are deprecated
            /// In legacy groups there would be both `standard` and `admin` `GroupMember` entries for admins so
            /// pre-process the members in order to remove the duplicates
            return Array(state.members
                .sorted(by: { lhs, rhs in lhs.value.role.rawValue < rhs.value.role.rawValue })
                .reduce(into: [:]) { result, next in result[next.profileId] = next }
                .values)
        }()
        .sorted()
        
        return [
            SectionModel(
                model: .groupInfo,
                elements: [
                    SessionCell.Info(
                        id: .avatar,
                        accessory: .profile(
                            id: threadId,
                            size: .hero,
                            threadVariant: (isUpdatedGroup ? .group : .legacyGroup),
                            displayPictureFilename: state.group.displayPictureFilename,
                            profile: state.profileFront,
                            profileIcon: {
                                guard isUpdatedGroup && dependencies[feature: .updatedGroupsAllowDisplayPicture] else {
                                    return .none
                                }
                                
                                // If we already have a display picture then the main profile gets the icon
                                return (state.group.displayPictureFilename != nil ? .rightPlus : .none)
                            }(),
                            additionalProfile: state.profileBack,
                            additionalProfileIcon: {
                                guard isUpdatedGroup && dependencies[feature: .updatedGroupsAllowDisplayPicture] else {
                                    return .none
                                }
                                
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
                        accessibility: Accessibility(
                            label: "Profile picture"
                        ),
                        onTap: { [weak self, dependencies] in
                            guard isUpdatedGroup && dependencies[feature: .updatedGroupsAllowDisplayPicture] else {
                                return
                            }
                            
                            self?.updateDisplayPicture(currentFileName: state.group.displayPictureFilename)
                        }
                    ),
                    SessionCell.Info(
                        id: .groupName,
                        leadingAccessory: .icon(
                            editIcon?.withRenderingMode(.alwaysTemplate),
                            size: .medium,
                            customTint: .textSecondary
                        ),
                        title: SessionCell.TextInfo(
                            state.group.name,
                            font: .titleLarge,
                            alignment: .center,
                            editingPlaceholder: "EDIT_GROUP_NAME_PLACEHOLDER".localized()
                        ),
                        styling: SessionCell.StyleInfo(
                            alignment: .centerHugging,
                            customPadding: SessionCell.Padding(
                                top: Values.smallSpacing,
                                leading: -((IconSize.medium.size + (Values.smallSpacing * 2)) / 2),
                                bottom: Values.smallSpacing,
                                interItem: 0
                            ),
                            backgroundStyle: .noBackground
                        ),
                        accessibility: Accessibility(
                            identifier: "Group name",
                            label: state.group.name
                        ),
                        onTap: { [weak self] in
                            self?.updateGroupNameAndDescription(
                                isUpdatedGroup: isUpdatedGroup,
                                currentName: state.group.name,
                                currentDescription: state.group.groupDescription
                            )
                        }
                    ),
                    ((state.group.groupDescription ?? "").isEmpty ? nil :
                        SessionCell.Info(
                            id: .groupDescription,
                            title: SessionCell.TextInfo(
                                (state.group.groupDescription ?? ""),
                                font: .subtitle,
                                alignment: .center,
                                editingPlaceholder: "EDIT_GROUP_DESCRIPTION_PLACEHOLDER".localized()
                            ),
                            styling: SessionCell.StyleInfo(
                                tintColor: .textSecondary,
                                alignment: .centerHugging,
                                customPadding: SessionCell.Padding(
                                    top: 0,
                                    bottom: Values.smallSpacing
                                ),
                                backgroundStyle: .noBackground
                            ),
                            accessibility: Accessibility(
                                identifier: "Group description",
                                label: (state.group.groupDescription ?? "")
                            ),
                            onTap: { [weak self] in
                               self?.updateGroupNameAndDescription(
                                   isUpdatedGroup: isUpdatedGroup,
                                   currentName: state.group.name,
                                   currentDescription: state.group.groupDescription
                               )
                           }
                        )
                     )
                ].compactMap { $0 }
            ),
            SectionModel(
                model: .invite,
                elements: [
                    SessionCell.Info(
                        id: .invite,
                        leadingAccessory:  .icon(UIImage(named: "icon_invite")?.withRenderingMode(.alwaysTemplate)),
                        title: "GROUP_ACTION_INVITE_CONTACTS".localized(),
                        accessibility: Accessibility(
                            identifier: "Invite Contacts",
                            label: "Invite Contacts"
                        ),
                        onTap: { [weak self] in self?.inviteContacts(currentGroupName: state.group.name) }
                    )
                ]
            ),
            SectionModel(
                model: .members,
                elements: sortedMembers
                    .map { memberInfo -> SessionCell.Info in
                        SessionCell.Info(
                            id: .member(memberInfo.profileId),
                            leadingAccessory:  .profile(
                                id: memberInfo.profileId,
                                profile: memberInfo.profile,
                                profileIcon: memberInfo.value.profileIcon
                            ),
                            title: (
                                memberInfo.profile?.displayName() ??
                                Profile.truncated(id: memberInfo.profileId, truncating: .middle)
                            ),
                            subtitle: (isUpdatedGroup ? memberInfo.value.statusDescription : nil),
                            trailingAccessory: {
                                switch (memberInfo.value.role, memberInfo.value.roleStatus) {
                                    case (.admin, _), (.moderator, _): return nil
                                    case (.standard, .failed), (.standard, .sending):
                                        return .highlightingBackgroundLabel(
                                            title: "context_menu_resend".localized()
                                        )
                                    
                                    // Intentionally including the 'pending' state in here as we want admins to
                                    // be able to remove pending members - to resend the admin will have to remove
                                    // and re-add the member
                                    case (.standard, .pending), (.standard, .accepted), (.zombie, _):
                                        return .radio(
                                            isSelected: selectedIdsSubject.value.contains(memberInfo.profileId)
                                        )
                                }
                            }(),
                            styling: SessionCell.StyleInfo(
                                subtitleTintColor: (isUpdatedGroup ? memberInfo.value.statusDescriptionColor : nil),
                                allowedSeparators: [],
                                customPadding: SessionCell.Padding(
                                    top: Values.smallSpacing,
                                    bottom: Values.smallSpacing
                                ),
                                backgroundStyle: .noBackgroundEdgeToEdge
                            ),
                            onTap: { [weak self, selectedIdsSubject] in
                                switch (memberInfo.value.role, memberInfo.value.roleStatus) {
                                    case (.moderator, _): return
                                    case (.admin, _):
                                        self?.showToast(
                                            text: "EDIT_GROUP_MEMBERS_ERROR_REMOVE_ADMIN".localized(),
                                            backgroundColor: .backgroundSecondary
                                        )
                                        
                                    case (.standard, .failed), (.standard, .sending):
                                        self?.resendInvitation(memberId: memberInfo.profileId)

                                    case (.standard, .pending), (.standard, .accepted), (.zombie, _):
                                        if !selectedIdsSubject.value.contains(memberInfo.profileId) {
                                            selectedIdsSubject.send(selectedIdsSubject.value.inserting(memberInfo.profileId))
                                        }
                                        else {
                                            selectedIdsSubject.send(selectedIdsSubject.value.removing(memberInfo.profileId))
                                        }
                                        
                                        // Force the table data to be refreshed (the database wouldn't
                                        // have been changed)
                                        self?.forceRefresh(type: .postDatabaseQuery)
                                }
                            }
                        )
                    }
            )
        ]
    }
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = selectedIdsSubject
        .prepend([])
        .map { selectedIds in
            SessionButton.Info(
                style: .destructive,
                title: "GROUP_ACTION_REMOVE".localized(),
                isEnabled: !selectedIds.isEmpty,
                onTap: { [weak self] in self?.removeMembers(memberIds: selectedIds) }
            )
        }
        .eraseToAnyPublisher()
    
    // MARK: - Functions
    
    private func updateDisplayPicture(currentFileName: String?) {
        guard dependencies[feature: .updatedGroupsAllowDisplayPicture] else { return }
        
        let existingImageData: Data? = dependencies[singleton: .storage].read(using: dependencies) { [threadId] db in
            DisplayPictureManager.displayPicture(db, id: .group(threadId))
        }
        let editDisplayPictureModalInfo: ConfirmationModal.Info = ConfirmationModal.Info(
            title: "EDIT_GROUP_DISPLAY_PICTURE".localized(),
            body: .image(
                placeholderData: UIImage(named: "profile_placeholder")?.pngData(),
                valueData: existingImageData,
                icon: .rightPlus,
                style: .circular,
                accessibility: Accessibility(
                    identifier: "Image picker",
                    label: "Image picker"
                ),
                onClick: { [weak self] in self?.showPhotoLibraryForAvatar() }
            ),
            confirmTitle: "update_profile_modal_save".localized(),
            confirmEnabled: false,
            cancelTitle: "update_profile_modal_remove".localized(),
            cancelEnabled: (existingImageData != nil),
            hasCloseButton: true,
            dismissOnConfirm: false,
            onConfirm: { modal in modal.close() },
            onCancel: { [weak self] modal in
                self?.updateDisplayPicture(
                    displayPictureUpdate: .remove,
                    onComplete: { [weak modal] in modal?.close() }
                )
            },
            afterClosed: { [weak self] in
                self?.editDisplayPictureModal = nil
                self?.editDisplayPictureModalInfo = nil
            }
        )
        let modal: ConfirmationModal = ConfirmationModal(info: editDisplayPictureModalInfo)
            
        self.editDisplayPictureModalInfo = editDisplayPictureModalInfo
        self.editDisplayPictureModal = modal
        self.transitionToScreen(modal, transitionType: .present)
    }

    private func updatedDisplayPictureSelected(update: DisplayPictureManager.Update) {
        guard let info: ConfirmationModal.Info = self.editDisplayPictureModalInfo else { return }
        
        self.editDisplayPictureModal?.updateContent(
            with: info.with(
                body: .image(
                    placeholderData: UIImage(named: "profile_placeholder")?.pngData(),
                    valueData: {
                        switch update {
                            case .uploadImageData(let imageData): return imageData
                            default: return nil
                        }
                    }(),
                    icon: .rightPlus,
                    style: .circular,
                    accessibility: Accessibility(
                        identifier: "Image picker",
                        label: "Image picker"
                    ),
                    onClick: { [weak self] in self?.showPhotoLibraryForAvatar() }
                ),
                confirmEnabled: true,
                onConfirm: { [weak self] modal in
                    self?.updateDisplayPicture(
                        displayPictureUpdate: update,
                        onComplete: { [weak modal] in modal?.close() }
                    )
                }
            )
        )
    }
    
    private func showPhotoLibraryForAvatar() {
        Permissions.requestLibraryPermissionIfNeeded(using: dependencies) { [weak self] in
            DispatchQueue.main.async {
                let picker: UIImagePickerController = UIImagePickerController()
                picker.sourceType = .photoLibrary
                picker.mediaTypes = [ "public.image" ]  // stringlint:disable
                picker.delegate = self?.imagePickerHandler
                
                self?.transitionToScreen(picker, transitionType: .present)
            }
        }
    }
    
    private func updateDisplayPicture(
        displayPictureUpdate: DisplayPictureManager.Update,
        onComplete: (() -> ())? = nil
    ) {
        switch displayPictureUpdate {
            case .none: onComplete?()
            default: break
        }
        
        func performChanges(_ viewController: ModalActivityIndicatorViewController, _ displayPictureUpdate: DisplayPictureManager.Update) {
            let existingFileName: String? = dependencies[singleton: .storage].read(using: dependencies) { [threadId] db in
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
                                onComplete?()
                            })
                        }
                    }
                )
        }
        
        let viewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self, dependencies] viewController in
            switch displayPictureUpdate {
                case .none: break // Shouldn't get called
                case .remove, .updateTo: performChanges(viewController, displayPictureUpdate)
                case .uploadImageData(let data):
                    DisplayPictureManager.prepareAndUploadDisplayPicture(
                        queue: DispatchQueue.global(qos: .background),
                        imageData: data,
                        success: { url, fileName, key in
                            performChanges(viewController, .updateTo(url: url, key: key, fileName: fileName))
                        },
                        failure: { error in
                            DispatchQueue.main.async {
                                viewController.dismiss {
                                    let title: String = {
                                        switch (displayPictureUpdate, error) {
                                            case (_, .uploadMaxFileSizeExceeded):
                                                return "update_profile_modal_max_size_error_title".localized()
                                            
                                            default: return "ALERT_ERROR_TITLE".localized()
                                        }
                                    }()
                                    let message: String? = {
                                        switch (displayPictureUpdate, error) {
                                            case (.remove, _): return "EDIT_DISPLAY_PICTURE_ERROR_REMOVE".localized()
                                            case (_, .uploadMaxFileSizeExceeded):
                                                return "update_profile_modal_max_size_error_message".localized()
                                            
                                            default: return "EDIT_DISPLAY_PICTURE_ERROR".localized()
                                        }
                                    }()
                                    
                                    self?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: title,
                                                body: (message.map { .text($0) } ?? .none),
                                                cancelTitle: "BUTTON_OK".localized(),
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
    
    private func updateGroupNameAndDescription(
        isUpdatedGroup: Bool,
        currentName: String,
        currentDescription: String?
    ) {
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: (isUpdatedGroup && dependencies[feature: .updatedGroupsAllowDescriptionEditing] ?
                        "EDIT_GROUP_INFO_TITLE".localized() :
                        "EDIT_LEGACY_GROUP_INFO_TITLE".localized()
                    ),
                    body: { [weak self, dependencies] in
                        guard isUpdatedGroup && dependencies[feature: .updatedGroupsAllowDescriptionEditing] else {
                            return .input(
                                explanation: NSAttributedString(string: "EDIT_LEGACY_GROUP_INFO_MESSAGE".localized()),
                                info: ConfirmationModal.Info.Body.InputInfo(
                                    placeholder: "EDIT_GROUP_NAME_PLACEHOLDER".localized(),
                                    initialValue: currentName
                                ),
                                onChange: { updatedName in
                                    self?.newDisplayName = updatedName
                                }
                            )
                        }
                        
                        return .dualInput(
                            explanation: NSAttributedString(string: "EDIT_GROUP_INFO_MESSAGE".localized()),
                            firstInfo: ConfirmationModal.Info.Body.InputInfo(
                                placeholder: "EDIT_GROUP_NAME_PLACEHOLDER".localized(),
                                initialValue: currentName
                            ),
                            secondInfo: ConfirmationModal.Info.Body.InputInfo(
                                placeholder: "EDIT_GROUP_DESCRIPTION_PLACEHOLDER".localized(),
                                initialValue: currentDescription
                            ),
                            onChange: { updatedName, updatedDescription in
                                self?.newDisplayName = updatedName
                                self?.newGroupDescription = updatedDescription
                            }
                        )
                    }(),
                    confirmTitle: "update_profile_modal_save".localized(),
                    cancelStyle: .danger,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self, dependencies, threadId] modal in
                        let finalName: String = (self?.newDisplayName ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let finalDescription: String? = self?.newGroupDescription
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        
                        /// Check if the data violates any of the size constraints
                        let maybeErrorString: String? = {
                            guard !finalName.isEmpty else { return "EDIT_GROUP_NAME_ERROR_MISSING".localized() }
                            guard !Profile.isTooLong(profileName: finalName) else { return "EDIT_GROUP_NAME_ERROR_LONG".localized() }
                            guard !LibSession.isTooLong(groupDescription: (finalDescription ?? "")) else {
                                return "EDIT_GROUP_DESCRIPTION_ERROR_LONG".localized()
                            }
                            
                            return nil
                        }()
                        
                        if let errorString: String = maybeErrorString {
                            self?.transitionToScreen(
                                ConfirmationModal(
                                    info: ConfirmationModal.Info(
                                        title: "ALERT_ERROR_TITLE".localized(),
                                        body: .text(errorString),
                                        cancelTitle: "BUTTON_OK".localized(),
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
                                                        title: "ALERT_ERROR_TITLE".localized(),
                                                        body: .text("DEFAULT_OPEN_GROUP_LOAD_ERROR_SUBTITLE".localized()),
                                                        cancelTitle: "BUTTON_OK".localized(),
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
    
    private func inviteContacts(
        currentGroupName: String
    ) {
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        let currentMemberIds: Set<String> = (tableData
            .first(where: { $0.model == .members })?
            .elements
            .compactMap { item -> String? in
                switch item.id {
                    case .member(let profileId): return profileId
                    default: return nil
                }
            })
            .defaulting(to: [])
            .asSet()
        
        self.transitionToScreen(
            SessionTableViewController(
                viewModel: UserListViewModel<Contact>(
                    title: "GROUP_ACTION_INVITE_CONTACTS".localized(),
                    emptyState: "GROUP_ACTION_INVITE_EMPTY_STATE".localized(),
                    showProfileIcons: true,
                    request: SQLRequest("""
                        SELECT \(contact.allColumns)
                        FROM \(contact)
                        LEFT JOIN \(groupMember) ON (
                            \(groupMember[.groupId]) = \(threadId) AND
                            \(groupMember[.profileId]) = \(contact[.id])
                        )
                        WHERE \(groupMember[.profileId]) IS NULL
                    """),
                    footerTitle: "GROUP_ACTION_INVITE".localized(),
                    onSubmit: {
                        switch try? SessionId.Prefix(from: threadId) {
                            case .group:
                                return .callback { [dependencies, threadId] viewModel, selectedMemberInfo in
                                    let updatedMemberIds: Set<String> = currentMemberIds
                                        .inserting(contentsOf: selectedMemberInfo.map { $0.profileId }.asSet())
                                    
                                    guard updatedMemberIds.count <= LibSession.sizeMaxGroupMemberCount else {
                                        throw UserListError.error(
                                            "vc_create_closed_group_too_many_group_members_error".localized()
                                        )
                                    }
                                    
                                    MessageSender.addGroupMembers(
                                        groupSessionId: threadId,
                                        members: selectedMemberInfo.map { ($0.profileId, $0.profile) },
                                        allowAccessToHistoricMessages: dependencies[feature: .updatedGroupsAllowHistoricAccessOnInvite],
                                        using: dependencies
                                    )
                                    viewModel?.showToast(
                                        text: (selectedMemberInfo.count == 1 ?
                                            "GROUP_ACTION_INVITE_SENDING".localized() :
                                            "GROUP_ACTION_INVITE_SENDING_MULTIPLE".localized()
                                        ),
                                        backgroundColor: .backgroundSecondary
                                    )
                                }
                                
                            case .standard: // Assume it's a legacy group
                                return .publisher { [dependencies, threadId] _, selectedMemberInfo in
                                    let updatedMemberIds: Set<String> = currentMemberIds
                                        .inserting(contentsOf: selectedMemberInfo.map { $0.profileId }.asSet())
                                    
                                    guard updatedMemberIds.count <= LibSession.sizeMaxGroupMemberCount else {
                                        return Fail(error: .error("vc_create_closed_group_too_many_group_members_error".localized()))
                                            .eraseToAnyPublisher()
                                    }
                                    
                                    return MessageSender.update(
                                        legacyGroupSessionId: threadId,
                                        with: updatedMemberIds,
                                        name: currentGroupName,
                                        using: dependencies
                                    )
                                    .mapError { _ in UserListError.error("GROUP_UPDATE_ERROR_TITLE".localized()) }
                                    .eraseToAnyPublisher()
                                }
                                
                            default: return .none
                        }
                    }(),
                    using: dependencies
                )
            ),
            transitionType: .push
        )
    }
    
    private func resendInvitation(memberId: String) {
        MessageSender.resendInvitation(
            groupSessionId: threadId,
            memberId: memberId,
            using: dependencies
        )
        self.showToast(text: "GROUP_ACTION_INVITE_SENDING".localized())
    }
    
    private func removeMembers(memberIds: Set<String>) {
        guard !memberIds.isEmpty else { return }
        
        switch try? SessionId.Prefix(from: threadId) {
            case .group:
                MessageSender
                    .removeGroupMembers(
                        groupSessionId: threadId,
                        memberIds: memberIds,
                        removeTheirMessages: dependencies[feature: .updatedGroupsRemoveMessagesOnKick],
                        sendMemberChangedMessage: true,
                        using: dependencies
                    )
                    .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                    .sinkUntilComplete()
                self.selectedIdsSubject.send([])
            
            case .standard: // Assume it's a legacy group
                let updatedMemberIds: Set<String> = (tableData
                    .first(where: { $0.model == .members })?
                    .elements
                    .compactMap { item -> String? in
                        switch item.id {
                            case .member(let profileId): return profileId
                            default: return nil
                        }
                    })
                    .defaulting(to: [])
                    .asSet()
                    .removing(contentsOf: memberIds)
                
                let viewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self, dependencies, threadId] modalActivityIndicator in
                    let currentGroupName: String = dependencies[singleton: .storage]
                        .read { db in
                            try ClosedGroup
                                .filter(id: threadId)
                                .select(.name)
                                .asRequest(of: String.self)
                                .fetchOne(db)
                        }
                        .defaulting(to: "GROUP_TITLE_FALLBACK".localized())
                    
                        MessageSender
                            .update(
                                legacyGroupSessionId: threadId,
                                with: updatedMemberIds,
                                name: currentGroupName,
                                using: dependencies
                            )
                            .eraseToAnyPublisher()
                            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                            .receive(on: DispatchQueue.main)
                            .sinkUntilComplete(
                                receiveCompletion: { [weak self] result in
                                    modalActivityIndicator.dismiss(completion: {
                                        switch result {
                                            case .finished: self?.selectedIdsSubject.send([])
                                            case .failure:
                                                self?.transitionToScreen(
                                                    ConfirmationModal(
                                                        info: ConfirmationModal.Info(
                                                            title: "ALERT_ERROR_TITLE".localized(),
                                                            body: .text("GROUP_UPDATE_ERROR_TITLE".localized()),
                                                            cancelTitle: "BUTTON_OK".localized(),
                                                            cancelStyle: .alert_text
                                                        )
                                                    ),
                                                    transitionType: .present
                                                )
                                        }
                                    })
                                }
                            )
                }
                self.transitionToScreen(viewController, transitionType: .present)
            
            default:
                self.transitionToScreen(
                    ConfirmationModal(
                        info: ConfirmationModal.Info(
                            title: "ALERT_ERROR_TITLE".localized(),
                            body: .text("GROUP_UPDATE_ERROR_TITLE".localized()),
                            cancelTitle: "BUTTON_OK".localized(),
                            cancelStyle: .alert_text
                        )
                    ),
                    transitionType: .present
                )
        }
    }
}
