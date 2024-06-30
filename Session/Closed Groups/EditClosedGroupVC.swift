// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

final class EditClosedGroupVC: BaseVC, UITableViewDataSource, UITableViewDelegate {
    private struct GroupMemberDisplayInfo: FetchableRecord, Equatable, Hashable, Decodable, Differentiable {
        let profileId: String
        let role: GroupMember.Role
        let profile: Profile?
        let accessibilityLabel: String?
        let accessibilityId: String?
    }
    
    private let threadId: String
    private let threadVariant: SessionThread.Variant
    private var originalName: String = ""
    private var originalMembersAndZombieIds: Set<String> = []
    private var name: String = ""
    private var hasContactsToAdd: Bool = false
    private var userPublicKey: String = ""
    private var membersAndZombies: [GroupMemberDisplayInfo] = []
    private var adminIds: Set<String> = []
    private var isEditingGroupName = false { didSet { handleIsEditingGroupNameChanged() } }
    private var tableViewHeightConstraint: NSLayoutConstraint!

    // MARK: - Components
    
    private lazy var groupNameLabel: UILabel = {
        let result: UILabel = UILabel()
        result.accessibilityLabel = "Group name"
        result.isAccessibilityElement = true
        result.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byTruncatingTail
        result.textAlignment = .center
        
        return result
    }()

    private lazy var groupNameTextField: TextField = {
        let result: TextField = TextField(
            placeholder: "groupNameEnter".localized(),
            usesDefaultHeight: false
        )
        result.textAlignment = .center
        result.isAccessibilityElement = true
        result.accessibilityIdentifier = "Group name text field"
        
        return result
    }()

    private lazy var addMembersButton: SessionButton = {
        let result: SessionButton = SessionButton(style: .bordered, size: .medium)
        result.accessibilityLabel = "Add members"
        result.isAccessibilityElement = true
        result.setTitle("membersInvite".localized(), for: .normal)
        result.addTarget(self, action: #selector(addMembers), for: UIControl.Event.touchUpInside)
        result.contentEdgeInsets = UIEdgeInsets(top: 0, leading: Values.mediumSpacing, bottom: 0, trailing: Values.mediumSpacing)
        
        return result
    }()

    @objc private lazy var tableView: UITableView = {
        let result: UITableView = UITableView()
        result.accessibilityLabel = "Contact"
        result.accessibilityIdentifier = "Contact"
        result.isAccessibilityElement = true
        result.dataSource = self
        result.delegate = self
        result.separatorStyle = .none
        result.themeBackgroundColor = .clear
        result.isScrollEnabled = false
        result.register(view: SessionCell.self)
        
        return result
    }()

    // MARK: - Lifecycle
    
    init(threadId: String, threadVariant: SessionThread.Variant) {
        self.threadId = threadId
        self.threadVariant = threadVariant
        
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        preconditionFailure("Use init(with:) instead.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        setNavBarTitle("groupEdit".localized())
        
        let threadId: String = self.threadId
        
        Storage.shared.read { [weak self] db in
            let userPublicKey: String = getUserHexEncodedPublicKey(db)
            self?.userPublicKey = userPublicKey
            self?.name = try ClosedGroup
                .select(.name)
                .filter(id: threadId)
                .asRequest(of: String.self)
                .fetchOne(db)
                .defaulting(to: "groupUnknown".localized())
            self?.originalName = (self?.name ?? "")
            
            let profileAlias: TypedTableAlias<Profile> = TypedTableAlias()
            let allGroupMembers: [GroupMemberDisplayInfo] = try GroupMember
                .filter(GroupMember.Columns.groupId == threadId)
                .including(optional: GroupMember.profile.aliased(profileAlias))
                .order(
                    (GroupMember.Columns.role == GroupMember.Role.zombie), // Non-zombies at the top
                    profileAlias[.nickname],
                    profileAlias[.name],
                    GroupMember.Columns.profileId
                )
                .asRequest(of: GroupMemberDisplayInfo.self)
                .fetchAll(db)
            self?.membersAndZombies = allGroupMembers
                .filter { $0.role == .standard || $0.role == .zombie }
            self?.adminIds = allGroupMembers
                .filter { $0.role == .admin }
                .map { $0.profileId }
                .asSet()
            
            let uniqueGroupMemberIds: Set<String> = allGroupMembers
                .map { $0.profileId }
                .asSet()
            self?.originalMembersAndZombieIds = uniqueGroupMemberIds
            self?.hasContactsToAdd = ((try? Profile
                .allContactProfiles(
                    excluding: uniqueGroupMemberIds.inserting(userPublicKey)
                )
                .fetchCount(db))
                .defaulting(to: 0) > 0)
        }
        
        setUpViewHierarchy()
        updateNavigationBarButtons()
        handleMembersChanged()
    }

    private func setUpViewHierarchy() {
        // Group name container
        groupNameLabel.text = name
        
        let groupNameContainer = UIView()
        groupNameContainer.addSubview(groupNameLabel)
        groupNameLabel.pin(to: groupNameContainer)
        groupNameContainer.addSubview(groupNameTextField)
        groupNameTextField.pin(to: groupNameContainer)
        groupNameContainer.set(.height, to: 40)
        groupNameTextField.alpha = 0
        
        // Top container
        let topContainer = UIView()
        topContainer.addSubview(groupNameContainer)
        groupNameContainer.center(in: topContainer)
        topContainer.set(.height, to: 40)
        let topContainerTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(showEditGroupNameUI))
        topContainer.addGestureRecognizer(topContainerTapGestureRecognizer)
        
        // Members label
        let membersLabel = UILabel()
        membersLabel.font = .systemFont(ofSize: Values.mediumFontSize)
        membersLabel.themeTextColor = .textPrimary
        membersLabel.text = "groupMembers".localized()
        
        addMembersButton.isEnabled = self.hasContactsToAdd
        
        // Middle stack view
        let middleStackView = UIStackView(arrangedSubviews: [ membersLabel, addMembersButton ])
        middleStackView.axis = .horizontal
        middleStackView.alignment = .center
        middleStackView.layoutMargins = UIEdgeInsets(top: Values.smallSpacing, leading: Values.mediumSpacing, bottom: Values.smallSpacing, trailing: Values.mediumSpacing)
        middleStackView.isLayoutMarginsRelativeArrangement = true
        middleStackView.set(.height, to: Values.largeButtonHeight + Values.smallSpacing * 2)
        
        // Table view
        tableViewHeightConstraint = tableView.set(.height, to: 0)
        
        // Main stack view
        let mainStackView = UIStackView(arrangedSubviews: [
            UIView.vSpacer(Values.veryLargeSpacing),
            topContainer,
            UIView.vSpacer(Values.veryLargeSpacing),
            UIView.separator(),
            middleStackView,
            UIView.separator(),
            tableView
        ])
        mainStackView.axis = .vertical
        mainStackView.alignment = .fill
        mainStackView.set(.width, to: UIScreen.main.bounds.width)
        
        // Scroll view
        let scrollView = UIScrollView()
        scrollView.showsVerticalScrollIndicator = false
        scrollView.addSubview(mainStackView)
        mainStackView.pin(to: scrollView)
        view.addSubview(scrollView)
        scrollView.pin(to: view)
    }

    // MARK: - Table View Data Source / Delegate
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return membersAndZombies.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: SessionCell = tableView.dequeue(type: SessionCell.self, for: indexPath)
        let displayInfo: GroupMemberDisplayInfo = membersAndZombies[indexPath.row]
        cell.update(
            with: SessionCell.Info(
                id: displayInfo,
                position: Position.with(indexPath.row, count: membersAndZombies.count),
                leftAccessory: .profile(id: displayInfo.profileId, profile: displayInfo.profile),
                title: (
                    displayInfo.profile?.displayName() ??
                    Profile.truncated(id: displayInfo.profileId, threadVariant: .contact)
                ),
                rightAccessory: (adminIds.contains(userPublicKey) ? nil :
                    .icon(
                        UIImage(named: "ic_lock_outline")?
                            .withRenderingMode(.alwaysTemplate),
                        customTint: .textSecondary
                    )
                ),
                styling: SessionCell.StyleInfo(backgroundStyle: .edgeToEdge)
            )
        )
        
        return cell
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return adminIds.contains(userPublicKey)
    }
    
    func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath) {
        UIContextualAction.willBeginEditing(indexPath: indexPath, tableView: tableView)
    }
    
    func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?) {
        UIContextualAction.didEndEditing(indexPath: indexPath, tableView: tableView)
    }
    
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let profileId: String = self.membersAndZombies[indexPath.row].profileId
        
        let delete: UIContextualAction = UIContextualAction(
            title: "remove".localized(),
            icon: UIImage(named: "icon_bin"),
            themeTintColor: .white,
            themeBackgroundColor: .conversationButton_swipeDestructive,
            side: .trailing,
            actionIndex: 0,
            indexPath: indexPath,
            tableView: tableView
        ) { [weak self] _, _, completionHandler in
            self?.adminIds.remove(profileId)
            self?.membersAndZombies.remove(at: indexPath.row)
            self?.handleMembersChanged()
            
            completionHandler(true)
        }
        
        return UISwipeActionsConfiguration(actions: [ delete ])
    }

    // MARK: - Updating
    
    private func updateNavigationBarButtons() {
        if isEditingGroupName {
            let cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(handleCancelGroupNameEditingButtonTapped))
            cancelButton.themeTintColor = .textPrimary
            navigationItem.leftBarButtonItem = cancelButton
        }
        else {
            navigationItem.leftBarButtonItem = nil
        }
        
        let doneButton = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(handleDoneButtonTapped))
        if isEditingGroupName {
            doneButton.accessibilityLabel = "Accept name change"
        }
        else {
            doneButton.accessibilityLabel = "Apply changes"
        }
        doneButton.themeTintColor = .textPrimary
        navigationItem.rightBarButtonItem = doneButton
    }

    private func handleMembersChanged() {
        tableViewHeightConstraint.constant = CGFloat(membersAndZombies.count) * 78
        tableView.reloadData()
    }

    private func handleIsEditingGroupNameChanged() {
        updateNavigationBarButtons()
        
        UIView.animate(withDuration: 0.25) {
            self.groupNameLabel.alpha = self.isEditingGroupName ? 0 : 1
            self.groupNameTextField.alpha = self.isEditingGroupName ? 1 : 0
        }
        
        if isEditingGroupName {
            groupNameTextField.becomeFirstResponder()
        }
        else {
            groupNameTextField.resignFirstResponder()
        }
    }

    // MARK: - Interaction
    
    @objc private func showEditGroupNameUI() {
        isEditingGroupName = true
    }

    @objc private func handleCancelGroupNameEditingButtonTapped() {
        isEditingGroupName = false
    }

    @objc private func handleDoneButtonTapped() {
        if isEditingGroupName {
            updateGroupName()
        }
        else {
            commitChanges()
        }
    }

    private func updateGroupName() {
        let updatedName: String = groupNameTextField.text
            .defaulting(to: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        
        guard !updatedName.isEmpty else {
            return showError(title: "groupNameEnterPlease".localized())
        }
        guard updatedName.utf8CString.count < LibSession.libSessionMaxGroupNameByteLength else {
            return showError(title: "groupNameEnterShorter".localized())
        }
        
        self.isEditingGroupName = false
        self.groupNameLabel.text = updatedName
        self.name = updatedName
    }

    @objc private func addMembers() {
        let title: String = "membersInvite".localized()
        
        let userPublicKey: String = self.userPublicKey
        let userSelectionVC: UserSelectionVC = UserSelectionVC(
            with: title,
            excluding: membersAndZombies
                .map { $0.profileId }
                .asSet()
        ) { [weak self] selectedUserIds in
            Storage.shared.read { [weak self] db in
                let selectedGroupMembers: [GroupMemberDisplayInfo] = try Profile
                    .filter(selectedUserIds.contains(Profile.Columns.id))
                    .fetchAll(db)
                    .map { profile in
                        GroupMemberDisplayInfo(
                            profileId: profile.id,
                            role: .standard,
                            profile: profile,
                            accessibilityLabel: "Contact",
                            accessibilityId: "Contact"
                        )
                    }
                self?.membersAndZombies = (self?.membersAndZombies ?? [])
                    .appending(contentsOf: selectedGroupMembers)
                    .sorted(by: { lhs, rhs in
                        if lhs.role == .zombie && rhs.role != .zombie {
                            return false
                        }
                        else if lhs.role != .zombie && rhs.role == .zombie {
                            return true
                        }
                        
                        let lhsDisplayName: String = Profile.displayName(
                            for: .contact,
                            id: lhs.profileId,
                            name: lhs.profile?.name,
                            nickname: lhs.profile?.nickname,
                            suppressId: false
                        )
                        let rhsDisplayName: String = Profile.displayName(
                            for: .contact,
                            id: rhs.profileId,
                            name: rhs.profile?.name,
                            nickname: rhs.profile?.nickname,
                            suppressId: false
                        )
                        
                        return (lhsDisplayName < rhsDisplayName)
                    })
                    .filter { $0.role == .standard || $0.role == .zombie }
                
                let uniqueGroupMemberIds: Set<String> = (self?.membersAndZombies ?? [])
                    .map { $0.profileId }
                    .asSet()
                    .inserting(contentsOf: self?.adminIds)
                self?.hasContactsToAdd = ((try? Profile
                    .allContactProfiles(
                        excluding: uniqueGroupMemberIds.inserting(userPublicKey)
                    )
                    .fetchCount(db))
                    .defaulting(to: 0) > 0)
            }
            
            self?.addMembersButton.isEnabled = (self?.hasContactsToAdd == true)
            self?.handleMembersChanged()
        }
        
        navigationController?.pushViewController(userSelectionVC, animated: true, completion: nil)
    }

    private func commitChanges() {
        let popToConversationVC: ((EditClosedGroupVC?) -> ()) = { editVC in
            guard
                let viewControllers: [UIViewController] = editVC?.navigationController?.viewControllers,
                let conversationVC: ConversationVC = viewControllers.first(where: { $0 is ConversationVC }) as? ConversationVC
            else {
                editVC?.navigationController?.popViewController(animated: true)
                return
            }
            
            editVC?.navigationController?.popToViewController(conversationVC, animated: true)
        }
        
        let threadId: String = self.threadId
        let updatedName: String = self.name
        let userPublicKey: String = self.userPublicKey
        let updatedMemberIds: Set<String> = self.membersAndZombies
            .map { $0.profileId }
            .asSet()
        
        guard updatedMemberIds != self.originalMembersAndZombieIds || updatedName != self.originalName else {
            return popToConversationVC(self)
        }
        
        if !updatedMemberIds.contains(userPublicKey) {
            guard self.originalMembersAndZombieIds.removing(userPublicKey) == updatedMemberIds else {
                return showError(
                    title: "GROUP_UPDATE_ERROR_TITLE".localized(),
                    message: "deleteAfterGroupPR3GroupErrorLeave".localized()
                )
            }
        }
        guard updatedMemberIds.count <= 100 else {
            return showError(title: "groupAddMemberMaximum".localized())
        }
        
        ModalActivityIndicatorViewController.present(fromViewController: navigationController) { _ in
            Storage.shared
                .writePublisher { db in
                    // If the user is no longer a member then leave the group
                    guard !updatedMemberIds.contains(userPublicKey) else { return }

                    try MessageSender.leave(
                        db,
                        groupPublicKey: threadId,
                        deleteThread: true
                    )
                    
                }
                .flatMap {
                    MessageSender.update(
                        groupPublicKey: threadId,
                        with: updatedMemberIds,
                        name: updatedName
                    )
                }
                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                .receive(on: DispatchQueue.main)
                .sinkUntilComplete(
                    receiveCompletion: { [weak self] result in
                        self?.dismiss(animated: true, completion: nil) // Dismiss the loader
                        
                        switch result {
                            case .finished: popToConversationVC(self)
                            case .failure(let error):
                                self?.showError(
                                    title: "GROUP_UPDATE_ERROR_TITLE".localized(),
                                    message: error.localizedDescription
                                )
                        }
                    }
                )
        }
    }

    // MARK: - Convenience
    
    private func showError(title: String, message: String = "") {
        let modal: ConfirmationModal = ConfirmationModal(
            targetView: self.view,
            info: ConfirmationModal.Info(
                title: title,
                body: .text(message),
                cancelTitle: "okay".localized(),
                cancelStyle: .alert_text
            )
        )
        self.present(modal, animated: true)
    }
}
