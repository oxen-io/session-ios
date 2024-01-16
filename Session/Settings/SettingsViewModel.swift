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
    
    private let userSessionId: SessionId
    private lazy var imagePickerHandler: ImagePickerHandler = ImagePickerHandler(
        onTransition: { [weak self] in self?.transitionToScreen($0, transitionType: $1) },
        onImageDataPicked: { [weak self] resultImageData in
            guard let oldDisplayName: String = self?.oldDisplayName else { return }
            
            self?.updatedDisplayPictureSelected(
                name: oldDisplayName,
                update: .uploadImageData(resultImageData)
            )
        }
    )
    fileprivate var oldDisplayName: String
    private var editedDisplayName: String?
    private var editProfilePictureModal: ConfirmationModal?
    private var editProfilePictureModalInfo: ConfirmationModal.Info?
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.userSessionId = getUserSessionId(using: dependencies)
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
                case .sessionId: return "your_session_id".localized()
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
        case developerSettings
        case clearData
    }
    
    // MARK: - NavigationItemSource
    
    lazy var navState: AnyPublisher<NavState, Never> = Publishers
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
        .map { [weak self, dependencies] navState -> [SessionNavItem<NavItem>] in
            switch navState {
                case .standard:
                    return [
                        SessionNavItem(
                            id: .qrCode,
                            image: UIImage(named: "QRCode")?
                                .withRenderingMode(.alwaysTemplate),
                            style: .plain,
                            accessibilityIdentifier: "Show QR code button",
                            action: { self?.transitionToScreen(QRCodeVC(using: dependencies)) }
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
                                guard !Profile.isTooLong(profileName: updatedNickname) else {
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
                                    displayPictureUpdate: .none
                                )
                            }
                        ]
            }
        }
        .eraseToAnyPublisher()

    
    // MARK: - Content
    
    private struct State: Equatable {
        let profile: Profile
        let developerModeEnabled: Bool
    }
    
    let title: String = "vc_settings_title".localized()
    
    lazy var observation: TargetObservation = ObservationBuilder
        .databaseObservation(self) { [dependencies] db -> State in
            State(
                profile: Profile.fetchOrCreateCurrentUser(db, using: dependencies),
                developerModeEnabled: db[.developerModeEnabled]
            )
        }
        .compactMap { [weak self] state -> [SectionModel]? in self?.content(state) }
    
    private func content(_ state: State) -> [SectionModel] {
        return [
            SectionModel(
                model: .profileInfo,
                elements: [
                    SessionCell.Info(
                        id: .avatar,
                        accessory: .profile(
                            id: state.profile.id,
                            size: .hero,
                            profile: state.profile,
                            profileIcon: (dependencies[feature: .serviceNetwork] == .mainnet ? .none :
                                .letter("T")    // stringlint:disable
                            )
                        ),
                        styling: SessionCell.StyleInfo(
                            alignment: .centerHugging,
                            customPadding: SessionCell.Padding(bottom: Values.smallSpacing),
                            backgroundStyle: .noBackground
                        ),
                        accessibility: Accessibility(
                            label: "Profile picture"
                        ),
                        onTap: { [weak self] in
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
                            alignment: .centerHugging,
                            customPadding: SessionCell.Padding(top: Values.smallSpacing),
                            backgroundStyle: .noBackground
                        ),
                        accessibility: Accessibility(
                            identifier: "Username",
                            label: state.profile.displayName()
                        ),
                        onTap: { [weak self] in self?.setIsEditing(true) }
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
                            identifier: "Session ID",
                            label: state.profile.id
                        )
                    ),
                    SessionCell.Info(
                        id: .idActions,
                        leadingAccessory:  .button(
                            style: .bordered,
                            title: "copy".localized(),
                            run: { [weak self] button in
                                self?.copySessionId(state.profile.id, button: button)
                            }
                        ),
                        trailingAccessory: .button(
                            style: .bordered,
                            title: "share".localized(),
                            run: { [weak self] _ in
                                self?.shareSessionId(state.profile.id)
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
                        leadingAccessory: .customView(uniqueId: "PathStatusView") {   // stringlint:disable
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
                        onTap: { [weak self, dependencies] in self?.transitionToScreen(PathVC(using: dependencies)) }
                    ),
                    SessionCell.Info(
                        id: .privacy,
                        leadingAccessory: .icon(
                            UIImage(named: "icon_privacy")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "vc_settings_privacy_button_title".localized(),
                        onTap: { [weak self, dependencies] in
                            self?.transitionToScreen(
                                SessionTableViewController(viewModel: PrivacySettingsViewModel(using: dependencies))
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .notifications,
                        leadingAccessory: .icon(
                            UIImage(named: "icon_speaker")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "vc_settings_notifications_button_title".localized(),
                        onTap: { [weak self, dependencies] in
                            self?.transitionToScreen(
                                SessionTableViewController(viewModel: NotificationSettingsViewModel(using: dependencies))
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .conversations,
                        leadingAccessory: .icon(
                            UIImage(named: "icon_msg")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "CONVERSATION_SETTINGS_TITLE".localized(),
                        onTap: { [weak self, dependencies] in
                            self?.transitionToScreen(
                                SessionTableViewController(viewModel: ConversationSettingsViewModel(using: dependencies))
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .messageRequests,
                        leadingAccessory: .icon(
                            UIImage(named: "icon_msg_req")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "MESSAGE_REQUESTS_TITLE".localized(),
                        onTap: { [weak self, dependencies] in
                            self?.transitionToScreen(
                                SessionTableViewController(viewModel: MessageRequestsViewModel(using: dependencies))
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .appearance,
                        leadingAccessory: .icon(
                            UIImage(named: "icon_apperance")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "APPEARANCE_TITLE".localized(),
                        onTap: { [weak self, dependencies] in
                            self?.transitionToScreen(AppearanceViewController(using: dependencies))
                        }
                    ),
                    SessionCell.Info(
                        id: .inviteAFriend,
                        leadingAccessory: .icon(
                            UIImage(named: "icon_invite")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "vc_settings_invite_a_friend_button_title".localized(),
                        onTap: { [weak self] in
                            let invitation: String = "Hey, I've been using Session to chat with complete privacy and security. Come join me! Download it at https://getsession.org/. My Session ID is \(state.profile.id) !"
                            
                            self?.transitionToScreen(
                                UIActivityViewController(
                                    activityItems: [ invitation ],
                                    applicationActivities: nil
                                ),
                                transitionType: .present
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .recoveryPhrase,
                        leadingAccessory: .icon(
                            UIImage(named: "icon_recovery")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "vc_settings_recovery_phrase_button_title".localized(),
                        onTap: { [weak self] in
                            let targetViewController: UIViewController = {
                                if let modal: SeedModal = try? SeedModal() {
                                    return modal
                                }
                                
                                return ConfirmationModal(
                                    info: ConfirmationModal.Info(
                                        title: "ALERT_ERROR_TITLE".localized(),
                                        body: .text("LOAD_RECOVERY_PASSWORD_ERROR".localized()),
                                        cancelTitle: "BUTTON_OK".localized(),
                                        cancelStyle: .alert_text
                                    )
                                )
                            }()
                            
                            self?.transitionToScreen(targetViewController, transitionType: .present)
                        }
                    ),
                    SessionCell.Info(
                        id: .help,
                        leadingAccessory: .icon(
                            UIImage(named: "icon_help")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "HELP_TITLE".localized(),
                        onTap: { [weak self, dependencies] in
                            self?.transitionToScreen(
                                SessionTableViewController(viewModel: HelpViewModel(using: dependencies))
                            )
                        }
                    ),
                    (!state.developerModeEnabled ? nil :
                        SessionCell.Info(
                            id: .developerSettings,
                            leadingAccessory: .icon(
                                UIImage(systemName: "wrench.and.screwdriver")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "Developer Settings",    // stringlint:disable
                            styling: SessionCell.StyleInfo(tintColor: .warning),
                            onTap: { [weak self, dependencies] in
                                self?.transitionToScreen(
                                    SessionTableViewController(viewModel: DeveloperSettingsViewModel(using: dependencies))
                                )
                            }
                        )
                    ),
                    SessionCell.Info(
                        id: .clearData,
                        leadingAccessory: .icon(
                            UIImage(named: "icon_bin")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "vc_settings_clear_all_data_button_title".localized(),
                        styling: SessionCell.StyleInfo(tintColor: .danger),
                        onTap: { [weak self] in
                            self?.transitionToScreen(NukeDataModal(), transitionType: .present)
                        }
                    )
                ].compactMap { $0 }
            )
        ]
    }
    
    public lazy var footerView: AnyPublisher<UIView?, Never> = Just(VersionFooterView(numTaps: 9) { [weak self, dependencies] in
        /// Do nothing if developer mode is already enabled
        guard !dependencies[singleton: .storage, key: .developerModeEnabled] else { return }
        
        dependencies[singleton: .storage].write(using: dependencies) { db in
            db[.developerModeEnabled] = true
        }
    }).eraseToAnyPublisher()
    
    // MARK: - Functions
    
    private func updateProfilePicture(currentFileName: String?) {
        let existingDisplayName: String = self.oldDisplayName
        let existingImageData: Data? = dependencies[singleton: .storage].read(using: dependencies) { [userSessionId] db in
            DisplayPictureManager.displayPicture(db, id: .user(userSessionId.hexString))
        }
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
                    displayPictureUpdate: .remove,
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

    fileprivate func updatedDisplayPictureSelected(name: String, update: DisplayPictureManager.Update) {
        guard let info: ConfirmationModal.Info = self.editProfilePictureModalInfo else { return }
        
        self.editProfilePictureModal?.updateContent(
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
                    self?.updateProfile(
                        name: name,
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
    
    fileprivate func updateProfile(
        name: String,
        displayPictureUpdate: DisplayPictureManager.Update,
        onComplete: (() -> ())? = nil
    ) {
        let viewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self] modalActivityIndicator in
            Profile.updateLocal(
                queue: .global(qos: .default),
                profileName: name,
                displayPictureUpdate: displayPictureUpdate,
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
                                switch (displayPictureUpdate, error) {
                                    case (.remove, _): return "update_profile_modal_remove_error_title".localized()
                                    case (_, .uploadMaxFileSizeExceeded):
                                        return "update_profile_modal_max_size_error_title".localized()
                                    
                                    default: return "update_profile_modal_error_title".localized()
                                }
                            }()
                            let message: String? = {
                                switch (displayPictureUpdate, error) {
                                    case (.remove, _): return nil
                                    case (_, .uploadMaxFileSizeExceeded):
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
