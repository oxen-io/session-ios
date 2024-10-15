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
    private static let minVersionBannerInfo: InfoBanner.Info = InfoBanner.Info(
        font: .systemFont(ofSize: Values.verySmallFontSize),
        message: "groupInviteVersion".localized(),
        icon: .none,
        tintColor: .black,
        backgroundColor: .warning,
        accessibility: Accessibility(identifier: "Version warning banner")
    )
    
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let editableState: EditableState<TableItem> = EditableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    private let selectedIdsSubject: CurrentValueSubject<Set<String>, Never> = CurrentValueSubject([])
    
    private let threadId: String
    private let userSessionId: SessionId
    private var inviteByIdValue: String?
    
    // MARK: - Initialization
    
    init(threadId: String, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.userSessionId = dependencies[cache: .general].sessionId
    }
    
    // MARK: - Config
    
    public enum Section: SessionTableSection {
        case groupInfo
        case invite
        case members
        
        public var title: String? {
            switch self {
                case .members: return "groupMembers".localized()
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
        case inviteById
        
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
    
    let title: String = "groupEdit".localized()
    
    var bannerInfo: AnyPublisher<InfoBanner.Info?, Never> { Just(EditGroupViewModel.minVersionBannerInfo).eraseToAnyPublisher() }
    
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
                    .fetchAllWithProfiles(db, using: dependencies),
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
                                "errorUnknown".localized(),
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
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let isUpdatedGroup: Bool = (((try? SessionId.Prefix(from: threadId)) ?? .group) == .group)
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
                            profileIcon: .none,
                            additionalProfile: state.profileBack,
                            additionalProfileIcon: .none,
                            accessibility: nil
                        ),
                        styling: SessionCell.StyleInfo(
                            alignment: .centerHugging,
                            customPadding: SessionCell.Padding(bottom: Values.smallSpacing),
                            backgroundStyle: .noBackground
                        ),
                        accessibility: Accessibility(
                            label: "Profile picture"
                        )
                    ),
                    SessionCell.Info(
                        id: .groupName,
                        title: SessionCell.TextInfo(
                            state.group.name,
                            font: .titleLarge,
                            alignment: .center,
                            editingPlaceholder: "groupNameEnter".localized()
                        ),
                        styling: SessionCell.StyleInfo(
                            alignment: .centerHugging,
                            customPadding: SessionCell.Padding(
                                top: Values.smallSpacing,
                                bottom: Values.smallSpacing
                            ),
                            backgroundStyle: .noBackground
                        ),
                        accessibility: Accessibility(
                            identifier: "Group name text field",
                            label: state.group.name
                        )
                    ),
                    ((state.group.groupDescription ?? "").isEmpty ? nil :
                        SessionCell.Info(
                            id: .groupDescription,
                            title: SessionCell.TextInfo(
                                (state.group.groupDescription ?? ""),
                                font: .subtitle,
                                alignment: .center,
                                editingPlaceholder: "groupDescriptionEnter".localized()
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
                                identifier: "Group description text field",
                                label: (state.group.groupDescription ?? "")
                            )
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
                        title: "membersInvite".localized(),
                        accessibility: Accessibility(
                            identifier: "Add members",
                            label: "Add members"
                        ),
                        onTap: { [weak self] in self?.inviteContacts(currentGroupName: state.group.name) }
                    ),
                    (!isUpdatedGroup || !dependencies[feature: .updatedGroupsAllowInviteById] ? nil :
                        SessionCell.Info(
                            id: .inviteById,
                            leadingAccessory:  .icon(UIImage(named: "ic_plus_24")?.withRenderingMode(.alwaysTemplate)),
                            title: "accountIdOrOnsInvite".localized(),
                            accessibility: Accessibility(
                                identifier: "Invite by id",
                                label: "Invite by id"
                            ),
                            onTap: { [weak self] in self?.inviteById(currentGroupName: state.group.name) }
                        )
                    )
                ].compactMap { $0 }
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
                            title: SessionCell.TextInfo(
                                {
                                    guard memberInfo.profileId != userSessionId.hexString else { return "you".localized() }
                                    
                                    return (
                                        memberInfo.profile?.displayName() ??
                                        Profile.truncated(id: memberInfo.profileId, truncating: .middle)
                                    )
                                }(),
                                font: .title,
                                accessibility: Accessibility(
                                    identifier: "Contact"
                                )
                            ),
                            subtitle: (!isUpdatedGroup ? nil : SessionCell.TextInfo(
                                memberInfo.value.statusDescription,
                                font: .subtitle,
                                accessibility: Accessibility(
                                    identifier: "Contact status"
                                )
                            )),
                            trailingAccessory: {
                                switch (memberInfo.value.role, memberInfo.value.roleStatus) {
                                    case (.admin, _), (.moderator, _): return nil
                                    case (.standard, .failed), (.standard, .notSentYet), (.standard, .pending):
                                        return .highlightingBackgroundLabelAndRadio(
                                            title: "resend".localized(),
                                            isSelected: selectedIdsSubject.value.contains(memberInfo.profileId),
                                            labelAccessibility: Accessibility(
                                                identifier: "Resend invite button",
                                                label: "Resend invite button"
                                            ),
                                            radioAccessibility: Accessibility(
                                                identifier: "Select contact",
                                                label: "Select contact"
                                            )
                                        )
                                        
                                    case (.standard, .accepted), (.zombie, _):
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
                            onTapView: { [weak self, selectedIdsSubject] targetView in
                                let didTapResend: Bool = (targetView is SessionHighlightingBackgroundLabel)
                                
                                switch (memberInfo.value.role, memberInfo.value.roleStatus, didTapResend) {
                                    case (.moderator, _, _): return
                                    case (.admin, _, _):
                                        self?.showToast(
                                            text: "adminCannotBeRemoved".localized(),
                                            backgroundColor: .backgroundSecondary
                                        )
                                        
                                    case (.standard, .failed, true), (.standard, .notSentYet, true), (.standard, .pending, true):
                                        self?.resendInvitation(memberId: memberInfo.profileId)

                                    case (.standard, .failed, _), (.standard, .notSentYet, _), (.standard, .pending, _),
                                        (.standard, .accepted, _), (.zombie, _, _):
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
                title: "remove".localized(),
                isEnabled: !selectedIds.isEmpty,
                accessibility: Accessibility(
                    identifier: "Remove contact button"
                ),
                onTap: { [weak self] in self?.removeMembers(memberIds: selectedIds) }
            )
        }
        .eraseToAnyPublisher()
    
    // MARK: - Functions
    
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
                    title: "membersInvite".localized(),
                    infoBanner: EditGroupViewModel.minVersionBannerInfo,
                    emptyState: "contactNone".localized(),
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
                    footerTitle: "membersInviteTitle".localized(),
                    onSubmit: { [weak self, threadId, dependencies] in
                        switch try? SessionId.Prefix(from: threadId) {
                            case .group:
                                return .callback { viewModel, selectedMemberInfo in
                                    let updatedMemberIds: Set<String> = currentMemberIds
                                        .inserting(contentsOf: selectedMemberInfo.map { $0.profileId }.asSet())
                                    
                                    guard updatedMemberIds.count <= LibSession.sizeMaxGroupMemberCount else {
                                        throw UserListError.error("groupAddMemberMaximum".localized())
                                    }
                                    
                                    self?.addMembers(
                                        currentGroupName: currentGroupName,
                                        memberInfo: selectedMemberInfo.map { ($0.profileId, $0.profile) }
                                    )
                                }
                                
                            case .standard: // Assume it's a legacy group
                                return .publisher { [dependencies, threadId] _, selectedMemberInfo in
                                    let updatedMemberIds: Set<String> = currentMemberIds
                                        .inserting(contentsOf: selectedMemberInfo.map { $0.profileId }.asSet())
                                    
                                    guard updatedMemberIds.count <= LibSession.sizeMaxGroupMemberCount else {
                                        return Fail(error: .error("groupAddMemberMaximum".localized()))
                                            .eraseToAnyPublisher()
                                    }
                                    
                                    return MessageSender.update(
                                        legacyGroupSessionId: threadId,
                                        with: updatedMemberIds,
                                        name: currentGroupName,
                                        using: dependencies
                                    )
                                    .mapError { _ in UserListError.error("deleteAfterLegacyGroupsGroupUpdateErrorTitle".localized()) }
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
    
    private func inviteById(currentGroupName: String) {
        // Convenience functions to avoid duplicate code
        func showError(_ errorString: String) {
            let modal: ConfirmationModal = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "theError".localized(),
                    body: .text(errorString),
                    cancelTitle: "okay".localized(),
                    cancelStyle: .alert_text,
                    dismissType: .single
                )
            )
            self.transitionToScreen(modal, transitionType: .present)
        }
        
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
        
        // Make sure inviting another member wouldn't hit the member limit
        guard (currentMemberIds.count + 1) <= LibSession.sizeMaxGroupMemberCount else {
            return showError("groupAddMemberMaximum".localized())
        }
        
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "accountIdOrOnsInvite".localized(),
                    body: .input(
                        explanation: nil,
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "accountIdOrOnsEnter".localized()
                        ),
                        onChange: { [weak self] updatedString in self?.inviteByIdValue = updatedString }
                    ),
                    confirmTitle: "membersInviteTitle".localized(),
                    confirmStyle: .danger,
                    cancelStyle: .alert_text,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self, dependencies] modal in
                        switch (self?.inviteByIdValue, try? SessionId(from: self?.inviteByIdValue)) {
                            case (_, .some(let sessionId)) where sessionId.prefix == .standard:
                                guard !currentMemberIds.contains(sessionId.hexString) else {
                                    // FIXME: Localise this
                                    return showError("This Account ID or ONS belongs to an existing member")
                                }
                                
                                modal.dismiss(animated: true) {
                                    self?.addMembers(
                                        currentGroupName: currentGroupName,
                                        memberInfo: [(sessionId.hexString, nil)]
                                    )
                                }
                            
                            case (.none, _), (_, .some): return showError("accountIdErrorInvalid".localized())
                                
                            case (.some(let inviteByIdValue), _):
                                // This could be an ONS name
                                let viewController = ModalActivityIndicatorViewController() { modalActivityIndicator in
                                    SnodeAPI
                                        .getSessionID(for: inviteByIdValue, using: dependencies)
                                        .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                                        .receive(on: DispatchQueue.main)
                                        .sinkUntilComplete(
                                            receiveCompletion: { result in
                                                switch result {
                                                    case .finished: break
                                                    case .failure(let error):
                                                        modalActivityIndicator.dismiss {
                                                            switch error {
                                                                case SnodeAPIError.onsNotFound:
                                                                    return showError("onsErrorNotRecognized".localized())
                                                                default:
                                                                    return showError("onsErrorUnableToSearch".localized())
                                                            }
                                                        }
                                                }
                                            },
                                            receiveValue: { sessionIdHexString in
                                                guard !currentMemberIds.contains(sessionIdHexString) else {
                                                    // FIXME: Localise this
                                                    return showError("This Account ID or ONS belongs to an existing member")
                                                }
                                                
                                                modalActivityIndicator.dismiss {
                                                    modal.dismiss(animated: true) {
                                                        self?.addMembers(
                                                            currentGroupName: currentGroupName,
                                                            memberInfo: [(sessionIdHexString, nil)]
                                                        )
                                                    }
                                                }
                                            }
                                        )
                                }
                                self?.transitionToScreen(viewController, transitionType: .present)
                        }
                    },
                    afterClosed: { [weak self] in self?.inviteByIdValue = nil }
                )
            ),
            transitionType: .present
        )
    }
    
    private func addMembers(
        currentGroupName: String,
        memberInfo: [(id: String, profile: Profile?)]
    ) {
        /// Show a toast that we have sent the invitations
        self.showToast(
            text: (memberInfo.count == 1 ?
                "groupInviteSending".localized() :
                "groupInviteSending".localized()
            ),
            backgroundColor: .backgroundSecondary
        )
        
        /// Actually trigger the sending
        MessageSender
            .addGroupMembers(
                groupSessionId: threadId,
                members: memberInfo,
                allowAccessToHistoricMessages: dependencies[feature: .updatedGroupsAllowHistoricAccessOnInvite],
                using: dependencies
            )
            .sinkUntilComplete(
                receiveCompletion: { [weak self] result in
                    switch result {
                        case .finished: break
                        case .failure:
                            self?.showToast(
                                text: GroupInviteMemberJob.failureMessage(
                                    groupName: currentGroupName,
                                    memberIds: memberInfo.map { $0.id },
                                    profileInfo: memberInfo
                                        .reduce(into: [:]) { result, next in
                                            result[next.id] = next.profile
                                        }
                                ),
                                backgroundColor: .backgroundSecondary
                            )
                    }
                }
            )
    }
    
    private func resendInvitation(memberId: String) {
        MessageSender.resendInvitation(
            groupSessionId: threadId,
            memberId: memberId,
            using: dependencies
        )
        self.showToast(text: "groupInviteSending".localized())
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
                        .defaulting(to: "groupUnknown".localized())
                    
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
                                                            title: "theError".localized(),
                                                            body: .text("deleteAfterLegacyGroupsGroupUpdateErrorTitle".localized()),
                                                            cancelTitle: "okay".localized(),
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
}
