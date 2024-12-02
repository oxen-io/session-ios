// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

class SettingsViewModel: SessionTableViewModel, NavigationItemSource, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private let userSessionId: SessionId
    private var updatedName: String?
    private var onDisplayPictureSelected: ((ConfirmationModal.ValueUpdate) -> Void)?
    private lazy var imagePickerHandler: ImagePickerHandler = ImagePickerHandler(
        onTransition: { [weak self] in self?.transitionToScreen($0, transitionType: $1) },
        onImageDataPicked: { [weak self] resultImageData in
            self?.onDisplayPictureSelected?(.image(resultImageData))
        }
    )
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.userSessionId = dependencies[cache: .general].sessionId
    }
    
    // MARK: - Config
    
    enum NavItem: Equatable {
        case close
        case qrCode
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
        case developerSettings
        case clearData
    }
    
    // MARK: - NavigationItemSource
    
    lazy var leftNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = [
        SessionNavItem(
            id: .close,
            image: UIImage(named: "X")?
                .withRenderingMode(.alwaysTemplate),
            style: .plain,
            accessibilityIdentifier: "Close button"
        ) { [weak self] in self?.dismissScreen() }
    ]
    
    lazy var rightNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = [
        SessionNavItem(
            id: .qrCode,
            image: UIImage(named: "QRCode")?
                .withRenderingMode(.alwaysTemplate),
            style: .plain,
            accessibilityIdentifier: "View QR code",
            action: { [weak self, dependencies] in
                let viewController: SessionHostingViewController = SessionHostingViewController(
                    rootView: QRCodeScreen(using: dependencies)
                )
                viewController.setNavBarTitle("qrCode".localized())
                self?.transitionToScreen(viewController)
            }
        )
    ]
    
    // MARK: - Content
    
    private struct State: Equatable {
        let profile: Profile
        let developerModeEnabled: Bool
        let hideRecoveryPasswordPermanently: Bool
    }
    
    let title: String = "sessionSettings".localized()
    
    lazy var observation: TargetObservation = ObservationBuilder
        .databaseObservation(self) { [weak self, dependencies] db -> State in
            State(
                profile: Profile.fetchOrCreateCurrentUser(db, using: dependencies),
                developerModeEnabled: db[.developerModeEnabled],
                hideRecoveryPasswordPermanently: db[.hideRecoveryPasswordPermanently]
            )
        }
        .compactMap { [weak self] state -> [SectionModel]? in self?.content(state) }
    
    private func content(_ state: State) -> [SectionModel] {
        let editIcon: UIImage? = UIImage(systemName: "pencil")
        
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
                            profileIcon: {
                                switch (dependencies[feature: .serviceNetwork], dependencies[feature: .forceOffline]) {
                                    case (.testnet, false): return .letter("T", false)     // stringlint:ignore
                                    case (.testnet, true): return .letter("T", true)       // stringlint:ignore
                                    default: return .none
                                }
                            }()
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
                        onTap: { [weak self] in
                            self?.updateProfilePicture(currentFileName: state.profile.profilePictureFileName)
                        }
                    ),
                    SessionCell.Info(
                        id: .profileName,
                        leadingAccessory: .icon(
                            editIcon?.withRenderingMode(.alwaysTemplate),
                            size: .mediumAspectFill,
                            customTint: .textSecondary,
                            shouldFill: true
                        ),
                        title: SessionCell.TextInfo(
                            state.profile.displayName(),
                            font: .titleLarge,
                            alignment: .center,
                            interaction: .editable
                        ),
                        styling: SessionCell.StyleInfo(
                            alignment: .centerHugging,
                            customPadding: SessionCell.Padding(
                                top: Values.smallSpacing,
                                leading: -((IconSize.medium.size + (Values.smallSpacing * 2)) / 2),
                                bottom: Values.mediumSpacing
                            ),
                            backgroundStyle: .noBackground
                        ),
                        accessibility: Accessibility(
                            identifier: "Username",
                            label: state.profile.displayName()
                        ),
                        onTap: { [weak self] in self?.updateDisplayName(current: state.profile.displayName()) }
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
                        leadingAccessory: .button(
                            style: .bordered,
                            title: "share".localized(),
                            accessibility: Accessibility(
                                identifier: "Share button",
                                label: "Share button"
                            ),
                            run: { [weak self] _ in
                                self?.shareSessionId(state.profile.id)
                            }
                        ),
                        trailingAccessory: .button(
                            style: .bordered,
                            title: "copy".localized(),
                            accessibility: Accessibility(
                                identifier: "Copy button",
                                label: "Copy button"
                            ),
                            run: { [weak self] button in
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
                        leadingAccessory: .customView(uniqueId: "PathStatusView") { [dependencies] in // stringlint:ignore
                            // Need to ensure this view is the same size as the icons so
                            // wrap it in a larger view
                            let result: UIView = UIView()
                            let pathView: PathStatusView = PathStatusView(size: .large, using: dependencies)
                            result.addSubview(pathView)
                            
                            result.set(.width, to: IconSize.medium.size)
                            result.set(.height, to: IconSize.medium.size)
                            pathView.center(in: result)
                            
                            return result
                        },
                        title: "onionRoutingPath".localized(),
                        onTap: { [weak self, dependencies] in self?.transitionToScreen(PathVC(using: dependencies)) }
                    ),
                    SessionCell.Info(
                        id: .privacy,
                        leadingAccessory: .icon(
                            UIImage(named: "icon_privacy")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "sessionPrivacy".localized(),
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
                        title: "sessionNotifications".localized(),
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
                        title: "sessionConversations".localized(),
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
                        title: "sessionMessageRequests".localized(),
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
                        title: "sessionAppearance".localized(),
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
                        title: "sessionInviteAFriend".localized(),
                        onTap: { [weak self] in
                            let invitation: String = "accountIdShare"
                                .put(key: "app_name", value: Constants.app_name)
                                .put(key: "account_id", value: state.profile.id)
                                .put(key: "session_download_url", value: Constants.session_download_url)
                                .localized()
                            
                            self?.transitionToScreen(
                                UIActivityViewController(
                                    activityItems: [ invitation ],
                                    applicationActivities: nil
                                ),
                                transitionType: .present
                            )
                        }
                    ),
                    (state.hideRecoveryPasswordPermanently ? nil :
                        SessionCell.Info(
                            id: .recoveryPhrase,
                            leadingAccessory: .icon(
                                UIImage(named: "SessionShield")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "sessionRecoveryPassword".localized(),
                            accessibility: Accessibility(
                                identifier: "Recovery password menu item",
                                label: "Recovery password menu item"
                            ),
                            onTap: { [weak self, dependencies] in
                                guard let recoveryPasswordView: RecoveryPasswordScreen = try? RecoveryPasswordScreen(using: dependencies) else {
                                    let targetViewController: UIViewController = ConfirmationModal(
                                        info: ConfirmationModal.Info(
                                            title: "theError".localized(),
                                            body: .text("recoveryPasswordErrorLoad".localized()),
                                            cancelTitle: "okay".localized(),
                                            cancelStyle: .alert_text
                                        )
                                    )
                                    self?.transitionToScreen(targetViewController, transitionType: .present)
                                    return
                                }
                                
                                let viewController: SessionHostingViewController = SessionHostingViewController(rootView: recoveryPasswordView)
                                viewController.setNavBarTitle("sessionRecoveryPassword".localized())
                                self?.transitionToScreen(viewController)
                            }
                        )
                    ),
                    SessionCell.Info(
                        id: .help,
                        leadingAccessory: .icon(
                            UIImage(named: "icon_help")?
                                .withRenderingMode(.alwaysTemplate)
                        ),
                        title: "sessionHelp".localized(),
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
                            title: "Developer Settings",    // stringlint:ignore
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
                        title: "sessionClearData".localized(),
                        styling: SessionCell.StyleInfo(tintColor: .danger),
                        onTap: { [weak self, dependencies] in
                            self?.transitionToScreen(NukeDataModal(using: dependencies), transitionType: .present)
                        }
                    )
                ].compactMap { $0 }
            )
        ]
    }
    
    public lazy var footerView: AnyPublisher<UIView?, Never> = Just(VersionFooterView(numTaps: 9) { [weak self, dependencies] in
        /// Do nothing if developer mode is already enabled
        guard !dependencies[singleton: .storage, key: .developerModeEnabled] else { return }
        
        dependencies[singleton: .storage].write { db in
            db[.developerModeEnabled] = true
        }
    }).eraseToAnyPublisher()
    
    // MARK: - Functions
    
    private func updateDisplayName(current: String) {
        /// Set `updatedName` to `current` so we can disable the "save" button when there are no changes and don't need to worry
        /// about retrieving them in the confirmation closure
        self.updatedName = current
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "displayNameSet".localized(),
                    body: .input(
                        explanation: NSAttributedString(string: "displayNameVisible".localized()),
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "displayNameEnter".localized(),
                            initialValue: current
                        ),
                        onChange: { [weak self] updatedName in self?.updatedName = updatedName }
                    ),
                    confirmTitle: "save".localized(),
                    confirmEnabled: .afterChange { [weak self] _ in
                        self?.updatedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
                        self?.updatedName != current
                    },
                    cancelStyle: .alert_text,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self] modal in
                        guard
                            let finalDisplayName: String = (self?.updatedName ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .nullIfEmpty
                        else { return }
                        
                        /// Check if the data violates the size constraints
                        guard !Profile.isTooLong(profileName: finalDisplayName) else {
                            self?.transitionToScreen(
                                ConfirmationModal(
                                    info: ConfirmationModal.Info(
                                        title: "theError".localized(),
                                        body: .text("displayNameErrorDescriptionShorter".localized()),
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
                        self?.updateProfile(displayNameUpdate: .currentUserUpdate(finalDisplayName)) {
                            modal.dismiss(animated: true)
                        }
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func updateProfilePicture(currentFileName: String?) {
        let existingImageData: Data? = dependencies[singleton: .storage].read { [userSessionId, dependencies] db in
            DisplayPictureManager.displayPicture(db, id: .user(userSessionId.hexString), using: dependencies)
        }
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "profileDisplayPictureSet".localized(),
                    body: .image(
                        placeholderData: UIImage(named: "profile_placeholder")?.pngData(),
                        valueData: existingImageData,
                        icon: .rightPlus,
                        style: .circular,
                        accessibility: Accessibility(
                            identifier: "Upload",
                            label: "Upload"
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
                                self?.updateProfile(
                                    displayPictureUpdate: .currentUserUploadImageData(valueData),
                                    onComplete: { [weak modal] in modal?.close() }
                                )
                                
                            default: modal.close()
                        }
                    },
                    onCancel: { [weak self] modal in
                        self?.updateProfile(
                            displayPictureUpdate: .currentUserRemove,
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
                picker.mediaTypes = [ "public.image" ]  // stringlint:ignore
                picker.delegate = self?.imagePickerHandler
                
                self?.transitionToScreen(picker, transitionType: .present)
            }
        }
    }
    
    fileprivate func updateProfile(
        displayNameUpdate: Profile.DisplayNameUpdate = .none,
        displayPictureUpdate: DisplayPictureManager.Update = .none,
        onComplete: @escaping () -> ()
    ) {
        let viewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self, dependencies] modalActivityIndicator in
            Profile.updateLocal(
                queue: .global(qos: .default),
                displayNameUpdate: displayNameUpdate,
                displayPictureUpdate: displayPictureUpdate,
                success: { db in
                    // Wait for the database transaction to complete before updating the UI
                    db.afterNextTransactionNested(using: dependencies) { _ in
                        DispatchQueue.main.async {
                            modalActivityIndicator.dismiss(completion: {
                                onComplete()
                            })
                        }
                    }
                },
                failure: { [weak self] error in
                    DispatchQueue.main.async {
                        modalActivityIndicator.dismiss {
                            let message: String = {
                                switch (displayPictureUpdate, error) {
                                    case (.currentUserRemove, _): return "profileDisplayPictureRemoveError".localized()
                                    case (_, .uploadMaxFileSizeExceeded):
                                        return "profileDisplayPictureSizeError".localized()
                                    
                                    default: return "errorConnection".localized()
                                }
                            }()
                            
                            self?.transitionToScreen(
                                ConfirmationModal(
                                    info: ConfirmationModal.Info(
                                        title: "profileErrorUpdate".localized(),
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
