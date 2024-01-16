// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import CryptoKit
import GRDB
import DifferenceKit
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalCoreKit

class DeveloperSettingsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private var databaseKeyEncryptionPassword: String = ""
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Section
    
    public enum Section: SessionTableSection {
        case developerMode
        case network
        case disappearingMessages
        case groups
        case database
        
        var title: String? {
            switch self {
                case .developerMode: return nil
                case .network: return "Network"
                case .disappearingMessages: return "Disappearing Messages"
                case .groups: return "Groups"
                case .database: return "Database"
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .developerMode: return .padding
                default: return .titleRoundedContent
            }
        }
    }
    
    public enum TableItem: Differentiable, CaseIterable {
        case developerMode
        
        case serviceNetwork
        case networkLayer
        
        case updatedDisappearingMessages
        case debugDisappearingMessageDurations
        
        case updatedGroups
        case updatedGroupsDisableAutoApprove
        case updatedGroupsRemoveMessagesOnKick
        case updatedGroupsAllowHistoricAccessOnInvite
        case updatedGroupsAllowDisplayPicture
        case updatedGroupsAllowDescriptionEditing
        case updatedGroupsAllowPromotions
        
        case exportDatabase
    }
    
    // MARK: - Content
    
    private struct State: Equatable {
        let developerMode: Bool
        
        let serviceNetwork: ServiceNetwork
        let networkLayer: Network.Layers
        
        let debugDisappearingMessageDurations: Bool
        let updatedDisappearingMessages: Bool
        
        let updatedGroups: Bool
        let updatedGroupsDisableAutoApprove: Bool
        let updatedGroupsRemoveMessagesOnKick: Bool
        let updatedGroupsAllowHistoricAccessOnInvite: Bool
        let updatedGroupsAllowDisplayPicture: Bool
        let updatedGroupsAllowDescriptionEditing: Bool
        let updatedGroupsAllowPromotions: Bool
    }
    
    let title: String = "Developer Settings"
    
    lazy var observation: TargetObservation = ObservationBuilder
        .refreshableData(self) { [dependencies] () -> State in
            State(
                developerMode: dependencies[singleton: .storage, key: .developerModeEnabled],
                serviceNetwork: dependencies[feature: .serviceNetwork],
                networkLayer: dependencies[feature: .networkLayers],
                debugDisappearingMessageDurations: dependencies[feature: .debugDisappearingMessageDurations],
                updatedDisappearingMessages: dependencies[feature: .updatedDisappearingMessages],
                updatedGroups: dependencies[feature: .updatedGroups],
                updatedGroupsDisableAutoApprove: dependencies[feature: .updatedGroupsDisableAutoApprove],
                updatedGroupsRemoveMessagesOnKick: dependencies[feature: .updatedGroupsRemoveMessagesOnKick],
                updatedGroupsAllowHistoricAccessOnInvite: dependencies[feature: .updatedGroupsAllowHistoricAccessOnInvite],
                updatedGroupsAllowDisplayPicture: dependencies[feature: .updatedGroupsAllowDisplayPicture],
                updatedGroupsAllowDescriptionEditing: dependencies[feature: .updatedGroupsAllowDescriptionEditing],
                updatedGroupsAllowPromotions: dependencies[feature: .updatedGroupsAllowPromotions]
            )
        }
        .compactMapWithPrevious { [weak self] prev, current -> [SectionModel]? in self?.content(prev, current) }
    
    private func content(_ previous: State?, _ current: State) -> [SectionModel] {
        return [
            SectionModel(
                model: .developerMode,
                elements: [
                    SessionCell.Info(
                        id: .developerMode,
                        title: "Developer Mode",
                        subtitle: """
                        Grants access to this screen.
                        
                        Disabling this setting will:
                        • Reset all the below settings to default (removing data as described below)
                        • Revoke access to this screen unless Developer Mode is re-enabled
                        """,
                        trailingAccessory: .toggle(
                            current.developerMode,
                            oldValue: previous?.developerMode
                        ),
                        onTap: { [weak self] in
                            guard current.developerMode else { return }
                            
                            self?.disableDeveloperMode()
                        }
                    )
                ]
            ),
            SectionModel(
                model: .network,
                elements: [
                    SessionCell.Info(
                        id: .serviceNetwork,
                        title: "Environment",
                        subtitle: """
                        The environment used for sending requests and storing messages.
                        
                        <b>Warning:</b>
                        Changing this setting will result in all conversation and snode data being cleared and any pending network requests being cancelled.
                        """,
                        trailingAccessory: .dropDown { current.serviceNetwork.title },
                        onTap: { [weak self, dependencies] in
                            self?.transitionToScreen(
                                SessionTableViewController(
                                    viewModel: SessionListViewModel<ServiceNetwork>(
                                        title: "Environment",
                                        options: ServiceNetwork.allCases,
                                        behaviour: .autoDismiss(
                                            initialSelection: current.serviceNetwork,
                                            onOptionSelected: self?.updateServiceNetwork
                                        ),
                                        using: dependencies
                                    )
                                )
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .networkLayer,
                        title: "Routing",
                        subtitle: """
                        The network layer which all network traffic should be routed through.
                        
                        We do support sending network traffic through multiple network layers, if multiple layers are selected then requests will wait for a response from all layers before completing with the first successful response.
                        
                        <b>Warning:</b>
                        Different network layers offer different levels of privacy, make sure to read the description of the network layers before making a selection.
                        """,
                        trailingAccessory: .dropDown { current.networkLayer.title },
                        onTap: { [weak self, dependencies] in
                            self?.transitionToScreen(
                                SessionTableViewController(
                                    viewModel: SessionListViewModel<Network.Layers>(
                                        title: "Routing",
                                        options: Network.Layers.allCases,
                                        behaviour: .singleSelect(
                                            initialSelection: current.networkLayer,
                                            onSaved: self?.updateNetworkLayers
                                        ),
                                        using: dependencies
                                    )
                                )
                            )
                        }
                    )
                ]
            ),
            SectionModel(
                model: .disappearingMessages,
                elements: [
                    SessionCell.Info(
                        id: .debugDisappearingMessageDurations,
                        title: "Debug Durations",
                        subtitle: """
                        Adds 10 and 60 second durations for Disappearing Message settings.
                        
                        These should only be used for debugging purposes and can result in odd behaviours.
                        """,
                        trailingAccessory: .toggle(
                            current.debugDisappearingMessageDurations,
                            oldValue: previous?.debugDisappearingMessageDurations
                        ),
                        onTap: { [weak self] in
                            self?.updateFlag(
                                for: .debugDisappearingMessageDurations,
                                to: !current.debugDisappearingMessageDurations
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .updatedDisappearingMessages,
                        title: "Use Updated Disappearing Messages",
                        subtitle: """
                        Controls whether legacy or updated disappearing messages should be used.
                        """,
                        trailingAccessory: .toggle(
                            current.updatedDisappearingMessages,
                            oldValue: previous?.updatedDisappearingMessages
                        ),
                        onTap: { [weak self] in
                            self?.updateFlag(
                                for: .updatedDisappearingMessages,
                                to: !current.updatedDisappearingMessages
                            )
                        }
                    )
                ]
            ),
            SectionModel(
                model: .groups,
                elements: [
                    SessionCell.Info(
                        id: .updatedGroups,
                        title: "Create Updated Groups",
                        subtitle: """
                        Controls whether newly created groups are updated or legacy groups.
                        """,
                        trailingAccessory: .toggle(
                            current.updatedGroups,
                            oldValue: previous?.updatedGroups
                        ),
                        onTap: { [weak self] in
                            self?.updateFlag(
                                for: .updatedGroups,
                                to: !current.updatedGroups
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .updatedGroupsDisableAutoApprove,
                        title: "Disable Auto Approve",
                        subtitle: """
                        Prevents a group from automatically getting approved if the admin is already approved.
                        
                        <b>Note:</b> The default behaviour is to automatically approve new groups if the admin that sent the invitation is an approved contact.
                        """,
                        trailingAccessory: .toggle(
                            current.updatedGroupsDisableAutoApprove,
                            oldValue: previous?.updatedGroupsDisableAutoApprove
                        ),
                        onTap: { [weak self] in
                            self?.updateFlag(
                                for: .updatedGroupsDisableAutoApprove,
                                to: !current.updatedGroupsDisableAutoApprove
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .updatedGroupsRemoveMessagesOnKick,
                        title: "Remove Messages on Kick",
                        subtitle: """
                        Controls whether a group members messages should be removed when they are kicked from an updated group.
                        
                        <b>Note:</b> In a future release we will offer this as an option when removing members but for the initial release it can be controlled via this flag for testing purposes.
                        """,
                        trailingAccessory: .toggle(
                            current.updatedGroupsRemoveMessagesOnKick,
                            oldValue: previous?.updatedGroupsRemoveMessagesOnKick
                        ),
                        onTap: { [weak self] in
                            self?.updateFlag(
                                for: .updatedGroupsRemoveMessagesOnKick,
                                to: !current.updatedGroupsRemoveMessagesOnKick
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .updatedGroupsAllowHistoricAccessOnInvite,
                        title: "Allow Historic Message Access",
                        subtitle: """
                        Controls whether members should be granted access to historic messages when invited to an updated group.
                        
                        <b>Note:</b> In a future release we will offer this as an option when inviting members but for the initial release it can be controlled via this flag for testing purposes.
                        """,
                        trailingAccessory: .toggle(
                            current.updatedGroupsAllowHistoricAccessOnInvite,
                            oldValue: previous?.updatedGroupsAllowHistoricAccessOnInvite
                        ),
                        onTap: { [weak self] in
                            self?.updateFlag(
                                for: .updatedGroupsAllowHistoricAccessOnInvite,
                                to: !current.updatedGroupsAllowHistoricAccessOnInvite
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .updatedGroupsAllowDisplayPicture,
                        title: "Custom Display Pictures",
                        subtitle: """
                        Controls whether the UI allows group admins to set a custom display picture for a group.
                        
                        <b>Note:</b> In a future release we will offer this functionality but for the initial release it may not be fully supported across platforms so can be controlled via this flag for testing purposes.
                        """,
                        trailingAccessory: .toggle(
                            current.updatedGroupsAllowDisplayPicture,
                            oldValue: previous?.updatedGroupsAllowDisplayPicture
                        ),
                        onTap: { [weak self] in
                            self?.updateFlag(
                                for: .updatedGroupsAllowDisplayPicture,
                                to: !current.updatedGroupsAllowDisplayPicture
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .updatedGroupsAllowDescriptionEditing,
                        title: "Edit Group Descriptions",
                        subtitle: """
                        Controls whether the UI allows group admins to modify the descriptions of updated groups.
                        
                        <b>Note:</b> In a future release we will offer this functionality but for the initial release it may not be fully supported across platforms so can be controlled via this flag for testing purposes.
                        """,
                        trailingAccessory: .toggle(
                            current.updatedGroupsAllowDescriptionEditing,
                            oldValue: previous?.updatedGroupsAllowDescriptionEditing
                        ),
                        onTap: { [weak self] in
                            self?.updateFlag(
                                for: .updatedGroupsAllowDescriptionEditing,
                                to: !current.updatedGroupsAllowDescriptionEditing
                            )
                        }
                    ),
                    SessionCell.Info(
                        id: .updatedGroupsAllowPromotions,
                        title: "Allow Group Promotions",
                        subtitle: """
                        Controls whether the UI allows group admins promote other group members to admin within an updated group.
                        
                        <b>Note:</b> In a future release we will offer this functionality but for the initial release it may not be fully supported across platforms so can be controlled via this flag for testing purposes.
                        """,
                        trailingAccessory: .toggle(
                            current.updatedGroupsAllowPromotions,
                            oldValue: previous?.updatedGroupsAllowPromotions
                        ),
                        onTap: { [weak self] in
                            self?.updateFlag(
                                for: .updatedGroupsAllowPromotions,
                                to: !current.updatedGroupsAllowPromotions
                            )
                        }
                    )
                ]
            ),
            SectionModel(
                model: .database,
                elements: [
                    SessionCell.Info(
                        id: .exportDatabase,
                        title: "Export Database",
                        trailingAccessory: .icon(
                            UIImage(systemName: "square.and.arrow.up.trianglebadge.exclamationmark")?
                                .withRenderingMode(.alwaysTemplate),
                            size: .small
                        ),
                        styling: SessionCell.StyleInfo(
                            tintColor: .danger
                        ),
                        onTapView: { [weak self] view in self?.exportDatabase(view) }
                    )
                ]
            )
        ]
    }
    
    // MARK: - Functions
    
    private func disableDeveloperMode() {
        /// Loop through all of the sections and reset the features back to default for each one as needed (this way if a new section is added
        /// then we will get a compile error if it doesn't get resetting instructions added)
        TableItem.allCases.forEach { item in
            switch item {
                case .developerMode: break  // Not a feature
                case .exportDatabase: break  // Not a feature
                
                case .serviceNetwork: updateServiceNetwork(to: nil)
                case .networkLayer: updateNetworkLayers(to: nil)
                    
                case .debugDisappearingMessageDurations:
                    updateFlag(for: .debugDisappearingMessageDurations, to: nil)
                case .updatedDisappearingMessages: updateFlag(for: .updatedDisappearingMessages, to: nil)
                    
                case .updatedGroups: updateFlag(for: .updatedGroups, to: nil)
                case .updatedGroupsDisableAutoApprove: updateFlag(for: .updatedGroupsDisableAutoApprove, to: nil)
                case .updatedGroupsRemoveMessagesOnKick: updateFlag(for: .updatedGroupsRemoveMessagesOnKick, to: nil)
                case .updatedGroupsAllowHistoricAccessOnInvite:
                    updateFlag(for: .updatedGroupsAllowHistoricAccessOnInvite, to: nil)
                case .updatedGroupsAllowDisplayPicture: updateFlag(for: .updatedGroupsAllowDisplayPicture, to: nil)
                case .updatedGroupsAllowDescriptionEditing:
                    updateFlag(for: .updatedGroupsAllowDescriptionEditing, to: nil)
                case .updatedGroupsAllowPromotions: updateFlag(for: .updatedGroupsAllowPromotions, to: nil)
            }
        }
        
        /// Disable developer mode
        dependencies[singleton: .storage].write(using: dependencies) { db in
            db[.developerModeEnabled] = false
        }
        
        self.dismissScreen(type: .pop)
    }
    
    private func updateServiceNetwork(to updatedNetwork: ServiceNetwork?) {
        struct IdentityData {
            let ed25519KeyPair: KeyPair
            let x25519KeyPair: KeyPair
        }
        
        /// Make sure we are actually changing the network before clearing all of the data
        guard
            updatedNetwork != dependencies[feature: .serviceNetwork],
            let identityData: IdentityData = dependencies[singleton: .storage].read(using: dependencies, { db in
                IdentityData(
                    ed25519KeyPair: KeyPair(
                        publicKey: Array(try Identity
                            .filter(Identity.Columns.variant == Identity.Variant.ed25519PublicKey)
                            .fetchOne(db, orThrow: StorageError.objectNotFound)
                            .data),
                        secretKey: Array(try Identity
                            .filter(Identity.Columns.variant == Identity.Variant.ed25519SecretKey)
                            .fetchOne(db, orThrow: StorageError.objectNotFound)
                            .data)
                    ),
                    x25519KeyPair: KeyPair(
                        publicKey: Array(try Identity
                            .filter(Identity.Columns.variant == Identity.Variant.x25519PublicKey)
                            .fetchOne(db, orThrow: StorageError.objectNotFound)
                            .data),
                        secretKey: Array(try Identity
                            .filter(Identity.Columns.variant == Identity.Variant.x25519PrivateKey)
                            .fetchOne(db, orThrow: StorageError.objectNotFound)
                            .data)
                    )
                )
            })
        else { return }
        
        SNLog("[DevSettings] Swapping to \(String(describing: updatedNetwork)), clearing data")
        
        /// Stop all pollers
        dependencies[singleton: .currentUserPoller].stopAllPollers()
        dependencies[singleton: .groupsPoller].stopAllPollers()
        OpenGroupManager.shared.stopPolling()
        
        /// Cancel and remove all current network requests
        dependencies.mutate(cache: .network) { networkCache in
            networkCache.currentRequests.forEach { _, value in value.cancel() }
            networkCache.currentRequests = [:]
        }
        
        /// Unsubscribe from push notifications (do this after cancelling pending network requests as we don't want these to be cancelled)
        if let existingToken: String = dependencies[singleton: .storage, key: .lastRecordedPushToken] {
            PushNotificationAPI
                .unsubscribeAll(token: Data(hex: existingToken), using: dependencies)
                .sinkUntilComplete()
        }
        
        /// Clear the snodeAPI and getSnodePool caches
        dependencies.mutate(cache: .snodeAPI) {
            $0.snodePool = []
            $0.swarmCache = [:]
            $0.loadedSwarms = []
            $0.snodeFailureCount = [:]
            $0.hasLoadedSnodePool = false
        }
        
        dependencies.mutate(cache: .getSnodePool) {
            $0.publisher = nil
        }
        
        /// Clear the onionRequestAPI cache
        dependencies.mutate(cache: .onionRequestAPI) {
            $0.buildPathsPublisher = nil
            $0.pathFailureCount = [:]
            $0.snodeFailureCount = [:]
            $0.guardSnodes = []
            $0.paths = []
        }
        
        /// Remove any network-specific data
        dependencies[singleton: .storage].write(using: dependencies) { [dependencies] db in
            let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
            
            _ = try Snode.deleteAll(db)
            _ = try SnodeSet.deleteAll(db)
            _ = try SnodeReceivedMessageInfo.deleteAll(db)
            _ = try SessionThread.deleteAll(db)
            _ = try ControlMessageProcessRecord.deleteAll(db)
            _ = try ClosedGroup.deleteAll(db)
            _ = try OpenGroup.deleteAll(db)
            _ = try Capability.deleteAll(db)
            _ = try GroupMember.deleteAll(db)
            _ = try Contact
                .filter(Contact.Columns.id != userSessionId.hexString)
                .deleteAll(db)
            _ = try Profile
                .filter(Profile.Columns.id != userSessionId.hexString)
                .deleteAll(db)
            _ = try BlindedIdLookup.deleteAll(db)
            _ = try ConfigDump.deleteAll(db)
        }
        
        SNLog("[DevSettings] Reloading state for \(String(describing: updatedNetwork))")
        
        /// Reload the libSession state
        LibSession.clearMemoryState(using: dependencies)
        
        /// Update to the new `ServiceNetwork`
        dependencies.set(feature: .serviceNetwork, to: updatedNetwork)
        
        /// Run the onboarding process as if we are recovering an account (will setup the device in it's proper state)
        Onboarding.Flow.recover.preregister(
            ed25519KeyPair: identityData.ed25519KeyPair,
            x25519KeyPair: identityData.x25519KeyPair,
            using: dependencies
        )
        Onboarding.Flow.recover.completeRegistration(
            suppressDidRegisterNotification: true,
            onComplete: { [dependencies] _ in
                /// Restart the current user poller (there won't be any other pollers though)
                dependencies[singleton: .currentUserPoller].start(using: dependencies)
                
                /// Re-sync the push tokens (if there are any)
                SyncPushTokensJob.run(uploadOnlyIfStale: false)
                
                SNLog("[DevSettings] Completed swap to \(String(describing: updatedNetwork))")
            },
            using: dependencies
        )
        
        forceRefresh(type: .databaseQuery)
    }
    
    private func updateNetworkLayers(to networkLayers: Network.Layers?) {
        let updatedNetworkLayers: Network.Layers? = networkLayers
        
        /// Cancel and remove all current network requests
        dependencies.mutate(cache: .network) { networkCache in
            networkCache.currentRequests.forEach { _, value in value.cancel() }
            networkCache.currentRequests = [:]
        }
        
        /// Update to the new `Network.Layers`
        dependencies.set(feature: .networkLayers, to: updatedNetworkLayers)
        
        forceRefresh(type: .databaseQuery)
    }
    
    private func updateFlag(for feature: FeatureConfig<Bool>, to updatedFlag: Bool?) {
        /// Update to the new flag
        dependencies.set(feature: feature, to: updatedFlag)
        forceRefresh(type: .databaseQuery)
    }
    
    private func exportDatabase(_ targetView: UIView?) {
        let generatedPassword: String = UUID().uuidString
        self.databaseKeyEncryptionPassword = generatedPassword
        
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Export Database",
                    body: .input(
                        explanation: NSAttributedString(
                            string: """
                            Sharing the database and key together is dangerous!

                            We've generated a secure password for you but feel free to provide your own (we will show the generated password again after exporting)

                            This password will be used to encrypt the database decryption key and will be exported alongside the database
                            """
                        ),
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "Enter a password",
                            initialValue: generatedPassword,
                            clearButton: true
                        ),
                        onChange: { [weak self] value in self?.databaseKeyEncryptionPassword = value }
                    ),
                    confirmTitle: "Export",
                    dismissOnConfirm: false,
                    onConfirm: { [weak self, dependencies] modal in
                        modal.dismiss(animated: true) {
                            guard let password: String = self?.databaseKeyEncryptionPassword, password.count >= 6 else {
                                self?.transitionToScreen(
                                    ConfirmationModal(
                                        info: ConfirmationModal.Info(
                                            title: "Error",
                                            body: .text("Password must be at least 6 characters")
                                        )
                                    ),
                                    transitionType: .present
                                )
                                return
                            }
                            
                            do {
                                let exportInfo = try dependencies[singleton: .storage].exportInfo(password: password)
                                let shareVC = UIActivityViewController(
                                    activityItems: [
                                        URL(fileURLWithPath: exportInfo.dbPath),
                                        URL(fileURLWithPath: exportInfo.keyPath)
                                    ],
                                    applicationActivities: nil
                                )
                                shareVC.completionWithItemsHandler = { [weak self] _, completed, _, _ in
                                    guard
                                        completed &&
                                        generatedPassword == self?.databaseKeyEncryptionPassword
                                    else { return }
                                    
                                    self?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "Password",
                                                body: .text("""
                                                The generated password was:
                                                \(generatedPassword)
                                                
                                                Avoid sending this via the same means as the database
                                                """),
                                                confirmTitle: "Share",
                                                dismissOnConfirm: false,
                                                onConfirm: { [weak self] modal in
                                                    modal.dismiss(animated: true) {
                                                        let passwordShareVC = UIActivityViewController(
                                                            activityItems: [generatedPassword],
                                                            applicationActivities: nil
                                                        )
                                                        if UIDevice.current.isIPad {
                                                            passwordShareVC.excludedActivityTypes = []
                                                            passwordShareVC.popoverPresentationController?.permittedArrowDirections = (targetView != nil ? [.up] : [])
                                                            passwordShareVC.popoverPresentationController?.sourceView = targetView
                                                            passwordShareVC.popoverPresentationController?.sourceRect = (targetView?.bounds ?? .zero)
                                                        }
                                                        
                                                        self?.transitionToScreen(passwordShareVC, transitionType: .present)
                                                    }
                                                }
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                }
                                
                                if UIDevice.current.isIPad {
                                    shareVC.excludedActivityTypes = []
                                    shareVC.popoverPresentationController?.permittedArrowDirections = (targetView != nil ? [.up] : [])
                                    shareVC.popoverPresentationController?.sourceView = targetView
                                    shareVC.popoverPresentationController?.sourceRect = (targetView?.bounds ?? .zero)
                                }
                                
                                self?.transitionToScreen(shareVC, transitionType: .present)
                            }
                            catch {
                                let message: String = {
                                    switch error {
                                        case CryptoKitError.incorrectKeySize:
                                            return "The password must be between 6 and 32 characters (padded to 32 bytes)"
                                        
                                        default: return "Failed to export database"
                                    }
                                }()
                                
                                self?.transitionToScreen(
                                    ConfirmationModal(
                                        info: ConfirmationModal.Info(
                                            title: "Error",
                                            body: .text(message)
                                        )
                                    ),
                                    transitionType: .present
                                )
                            }
                        }
                    }
                )
            ),
            transitionType: .present
        )
    }
}

// MARK: - Listable Conformance

extension ServiceNetwork: Listable {}
extension Network.Layers: Listable {}
