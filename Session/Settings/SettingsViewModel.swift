// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import YYImage
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

class SettingsViewModel: SessionTableViewModel, NavigationItemSource, NavigatableStateHolder, EditableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let editableState: EditableState<TableItem> = EditableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private let userSessionId: String
    private lazy var imagePickerHandler: ImagePickerHandler = ImagePickerHandler(
        onTransition: { [weak self] in self?.transitionToScreen($0, transitionType: $1) },
        onImageDataPicked: { [weak self] resultImageData in
            guard let oldDisplayName: String = self?.oldDisplayName else { return }
            
            self?.updatedProfilePictureSelected(
                name: oldDisplayName,
                avatarUpdate: .uploadImageData(resultImageData)
            )
        }
    )
    fileprivate var oldDisplayName: String
    private var editedDisplayName: String?
    private var editProfilePictureModal: ConfirmationModal?
    private var editProfilePictureModalInfo: ConfirmationModal.Info?
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
        self.userSessionId = getUserHexEncodedPublicKey(using: dependencies)
        self.oldDisplayName = Profile.fetchOrCreateCurrentUser(using: dependencies).name
    }
    
    // MARK: - Config
    
    enum NavState {
        case standard
        case editing
    }
    
    enum NavItem: Equatable {
        case close
        case qrCode
        case cancel
        case done
    }
    
    public enum Section: SessionTableSection {
        case profileInfo
        case sessionId
        case menus
        case footer
        
        var title: String? {
            switch self {
                case .sessionId: return "accountIdYours".localized()
                default: return nil
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .sessionId: return .titleSeparator
                case .menus: return .padding
                default: return .none
            }
        }
    }
    
    public enum TableItem: Differentiable {
        case avatar
        case profileName
        
        case sessionId
        case idActions
        
        case path
        case privacy
        case notifications
        case conversations
        case messageRequests
        case appearance
        case inviteAFriend
        case recoveryPhrase
        case help
        case clearData
    }
    
    // MARK: - Navigation
    
    lazy var navState: AnyPublisher<NavState, Never> = {
        Publishers
            .CombineLatest(
                isEditing,
                textChanged
                    .handleEvents(
                        receiveOutput: { [weak self] value, _ in
                            self?.editedDisplayName = value
                        }
                    )
                    .filter { _ in false }
                    .prepend((nil, .profileName))
            )
            .map { isEditing, _ -> NavState in (isEditing ? .editing : .standard) }
            .removeDuplicates()
            .prepend(.standard)     // Initial value
            .shareReplay(1)
            .eraseToAnyPublisher()
    }()

    lazy var leftNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = navState
        .map { navState -> [SessionNavItem<NavItem>] in
            switch navState {
                case .standard:
                    return [
                        SessionNavItem(
                            id: .close,
                            image: UIImage(named: "X")?
                                .withRenderingMode(.alwaysTemplate),
                            style: .plain,
                            accessibilityIdentifier: "Close button"
                        ) { [weak self] in self?.dismissScreen() }
                    ]
                   
                case .editing:
                    return [
                        SessionNavItem(
                            id: .cancel,
                            systemItem: .cancel,
                            accessibilityIdentifier: "Cancel button"
                        ) { [weak self] in
                            self?.setIsEditing(false)
                            self?.editedDisplayName = self?.oldDisplayName
                        }
                    ]
            }
        }
        .eraseToAnyPublisher()
    
    lazy var rightNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = navState
        .map { [weak self] navState -> [SessionNavItem<NavItem>] in
            switch navState {
                case .standard:
                    return [
                        SessionNavItem(
                            id: .qrCode,
                            image: UIImage(named: "QRCode")?
                                .withRenderingMode(.alwaysTemplate),
                            style: .plain,
                            accessibilityIdentifier: "View QR code",
                            action: { [weak self] in
                                let viewController: SessionHostingViewController = SessionHostingViewController(rootView: QRCodeScreen())
                                viewController.setNavBarTitle("vc_qr_code_title".localized())
                                self?.transitionToScreen(viewController)
                            }
                        )
                    ]
                       
                    case .editing:
                        return [
                            SessionNavItem(
                                id: .done,
                                systemItem: .done,
                                accessibilityIdentifier: "Done"
                            ) { [weak self] in
                                let updatedNickname: String = (self?.editedDisplayName ?? "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                
                                guard !updatedNickname.isEmpty else {
                                    self?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "vc_settings_display_name_missing_error".localized(),
                                                cancelTitle: "BUTTON_OK".localized(),
                                                cancelStyle: .alert_text
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                    return
                                }
                                guard !ProfileManager.isTooLong(profileName: updatedNickname) else {
                                    self?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "vc_settings_display_name_too_long_error".localized(),
                                                cancelTitle: "BUTTON_OK".localized(),
                                                cancelStyle: .alert_text
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                    return
                                }
                                
                                self?.setIsEditing(false)
                                self?.oldDisplayName = updatedNickname
                                self?.updateProfile(
                                    name: updatedNickname,
                                    avatarUpdate: .none
                                )
                            }
                        ]
                }
            }
            .eraseToAnyPublisher()
    
    // MARK: - Content
    private struct State: Equatable {
        let profile: Profile
        let hideRecoveryPasswordPermanently: Bool
    }
    
    let title: String = "vc_settings_title".localized()
    
    lazy var observation: TargetObservation = ObservationBuilder
        .databaseObservation(self) { [weak self, dependencies] db -> State in
            State(
                profile: Profile.fetchOrCreateCurrentUser(db, using: dependencies),
                hideRecoveryPasswordPermanently: db[.hideRecoveryPasswordPermanently]
            )
        }
        .map { [weak self] state -> [SectionModel] in
            return [
                SectionModel(
                    model: .profileInfo,
                    elements: [
                        SessionCell.Info(
                            id: .avatar,
                            accessory: .profile(
                                id: state.profile.id,
                                size: .hero,
                                profile: state.profile
                            ),
                            styling: SessionCell.StyleInfo(
                                alignment: .centerHugging,
                                customPadding: SessionCell.Padding(bottom: Values.smallSpacing),
                                backgroundStyle: .noBackground
                            ),
                            accessibility: Accessibility(
                                identifier: "User settings",
                                label: "Profile picture"
                            ),
                            onTap: {
                                self?.updateProfilePicture(currentFileName: state.profile.profilePictureFileName)
                            }
                        ),
                        SessionCell.Info(
                            id: .profileName,
                            title: SessionCell.TextInfo(
                                state.profile.displayName(),
                                font: .titleLarge,
                                alignment: .center,
                                interaction: .editable
                            ),
                            styling: SessionCell.StyleInfo(
                                customPadding: SessionCell.Padding(top: Values.smallSpacing),
                                backgroundStyle: .noBackground
                            ),
                            accessibility: Accessibility(
                                identifier: "Username",
                                label: state.profile.displayName()
                            ),
                            onTap: { self?.setIsEditing(true) }
                        )
                    ]
                ),
                SectionModel(
                    model: .sessionId,
                    elements: [
                        SessionCell.Info(
                            id: .sessionId,
                            title: SessionCell.TextInfo(
                                state.profile.id,
                                font: .monoLarge,
                                alignment: .center,
                                interaction: .copy
                            ),
                            styling: SessionCell.StyleInfo(
                                customPadding: SessionCell.Padding(bottom: Values.smallSpacing),
                                backgroundStyle: .noBackground
                            ),
                            accessibility: Accessibility(
                                identifier: "Account ID",
                                label: state.profile.id
                            )
                        ),
                        SessionCell.Info(
                            id: .idActions,
                            leftAccessory: .button(
                                style: .bordered,
                                title: "share".localized(),
                                accessibility: Accessibility(
                                    identifier: "Share button",
                                    label: "Share button"
                                ),
                                run: { _ in
                                    self?.shareSessionId(state.profile.id)
                                }
                            ),
                            rightAccessory: .button(
                                style: .bordered,
                                title: "copy".localized(),
                                accessibility: Accessibility(
                                    identifier: "Copy button",
                                    label: "Copy button"
                                ),
                                run: { button in
                                    self?.copySessionId(state.profile.id, button: button)
                                }
                            ),
                            styling: SessionCell.StyleInfo(
                                customPadding: SessionCell.Padding(
                                    top: Values.smallSpacing,
                                    leading: 0,
                                    trailing: 0
                                ),
                                backgroundStyle: .noBackground
                            )
                        )
                    ]
                ),
                SectionModel(
                    model: .menus,
                    elements: [
                        SessionCell.Info(
                            id: .path,
                            leftAccessory: .customView(hashValue: "PathStatusView") {   // stringlint:disable
                                // Need to ensure this view is the same size as the icons so
                                // wrap it in a larger view
                                let result: UIView = UIView()
                                let pathView: PathStatusView = PathStatusView(size: .large)
                                result.addSubview(pathView)
                                
                                result.set(.width, to: IconSize.medium.size)
                                result.set(.height, to: IconSize.medium.size)
                                pathView.center(in: result)
                                
                                return result
                            },
                            title: "vc_path_title".localized(),
                            onTap: { self?.transitionToScreen(PathVC()) }
                        ),
                        SessionCell.Info(
                            id: .privacy,
                            leftAccessory: .icon(
                                UIImage(named: "icon_privacy")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "vc_settings_privacy_button_title".localized(),
                            onTap: {
                                self?.transitionToScreen(
                                    SessionTableViewController(viewModel: PrivacySettingsViewModel())
                                )
                            }
                        ),
                        SessionCell.Info(
                            id: .notifications,
                            leftAccessory: .icon(
                                UIImage(named: "icon_speaker")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "vc_settings_notifications_button_title".localized(),
                            onTap: {
                                self?.transitionToScreen(
                                    SessionTableViewController(viewModel: NotificationSettingsViewModel())
                                )
                            }
                        ),
                        SessionCell.Info(
                            id: .conversations,
                            leftAccessory: .icon(
                                UIImage(named: "icon_msg")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "CONVERSATION_SETTINGS_TITLE".localized(),
                            onTap: {
                                self?.transitionToScreen(
                                    SessionTableViewController(viewModel: ConversationSettingsViewModel())
                                )
                            }
                        ),
                        SessionCell.Info(
                            id: .messageRequests,
                            leftAccessory: .icon(
                                UIImage(named: "icon_msg_req")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "MESSAGE_REQUESTS_TITLE".localized(),
                            onTap: {
                                self?.transitionToScreen(
                                    SessionTableViewController(viewModel: MessageRequestsViewModel())
                                )
                            }
                        ),
                        SessionCell.Info(
                            id: .appearance,
                            leftAccessory: .icon(
                                UIImage(named: "icon_apperance")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "APPEARANCE_TITLE".localized(),
                            onTap: {
                                self?.transitionToScreen(AppearanceViewController())
                            }
                        ),
                        SessionCell.Info(
                            id: .inviteAFriend,
                            leftAccessory: .icon(
                                UIImage(named: "icon_invite")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "vc_settings_invite_a_friend_button_title".localized(),
                            onTap: {
                                let invitation: String = "Hey, I've been using Session to chat with complete privacy and security. Come join me! Download it at https://getsession.org/. My Session ID is \(state.profile.id) !"
                                
                                self?.transitionToScreen(
                                    UIActivityViewController(
                                        activityItems: [ invitation ],
                                        applicationActivities: nil
                                    ),
                                    transitionType: .present
                                )
                            }
                        )
                    ].appending(
                        state.hideRecoveryPasswordPermanently ? nil :
                        SessionCell.Info(
                            id: .recoveryPhrase,
                            leftAccessory: .icon(
                                UIImage(named: "SessionShield")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "sessionRecoveryPassword".localized(),
                            accessibility: Accessibility(
                                identifier: "Recovery password menu item",
                                label: "Recovery password menu item"
                            ),
                            onTap: {
                                if let recoveryPasswordView: RecoveryPasswordScreen = try? RecoveryPasswordScreen() {
                                    let viewController: SessionHostingViewController = SessionHostingViewController(rootView: recoveryPasswordView)
                                    viewController.setNavBarTitle("sessionRecoveryPassword".localized())
                                    self?.transitionToScreen(viewController)
                                } else {
                                    let targetViewController: UIViewController = ConfirmationModal(
                                        info: ConfirmationModal.Info(
                                            title: "ALERT_ERROR_TITLE".localized(),
                                            body: .text("LOAD_RECOVERY_PASSWORD_ERROR".localized()),
                                            cancelTitle: "BUTTON_OK".localized(),
                                            cancelStyle: .alert_text
                                        )
                                    )
                                    self?.transitionToScreen(targetViewController, transitionType: .present)
                                }
                            }
                        )
                    ).appending(
                        contentsOf: [
                            SessionCell.Info(
                                id: .help,
                                leftAccessory: .icon(
                                    UIImage(named: "icon_help")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "HELP_TITLE".localized(),
                                onTap: {
                                    self?.transitionToScreen(
                                        SessionTableViewController(viewModel: HelpViewModel())
                                    )
                                }
                            ),
                            SessionCell.Info(
                                id: .clearData,
                                leftAccessory: .icon(
                                    UIImage(named: "icon_bin")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "vc_settings_clear_all_data_button_title".localized(),
                                styling: SessionCell.StyleInfo(tintColor: .danger),
                                onTap: {
                                    self?.transitionToScreen(NukeDataModal(), transitionType: .present)
                                }
                            )
                        ]
                    )
                )
            ]
        }
    
    public let footerView: AnyPublisher<UIView?, Never> = Just(VersionFooterView()).eraseToAnyPublisher()
    
    // MARK: - Functions
    
    private func updateProfilePicture(currentFileName: String?) {
        let existingDisplayName: String = self.oldDisplayName
        let existingImageData: Data? = ProfileManager
            .profileAvatar(id: self.userSessionId)
        let editProfilePictureModalInfo: ConfirmationModal.Info = ConfirmationModal.Info(
            title: "update_profile_modal_title".localized(),
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
                self?.updateProfile(
                    name: existingDisplayName,
                    avatarUpdate: .remove,
                    onComplete: { [weak modal] in modal?.close() }
                )
            },
            afterClosed: { [weak self] in
                self?.editProfilePictureModal = nil
                self?.editProfilePictureModalInfo = nil
            }
        )
        let modal: ConfirmationModal = ConfirmationModal(info: editProfilePictureModalInfo)
            
        self.editProfilePictureModalInfo = editProfilePictureModalInfo
        self.editProfilePictureModal = modal
        self.transitionToScreen(modal, transitionType: .present)
    }

    fileprivate func updatedProfilePictureSelected(name: String, avatarUpdate: ProfileManager.AvatarUpdate) {
        guard let info: ConfirmationModal.Info = self.editProfilePictureModalInfo else { return }
        
        self.editProfilePictureModal?.updateContent(
            with: info.with(
                body: .image(
                    placeholderData: UIImage(named: "profile_placeholder")?.pngData(),
                    valueData: {
                        switch avatarUpdate {
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
                    self?.updateProfile(
                        name: name,
                        avatarUpdate: avatarUpdate,
                        onComplete: { [weak modal] in modal?.close() }
                    )
                }
            )
        )
    }
    
    private func showPhotoLibraryForAvatar() {
        Permissions.requestLibraryPermissionIfNeeded { [weak self] in
            DispatchQueue.main.async {
                let picker: UIImagePickerController = UIImagePickerController()
                picker.sourceType = .photoLibrary
                picker.mediaTypes = [ "public.image" ]  // stringlint:disable
                picker.delegate = self?.imagePickerHandler
                
                self?.transitionToScreen(picker, transitionType: .present)
            }
        }
    }
    
    fileprivate func updateProfile(
        name: String,
        avatarUpdate: ProfileManager.AvatarUpdate,
        onComplete: (() -> ())? = nil
    ) {
        let viewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self] modalActivityIndicator in
            ProfileManager.updateLocal(
                queue: .global(qos: .default),
                profileName: name,
                avatarUpdate: avatarUpdate,
                success: { db in
                    // Wait for the database transaction to complete before updating the UI
                    db.afterNextTransactionNested { _ in
                        DispatchQueue.main.async {
                            modalActivityIndicator.dismiss(completion: {
                                onComplete?()
                            })
                        }
                    }
                },
                failure: { [weak self] error in
                    DispatchQueue.main.async {
                        modalActivityIndicator.dismiss {
                            let title: String = {
                                switch (avatarUpdate, error) {
                                    case (.remove, _): return "update_profile_modal_remove_error_title".localized()
                                    case (_, .avatarUploadMaxFileSizeExceeded):
                                        return "update_profile_modal_max_size_error_title".localized()
                                    
                                    default: return "update_profile_modal_error_title".localized()
                                }
                            }()
                            let message: String? = {
                                switch (avatarUpdate, error) {
                                    case (.remove, _): return nil
                                    case (_, .avatarUploadMaxFileSizeExceeded):
                                        return "update_profile_modal_max_size_error_message".localized()
                                    
                                    default: return "update_profile_modal_error_message".localized()
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
                }
            )
        }
        
        self.transitionToScreen(viewController, transitionType: .present)
    }
    
    private func copySessionId(_ sessionId: String, button: SessionButton?) {
        UIPasteboard.general.string = sessionId
        
        guard let button: SessionButton = button else { return }
        
        // Ensure we are on the main thread just in case
        DispatchQueue.main.async {
            button.isUserInteractionEnabled = false
            
            UIView.transition(
                with: button,
                duration: 0.25,
                options: .transitionCrossDissolve,
                animations: {
                    button.setTitle("copied".localized(), for: .normal)
                },
                completion: { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(4)) {
                        button.isUserInteractionEnabled = true
                    
                        UIView.transition(
                            with: button,
                            duration: 0.25,
                            options: .transitionCrossDissolve,
                            animations: {
                                button.setTitle("copy".localized(), for: .normal)
                            },
                            completion: nil
                        )
                    }
                }
            )
        }
    }
    
    private func shareSessionId(_ sessionId: String) {
        let shareVC = UIActivityViewController(
            activityItems: [ sessionId ],
            applicationActivities: nil
        )
        
        self.transitionToScreen(shareVC, transitionType: .present)
    }
}
