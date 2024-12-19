// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import CryptoKit
import Compression
import GRDB
import DifferenceKit
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

class DeveloperSettingsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private var showAdvancedLogging: Bool = false
    private var databaseKeyEncryptionPassword: String = ""
    private var documentPickerResult: DocumentPickerResult?
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Section
    
    public enum Section: SessionTableSection {
        case developerMode
        case general
        case logging
        case network
        case disappearingMessages
        case groups
        case database
        
        var title: String? {
            switch self {
                case .developerMode: return nil
                case .general: return "General"
                case .logging: return "Logging"
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
    
    public enum TableItem: Hashable, Differentiable, CaseIterable {
        case developerMode
        
        case animationsEnabled
        case showStringKeys
        
        case defaultLogLevel
        case advancedLogging
        case loggingCategory(String)
        
        case serviceNetwork
        case forceOffline
        case resetSnodeCache
        
        case updatedDisappearingMessages
        case debugDisappearingMessageDurations
        
        case updatedGroups
        case updatedGroupsDisableAutoApprove
        case updatedGroupsRemoveMessagesOnKick
        case updatedGroupsAllowHistoricAccessOnInvite
        case updatedGroupsAllowDisplayPicture
        case updatedGroupsAllowDescriptionEditing
        case updatedGroupsAllowPromotions
        case updatedGroupsAllowInviteById
        case updatedGroupsDeleteBeforeNow
        case updatedGroupsDeleteAttachmentsBeforeNow
        
        case exportDatabase
        case importDatabase
        
        // MARK: - Conformance
        
        public typealias DifferenceIdentifier = String
        
        public var differenceIdentifier: String {
            switch self {
                case .developerMode: return "developerMode"
                case .animationsEnabled: return "animationsEnabled"
                case .showStringKeys: return "showStringKeys"
                
                case .defaultLogLevel: return "defaultLogLevel"
                case .advancedLogging: return "advancedLogging"
                case .loggingCategory(let categoryIdentifier): return "loggingCategory-\(categoryIdentifier)"
                
                case .serviceNetwork: return "serviceNetwork"
                case .forceOffline: return "forceOffline"
                case .resetSnodeCache: return "resetSnodeCache"
                
                case .updatedDisappearingMessages: return "updatedDisappearingMessages"
                case .debugDisappearingMessageDurations: return "debugDisappearingMessageDurations"
                
                case .updatedGroups: return "updatedGroups"
                case .updatedGroupsDisableAutoApprove: return "updatedGroupsDisableAutoApprove"
                case .updatedGroupsRemoveMessagesOnKick: return "updatedGroupsRemoveMessagesOnKick"
                case .updatedGroupsAllowHistoricAccessOnInvite: return "updatedGroupsAllowHistoricAccessOnInvite"
                case .updatedGroupsAllowDisplayPicture: return "updatedGroupsAllowDisplayPicture"
                case .updatedGroupsAllowDescriptionEditing: return "updatedGroupsAllowDescriptionEditing"
                case .updatedGroupsAllowPromotions: return "updatedGroupsAllowPromotions"
                case .updatedGroupsAllowInviteById: return "updatedGroupsAllowInviteById"
                case .updatedGroupsDeleteBeforeNow: return "updatedGroupsDeleteBeforeNow"
                case .updatedGroupsDeleteAttachmentsBeforeNow: return "updatedGroupsDeleteAttachmentsBeforeNow"
                
                case .exportDatabase: return "exportDatabase"
                case .importDatabase: return "importDatabase"
            }
        }
        
        public func isContentEqual(to source: TableItem) -> Bool {
            self.differenceIdentifier == source.differenceIdentifier
        }
        
        public static var allCases: [TableItem] {
            var result: [TableItem] = []
            switch TableItem.developerMode {
                case .developerMode: result.append(.developerMode); fallthrough
                case .animationsEnabled: result.append(.animationsEnabled); fallthrough
                case .showStringKeys: result.append(.showStringKeys); fallthrough
                
                case .defaultLogLevel: result.append(.defaultLogLevel); fallthrough
                case .advancedLogging: result.append(.advancedLogging); fallthrough
                case .loggingCategory: result.append(.loggingCategory("")); fallthrough
                
                case .serviceNetwork: result.append(.serviceNetwork); fallthrough
                case .forceOffline: result.append(.forceOffline); fallthrough
                case .resetSnodeCache: result.append(.resetSnodeCache); fallthrough
                
                case .updatedDisappearingMessages: result.append(.updatedDisappearingMessages); fallthrough
                case .debugDisappearingMessageDurations: result.append(.debugDisappearingMessageDurations); fallthrough
                
                case .updatedGroups: result.append(.updatedGroups); fallthrough
                case .updatedGroupsDisableAutoApprove: result.append(.updatedGroupsDisableAutoApprove); fallthrough
                case .updatedGroupsRemoveMessagesOnKick: result.append(.updatedGroupsRemoveMessagesOnKick); fallthrough
                case .updatedGroupsAllowHistoricAccessOnInvite:
                    result.append(.updatedGroupsAllowHistoricAccessOnInvite); fallthrough
                case .updatedGroupsAllowDisplayPicture: result.append(.updatedGroupsAllowDisplayPicture); fallthrough
                case .updatedGroupsAllowDescriptionEditing: result.append(.updatedGroupsAllowDescriptionEditing); fallthrough
                case .updatedGroupsAllowPromotions: result.append(.updatedGroupsAllowPromotions); fallthrough
                case .updatedGroupsAllowInviteById: result.append(.updatedGroupsAllowInviteById); fallthrough
                case .updatedGroupsDeleteBeforeNow: result.append(.updatedGroupsDeleteBeforeNow); fallthrough
                case .updatedGroupsDeleteAttachmentsBeforeNow: result.append(.updatedGroupsDeleteAttachmentsBeforeNow); fallthrough
                
                case .exportDatabase: result.append(.exportDatabase); fallthrough
                case .importDatabase: result.append(.importDatabase)
            }
            
            return result
        }
    }
    
    // MARK: - Content
    
    private struct State: Equatable {
        let developerMode: Bool
        
        let animationsEnabled: Bool
        let showStringKeys: Bool
        
        let defaultLogLevel: Log.Level
        let advancedLogging: Bool
        let loggingCategories: [Log.Category: Log.Level]
        
        let serviceNetwork: ServiceNetwork
        let forceOffline: Bool
        
        let debugDisappearingMessageDurations: Bool
        let updatedDisappearingMessages: Bool
        
        let updatedGroups: Bool
        let updatedGroupsDisableAutoApprove: Bool
        let updatedGroupsRemoveMessagesOnKick: Bool
        let updatedGroupsAllowHistoricAccessOnInvite: Bool
        let updatedGroupsAllowDisplayPicture: Bool
        let updatedGroupsAllowDescriptionEditing: Bool
        let updatedGroupsAllowPromotions: Bool
        let updatedGroupsAllowInviteById: Bool
        let updatedGroupsDeleteBeforeNow: Bool
        let updatedGroupsDeleteAttachmentsBeforeNow: Bool
    }
    
    let title: String = "Developer Settings"
    
    lazy var observation: TargetObservation = ObservationBuilder
        .refreshableData(self) { [weak self, dependencies] () -> State in
            State(
                developerMode: dependencies[singleton: .storage, key: .developerModeEnabled],
                animationsEnabled: dependencies[feature: .animationsEnabled],
                showStringKeys: dependencies[feature: .showStringKeys],
                
                defaultLogLevel: dependencies[feature: .logLevel(cat: .default)],
                advancedLogging: (self?.showAdvancedLogging == true),
                loggingCategories: dependencies[feature: .allLogLevels].currentValues(using: dependencies),
                
                serviceNetwork: dependencies[feature: .serviceNetwork],
                forceOffline: dependencies[feature: .forceOffline],
                
                debugDisappearingMessageDurations: dependencies[feature: .debugDisappearingMessageDurations],
                updatedDisappearingMessages: dependencies[feature: .updatedDisappearingMessages],
                
                updatedGroups: dependencies[feature: .updatedGroups],
                updatedGroupsDisableAutoApprove: dependencies[feature: .updatedGroupsDisableAutoApprove],
                updatedGroupsRemoveMessagesOnKick: dependencies[feature: .updatedGroupsRemoveMessagesOnKick],
                updatedGroupsAllowHistoricAccessOnInvite: dependencies[feature: .updatedGroupsAllowHistoricAccessOnInvite],
                updatedGroupsAllowDisplayPicture: dependencies[feature: .updatedGroupsAllowDisplayPicture],
                updatedGroupsAllowDescriptionEditing: dependencies[feature: .updatedGroupsAllowDescriptionEditing],
                updatedGroupsAllowPromotions: dependencies[feature: .updatedGroupsAllowPromotions],
                updatedGroupsAllowInviteById: dependencies[feature: .updatedGroupsAllowInviteById],
                updatedGroupsDeleteBeforeNow: dependencies[feature: .updatedGroupsDeleteBeforeNow],
                updatedGroupsDeleteAttachmentsBeforeNow: dependencies[feature: .updatedGroupsDeleteAttachmentsBeforeNow]
            )
        }
        .compactMapWithPrevious { [weak self] prev, current -> [SectionModel]? in self?.content(prev, current) }
    
    private func content(_ previous: State?, _ current: State) -> [SectionModel] {
        let developerMode: SectionModel = SectionModel(
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
        )
        let general: SectionModel = SectionModel(
            model: .general,
            elements: [
                SessionCell.Info(
                    id: .animationsEnabled,
                    title: "Animations Enabled",
                    subtitle: """
                    Controls whether animations are enabled throughout the app
                    
                    Note: There may be some custom or low-level animations which can't be disabled via this setting
                    """,
                    trailingAccessory: .toggle(
                        current.animationsEnabled,
                        oldValue: previous?.animationsEnabled
                    ),
                    onTap: { [weak self] in
                        self?.updateFlag(
                            for: .animationsEnabled,
                            to: !current.animationsEnabled
                        )
                    }
                ),
                SessionCell.Info(
                    id: .showStringKeys,
                    title: "Show String Keys",
                    subtitle: """
                    Controls whether localised strings should render using their keys rather than the localised value (strings will be rendered as "[{key}]")
                    
                    Notes:
                    • This change will only apply to newly created screens (eg. the Settings screen will need to be closed and reopened before it gets updated
                    • The "Home" screen won't update as it never gets recreated
                    """,
                    trailingAccessory: .toggle(
                        current.showStringKeys,
                        oldValue: previous?.showStringKeys
                    ),
                    onTap: { [weak self] in
                        self?.updateFlag(
                            for: .showStringKeys,
                            to: !current.showStringKeys
                        )
                    }
                )
            ]
        )
        let logging: SectionModel = SectionModel(
            model: .logging,
            elements: [
                SessionCell.Info(
                    id: .defaultLogLevel,
                    title: "Default Log Level",
                    subtitle: """
                    Sets the default log level
                    
                    All logging categories which don't have a custom level set below will use this value
                    """,
                    trailingAccessory: .dropDown { current.defaultLogLevel.title },
                    onTap: { [weak self, dependencies] in
                        self?.transitionToScreen(
                            SessionTableViewController(
                                viewModel: SessionListViewModel<Log.Level>(
                                    title: "Default Log Level",
                                    options: Log.Level.allCases.filter { $0 != .default },
                                    behaviour: .autoDismiss(
                                        initialSelection: current.defaultLogLevel,
                                        onOptionSelected: self?.updateDefaulLogLevel
                                    ),
                                    using: dependencies
                                )
                            )
                        )
                    }
                ),
                SessionCell.Info(
                    id: .advancedLogging,
                    title: "Advanced Logging",
                    subtitle: "Show per-category log levels",
                    trailingAccessory: .toggle(
                        current.advancedLogging,
                        oldValue: previous?.advancedLogging
                    ),
                    onTap: { [weak self] in
                        self?.setAdvancedLoggingVisibility(to: !current.advancedLogging)
                    }
                )
            ].appending(
                contentsOf: !current.advancedLogging ? nil : current.loggingCategories
                    .sorted(by: { lhs, rhs in lhs.key.rawValue < rhs.key.rawValue })
                    .map { category, level in
                        SessionCell.Info(
                            id: .loggingCategory(category.rawValue),
                            title: category.rawValue,
                            subtitle: "Sets the log level for the \(category.rawValue) category",
                            trailingAccessory: .dropDown { level.title },
                            onTap: { [weak self, dependencies] in
                                self?.transitionToScreen(
                                    SessionTableViewController(
                                        viewModel: SessionListViewModel<Log.Level>(
                                            title: "\(category.rawValue) Log Level",
                                            options: [Log.Level.default]    // Move 'default' to the top
                                                .appending(contentsOf: Log.Level.allCases.filter { $0 != .default }),
                                            behaviour: .autoDismiss(
                                                initialSelection: level,
                                                onOptionSelected: { updatedLevel in
                                                    self?.updateLogLevel(of: category, to: updatedLevel)
                                                }
                                            ),
                                            using: dependencies
                                        )
                                    )
                                )
                            }
                        )
                    }
            )
        )
        let network: SectionModel = SectionModel(
            model: .network,
            elements: [
                SessionCell.Info(
                    id: .serviceNetwork,
                    title: "Environment",
                    subtitle: """
                    The environment used for sending requests and storing messages.
                    
                    <b>Warning:</b>
                    Changing between some of these options can result in all conversation and snode data being cleared and any pending network requests being cancelled.
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
                    id: .forceOffline,
                    title: "Force Offline",
                    subtitle: """
                    Shut down the current network and cause all future network requests to fail after a 1 second delay with a 'serviceUnavailable' error.
                    """,
                    trailingAccessory: .toggle(
                        current.forceOffline,
                        oldValue: previous?.forceOffline
                    ),
                    onTap: { [weak self] in self?.updateForceOffline(current: current.forceOffline) }
                ),
                SessionCell.Info(
                    id: .resetSnodeCache,
                    title: "Reset Service Node Cache",
                    subtitle: """
                    Reset and rebuild the service node cache and rebuild the paths.
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Reset Cache"),
                    onTap: { [weak self] in self?.resetServiceNodeCache() }
                )
            ]
        )
        let disappearingMessages: SectionModel = SectionModel(
            model: .disappearingMessages,
            elements: [
                SessionCell.Info(
                    id: .debugDisappearingMessageDurations,
                    title: "Debug Durations",
                    subtitle: """
                    Adds 10, 30 and 60 second durations for Disappearing Message settings.
                    
                    These should only be used for debugging purposes and will likely result in odd behaviours.
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
        )
        let groups: SectionModel = SectionModel(
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
                    Controls whether the UI allows group admins to promote other group members to admin within an updated group.
                    
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
                ),
                SessionCell.Info(
                    id: .updatedGroupsAllowInviteById,
                    title: "Allow Invite by ID",
                    subtitle: """
                    Controls whether the UI allows group admins to invite other group members directly by their Account ID.
                    
                    <b>Note:</b> In a future release we will offer this functionality but it's not included in the initial release.
                    """,
                    trailingAccessory: .toggle(
                        current.updatedGroupsAllowInviteById,
                        oldValue: previous?.updatedGroupsAllowInviteById
                    ),
                    onTap: { [weak self] in
                        self?.updateFlag(
                            for: .updatedGroupsAllowInviteById,
                            to: !current.updatedGroupsAllowInviteById
                        )
                    }
                ),
                SessionCell.Info(
                    id: .updatedGroupsDeleteBeforeNow,
                    title: "Show button to delete messages before now",
                    subtitle: """
                    Controls whether the UI allows group admins to delete all messages in the group that were sent before the button was pressed.
                    
                    <b>Note:</b> In a future release we will offer this functionality but it's not included in the initial release.
                    """,
                    trailingAccessory: .toggle(
                        current.updatedGroupsDeleteBeforeNow,
                        oldValue: previous?.updatedGroupsDeleteBeforeNow
                    ),
                    onTap: { [weak self] in
                        self?.updateFlag(
                            for: .updatedGroupsDeleteBeforeNow,
                            to: !current.updatedGroupsDeleteBeforeNow
                        )
                    }
                ),
                SessionCell.Info(
                    id: .updatedGroupsDeleteAttachmentsBeforeNow,
                    title: "Show button to delete attachments before now",
                    subtitle: """
                    Controls whether the UI allows group admins to delete all attachments (and their associated messages) in the group that were sent before the button was pressed.
                    
                    <b>Note:</b> In a future release we will offer this functionality but it's not included in the initial release.
                    """,
                    trailingAccessory: .toggle(
                        current.updatedGroupsDeleteAttachmentsBeforeNow,
                        oldValue: previous?.updatedGroupsDeleteAttachmentsBeforeNow
                    ),
                    onTap: { [weak self] in
                        self?.updateFlag(
                            for: .updatedGroupsDeleteAttachmentsBeforeNow,
                            to: !current.updatedGroupsDeleteAttachmentsBeforeNow
                        )
                    }
                )
            ]
        )
        let database: SectionModel = SectionModel(
            model: .database,
            elements: [
                SessionCell.Info(
                    id: .exportDatabase,
                    title: "Export App Data",
                    trailingAccessory: .icon(
                        UIImage(systemName: "square.and.arrow.up.trianglebadge.exclamationmark")?
                            .withRenderingMode(.alwaysTemplate),
                        size: .small
                    ),
                    styling: SessionCell.StyleInfo(
                        tintColor: .danger
                    ),
                    onTapView: { [weak self] view in self?.exportDatabase(view) }
                ),
                SessionCell.Info(
                    id: .importDatabase,
                    title: "Import App Data",
                    trailingAccessory: .icon(
                        UIImage(systemName: "square.and.arrow.down")?
                            .withRenderingMode(.alwaysTemplate),
                        size: .small
                    ),
                    styling: SessionCell.StyleInfo(
                        tintColor: .danger
                    ),
                    onTapView: { [weak self] view in self?.importDatabase(view) }
                )
            ]
        )
        
        return [
            developerMode,
            general,
            logging,
            network,
            disappearingMessages,
            groups,
            database
        ]
    }
    
    // MARK: - Functions
    
    private func disableDeveloperMode() {
        /// Loop through all of the sections and reset the features back to default for each one as needed (this way if a new section is added
        /// then we will get a compile error if it doesn't get resetting instructions added)
        TableItem.allCases.forEach { item in
            switch item {
                case .developerMode: break      // Not a feature
                case .animationsEnabled: updateFlag(for: .animationsEnabled, to: nil)
                case .showStringKeys: updateFlag(for: .showStringKeys, to: nil)
                
                case .resetSnodeCache: break    // Not a feature
                case .exportDatabase: break     // Not a feature
                case .importDatabase: break     // Not a feature
                case .advancedLogging: break    // Not a feature
                    
                case .defaultLogLevel: updateDefaulLogLevel(to: nil)
                case .loggingCategory: resetLoggingCategories()
                
                case .serviceNetwork: updateServiceNetwork(to: nil)
                case .forceOffline:  updateFlag(for: .forceOffline, to: nil)
                    
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
                case .updatedGroupsAllowInviteById: updateFlag(for: .updatedGroupsAllowInviteById, to: nil)
                case .updatedGroupsDeleteBeforeNow: updateFlag(for: .updatedGroupsDeleteBeforeNow, to: nil)
                case .updatedGroupsDeleteAttachmentsBeforeNow: updateFlag(for: .updatedGroupsDeleteAttachmentsBeforeNow, to: nil)
            }
        }
        
        /// Disable developer mode
        dependencies[singleton: .storage].write { db in
            db[.developerModeEnabled] = false
        }
        
        self.dismissScreen(type: .pop)
    }
    
    private func updateDefaulLogLevel(to updatedDefaultLogLevel: Log.Level?) {
        dependencies.set(feature: .logLevel(cat: .default), to: updatedDefaultLogLevel)
        forceRefresh(type: .databaseQuery)
    }
    
    private func setAdvancedLoggingVisibility(to value: Bool) {
        self.showAdvancedLogging = value
        forceRefresh(type: .databaseQuery)
    }
    
    private func updateLogLevel(of category: Log.Category, to level: Log.Level) {
        switch (level, category.defaultLevel) {
            case (.default, category.defaultLevel): dependencies.reset(feature: .logLevel(cat: category))
            default: dependencies.set(feature: .logLevel(cat: category), to: level)
        }
        forceRefresh(type: .databaseQuery)
    }
    
    private func resetLoggingCategories() {
        dependencies[feature: .allLogLevels].currentValues(using: dependencies).forEach { category, _ in
            dependencies.reset(feature: .logLevel(cat: category))
        }
        forceRefresh(type: .databaseQuery)
    }
    
    private func updateServiceNetwork(to updatedNetwork: ServiceNetwork?) {
        DeveloperSettingsViewModel.updateServiceNetwork(to: updatedNetwork, using: dependencies)
        forceRefresh(type: .databaseQuery)
    }
    
    private static func updateServiceNetwork(
        to updatedNetwork: ServiceNetwork?,
        using dependencies: Dependencies
    ) {
        struct IdentityData {
            let ed25519KeyPair: KeyPair
            let x25519KeyPair: KeyPair
        }
        
        /// Make sure we are actually changing the network before clearing all of the data
        guard
            updatedNetwork != dependencies[feature: .serviceNetwork],
            let identityData: IdentityData = dependencies[singleton: .storage].read({ db in
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
        
        Log.info("[DevSettings] Swapping to \(String(describing: updatedNetwork)), clearing data")
        
        /// Stop all pollers
        dependencies[singleton: .currentUserPoller].stop()
        dependencies.remove(cache: .groupPollers)
        dependencies.remove(cache: .communityPollers)
        
        /// Reset the network
        dependencies.mutate(cache: .libSessionNetwork) {
            $0.setPaths(paths: [])
            $0.setNetworkStatus(status: .unknown)
        }
        dependencies.remove(cache: .libSessionNetwork)
        
        /// Unsubscribe from push notifications (do this after resetting the network as they are server requests so aren't dependant on a service
        /// layer and we don't want these to be cancelled)
        if let existingToken: String = dependencies[singleton: .storage, key: .lastRecordedPushToken] {
            PushNotificationAPI
                .unsubscribeAll(token: Data(hex: existingToken), using: dependencies)
                .sinkUntilComplete()
        }
        
        /// Clear the snodeAPI  caches
        dependencies.remove(cache: .snodeAPI)
        
        /// Remove the libSession state
        dependencies.remove(cache: .libSession)
        
        /// Remove any network-specific data
        dependencies[singleton: .storage].write { [dependencies] db in
            let userSessionId: SessionId = dependencies[cache: .general].sessionId
            
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
        
        Log.info("[DevSettings] Reloading state for \(String(describing: updatedNetwork))")
        
        /// Update to the new `ServiceNetwork`
        dependencies.set(feature: .serviceNetwork, to: updatedNetwork)
        
        /// Start the new network cache
        dependencies.warmCache(cache: .libSessionNetwork)
        
        /// Run the onboarding process as if we are recovering an account (will setup the device in it's proper state)
        Onboarding.Cache(
            ed25519KeyPair: identityData.ed25519KeyPair,
            x25519KeyPair: identityData.x25519KeyPair,
            displayName: Profile.fetchOrCreateCurrentUser(using: dependencies)
                .name
                .nullIfEmpty
                .defaulting(to: "Anonymous"),
            using: dependencies
        ).completeRegistration { [dependencies] in
            /// Restart the current user poller (there won't be any other pollers though)
            dependencies[singleton: .currentUserPoller].startIfNeeded()
            
            /// Re-sync the push tokens (if there are any)
            SyncPushTokensJob.run(uploadOnlyIfStale: false, using: dependencies)
            
            Log.info("[DevSettings] Completed swap to \(String(describing: updatedNetwork))")
        }
    }
    
    private func updateFlag(for feature: FeatureConfig<Bool>, to updatedFlag: Bool?) {
        /// Update to the new flag
        dependencies.set(feature: feature, to: updatedFlag)
        forceRefresh(type: .databaseQuery)
    }
    
    private func updateForceOffline(current: Bool) {
        updateFlag(for: .forceOffline, to: !current)
        
        // Reset the network cache
        dependencies.mutate(cache: .libSessionNetwork) {
            $0.setPaths(paths: [])
            $0.setNetworkStatus(status: current ? .unknown : .disconnected)
        }
        dependencies.remove(cache: .libSessionNetwork)
    }
    
    private func resetServiceNodeCache() {
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Reset Service Node Cache",
                    body: .text("The device will need to fetch a new cache and rebuild it's paths"),
                    confirmTitle: "Reset Cache",
                    confirmStyle: .danger,
                    cancelStyle: .alert_text,
                    dismissOnConfirm: true,
                    onConfirm: { [dependencies] _ in
                        /// Clear the snodeAPI cache
                        dependencies.remove(cache: .snodeAPI)
                        
                        /// Clear the snode cache
                        dependencies.mutate(cache: .libSessionNetwork) { $0.clearSnodeCache() }
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    // MARK: - Export and Import
    
    private func exportDatabase(_ targetView: UIView?) {
        let generatedPassword: String = UUID().uuidString
        self.databaseKeyEncryptionPassword = generatedPassword
        
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Export App Data",
                    body: .input(
                        explanation: NSAttributedString(
                            string: """
                            This will generate a file encrypted using the provided password includes all app data, attachments, settings and keys.
                            
                            This exported file can only be imported by Session iOS. 
                            
                            Use at your own risk!

                            We've generated a secure password for you but feel free to provide your own.
                            """
                        ),
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "Enter a password",
                            initialValue: generatedPassword,
                            clearButton: true
                        ),
                        onChange: { [weak self] value in self?.databaseKeyEncryptionPassword = value }
                    ),
                    confirmTitle: "save".localized(),
                    confirmStyle: .alert_text,
                    cancelTitle: "share".localized(),
                    cancelStyle: .alert_text,
                    hasCloseButton: true,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self] modal in
                        modal.dismiss(animated: true) {
                            self?.performExport(viaShareSheet: false, targetView: targetView)
                        }
                    },
                    onCancel: { [weak self] modal in
                        modal.dismiss(animated: true) {
                            self?.performExport(viaShareSheet: true, targetView: targetView)
                        }
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func importDatabase(_ targetView: UIView?) {
        self.databaseKeyEncryptionPassword = ""
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Import App Data",
                    body: .input(
                        explanation: NSAttributedString(
                            string: """
                            Importing a database will result in the loss of all data stored locally.
                            
                            This can only import backup files exported by Session iOS.

                            Use at your own risk!
                            """
                        ),
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "Enter a password",
                            initialValue: "",
                            clearButton: true
                        ),
                        onChange: { [weak self] value in self?.databaseKeyEncryptionPassword = value }
                    ),
                    confirmTitle: "Import",
                    confirmStyle: .danger,
                    cancelStyle: .alert_text,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self] modal in
                        modal.dismiss(animated: true) {
                            self?.performImport()
                        }
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func performExport(
        viaShareSheet: Bool,
        targetView: UIView?
    ) {
        func showError(_ error: Error) {
            self.transitionToScreen(
                ConfirmationModal(
                    info: ConfirmationModal.Info(
                        title: "theError".localized(),
                        body: {
                            switch error {
                                case CryptoKitError.incorrectKeySize:
                                    return .text("The password must be between 6 and 32 characters (padded to 32 bytes)")
                                case is DatabaseError:
                                    return .text("An error occurred finalising pending changes in the database")
                                
                                default: return .text("Failed to export database")
                            }
                        }()
                    )
                ),
                transitionType: .present
            )
        }
        guard databaseKeyEncryptionPassword.count >= 6 else { return showError(CryptoKitError.incorrectKeySize) }
        
        let viewController: UIViewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self, databaseKeyEncryptionPassword, dependencies] modalActivityIndicator in
            let backupFile: String = "\(dependencies[singleton: .fileManager].temporaryDirectory)/session.bak"
            
            do {
                /// Perform a full checkpoint to ensure any pending changes are written to the main database file
                try dependencies[singleton: .storage].checkpoint(.truncate)
                
                let secureDbKey: String = try dependencies[singleton: .storage].secureExportKey(
                    password: databaseKeyEncryptionPassword
                )
                
                try DirectoryArchiver.archiveDirectory(
                    sourcePath: dependencies[singleton: .fileManager].appSharedDataDirectoryPath,
                    destinationPath: backupFile,
                    filenamesToExclude: [
                        ".DS_Store",
                        "\(Storage.dbFileName)-wal",
                        "\(Storage.dbFileName)-shm"
                    ],
                    additionalPaths: [secureDbKey],
                    password: databaseKeyEncryptionPassword,
                    progressChanged: { fileIndex, totalFiles, currentFileProgress, currentFileSize in
                        let percentage: Int = {
                            guard currentFileSize > 0 else { return 100 }
                            
                            let percentage: Int = Int((Double(currentFileProgress) / Double(currentFileSize)) * 100)
                            
                            guard percentage > 0 else { return 100 }
                            
                            return percentage
                        }()
                        
                        DispatchQueue.main.async {
                            modalActivityIndicator.setMessage([
                                "Exporting file: \(fileIndex)/\(totalFiles)",
                                "File encryption progress: \(percentage)%"
                            ].compactMap { $0 }.joined(separator: "\n"))
                        }
                    }
                )
            }
            catch {
                modalActivityIndicator.dismiss {
                    showError(error)
                }
                return
            }
            
            modalActivityIndicator.dismiss {
                switch viaShareSheet {
                    case true:
                        let shareVC: UIActivityViewController = UIActivityViewController(
                            activityItems: [ URL(fileURLWithPath: backupFile) ],
                            applicationActivities: nil
                        )
                        shareVC.completionWithItemsHandler = { _, _, _, _ in }
                        
                        if UIDevice.current.isIPad {
                            shareVC.excludedActivityTypes = []
                            shareVC.popoverPresentationController?.permittedArrowDirections = (targetView != nil ? [.up] : [])
                            shareVC.popoverPresentationController?.sourceView = targetView
                            shareVC.popoverPresentationController?.sourceRect = (targetView?.bounds ?? .zero)
                        }
                        
                        self?.transitionToScreen(shareVC, transitionType: .present)
                        
                    case false:
                        // Create and present the document picker
                        let documentPickerResult: DocumentPickerResult = DocumentPickerResult { _ in }
                        self?.documentPickerResult = documentPickerResult
                        
                        let documentPicker: UIDocumentPickerViewController = UIDocumentPickerViewController(
                            forExporting: [URL(fileURLWithPath: backupFile)]
                        )
                        documentPicker.delegate = documentPickerResult
                        documentPicker.modalPresentationStyle = .formSheet
                        self?.transitionToScreen(documentPicker, transitionType: .present)
                }
            }
        }
        
        self.transitionToScreen(viewController, transitionType: .present)
    }
    
    private func performImport() {
        func showError(_ error: Error) {
            self.transitionToScreen(
                ConfirmationModal(
                    info: ConfirmationModal.Info(
                        title: "theError".localized(),
                        body: {
                            switch error {
                                case CryptoKitError.incorrectKeySize:
                                    return .text("The password must be between 6 and 32 characters (padded to 32 bytes)")
                                
                                case is DatabaseError: return .text("Database key in backup file was invalid.")
                                default: return .text("\(error)")
                            }
                        }()
                    )
                ),
                transitionType: .present
            )
        }
        
        guard databaseKeyEncryptionPassword.count >= 6 else { return showError(CryptoKitError.incorrectKeySize) }
        
        let documentPickerResult: DocumentPickerResult = DocumentPickerResult { url in
            guard let url: URL = url else { return }

            let viewController: UIViewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self, password = self.databaseKeyEncryptionPassword, dependencies = self.dependencies] modalActivityIndicator in
                do {
                    let tmpUnencryptPath: String = "\(dependencies[singleton: .fileManager].temporaryDirectory)/new_session.bak"
                    let (paths, additionalFilePaths): ([String], [String]) = try DirectoryArchiver.unarchiveDirectory(
                        archivePath: url.path,
                        destinationPath: tmpUnencryptPath,
                        password: password,
                        progressChanged: { filesSaved, totalFiles, fileProgress, fileSize in
                            let percentage: Int = {
                                guard fileSize > 0 else { return 0 }
                                
                                return Int((Double(fileProgress) / Double(fileSize)) * 100)
                            }()
                            
                            DispatchQueue.main.async {
                                modalActivityIndicator.setMessage([
                                    "Decryption progress: \(percentage)%",
                                    "Files imported: \(filesSaved)/\(totalFiles)"
                                ].compactMap { $0 }.joined(separator: "\n"))
                            }
                        }
                    )
                    
                    /// Test that we actually have valid access to the database
                    guard
                        let encKeyPath: String = additionalFilePaths
                            .first(where: { $0.hasSuffix(Storage.encKeyFilename) }),
                        let databasePath: String = paths
                            .first(where: { $0.hasSuffix(Storage.dbFileName) })
                    else { throw ArchiveError.unableToFindDatabaseKey }
                    
                    DispatchQueue.main.async {
                        modalActivityIndicator.setMessage(
                            "Checking for valid database..."
                        )
                    }
                    
                    let testStorage: Storage = try Storage(
                        testAccessTo: databasePath,
                        encryptedKeyPath: encKeyPath,
                        encryptedKeyPassword: password,
                        using: dependencies
                    )
                    
                    guard testStorage.isValid else {
                        throw ArchiveError.decryptionFailed
                    }
                    
                    /// Now that we have confirmed access to the replacement database we need to
                    /// stop the current account from doing anything
                    DispatchQueue.main.async {
                        modalActivityIndicator.setMessage(
                            "Clearing current account data..."
                        )
                        
                        (UIApplication.shared.delegate as? AppDelegate)?.stopPollers()
                    }
                    
                    dependencies[singleton: .jobRunner].stopAndClearPendingJobs()
                    dependencies.mutate(cache: .libSessionNetwork) { $0.suspendNetworkAccess() }
                    dependencies[singleton: .storage].suspendDatabaseAccess()
                    try dependencies[singleton: .storage].closeDatabase()
                    
                    let deleteEnumerator: FileManager.DirectoryEnumerator? = FileManager.default.enumerator(
                        at: URL(
                            fileURLWithPath: dependencies[singleton: .fileManager].appSharedDataDirectoryPath
                        ),
                        includingPropertiesForKeys: [.isRegularFileKey]
                    )
                    let fileUrls: [URL] = (deleteEnumerator?.allObjects.compactMap { $0 as? URL } ?? [])
                    try fileUrls.forEach { url in
                        /// The database `wal` and `shm` files might not exist anymore at this point
                        /// so we should only remove files which exist to prevent errors
                        guard FileManager.default.fileExists(atPath: url.path) else { return }
                        
                        try FileManager.default.removeItem(atPath: url.path)
                    }
                    
                    /// Current account data has been removed, we now need to copy over the
                    /// newly imported data
                    DispatchQueue.main.async {
                        modalActivityIndicator.setMessage(
                            "Moving imported data..."
                        )
                    }
                    
                    try paths.forEach { path in
                        /// Need to ensure the destination directry
                        let targetPath: String = [
                            dependencies[singleton: .fileManager].appSharedDataDirectoryPath,
                            path.replacingOccurrences(of: tmpUnencryptPath, with: "")
                        ].joined()  // Already has '/' after 'appSharedDataDirectoryPath'
                        
                        try FileManager.default.createDirectory(
                            atPath: URL(fileURLWithPath: targetPath)
                                .deletingLastPathComponent()
                                .path,
                            withIntermediateDirectories: true
                        )
                        try FileManager.default.moveItem(atPath: path, toPath: targetPath)
                    }
                    
                    /// All of the main files have been moved across, we now need to replace the current database key with
                    /// the one included in the backup
                    try dependencies[singleton: .storage].replaceDatabaseKey(path: encKeyPath, password: password)
                    
                    /// The import process has completed so we need to restart the app
                    DispatchQueue.main.async {
                        self?.transitionToScreen(
                            ConfirmationModal(
                                info: ConfirmationModal.Info(
                                    title: "Import Complete",
                                    body: .text("The import completed successfully, Session must be reopened in order to complete the process."),
                                    cancelTitle: "Exit",
                                    cancelStyle: .alert_text,
                                    onCancel: { _ in exit(0) }
                                )
                            ),
                            transitionType: .present
                        )
                    }
                }
                catch {
                    modalActivityIndicator.dismiss {
                        showError(error)
                    }
                }
            }
            
            self.transitionToScreen(viewController, transitionType: .present)
        }
        self.documentPickerResult = documentPickerResult
        
        // UIDocumentPickerModeImport copies to a temp file within our container.
        // It uses more memory than "open" but lets us avoid working with security scoped URLs.
        let documentPickerVC = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        documentPickerVC.delegate = documentPickerResult
        documentPickerVC.modalPresentationStyle = .fullScreen
        
        self.transitionToScreen(documentPickerVC, transitionType: .present)
    }
}

// MARK: - Automated Test Convenience

extension DeveloperSettingsViewModel {
    static func processUnitTestEnvVariablesIfNeeded(using dependencies: Dependencies) {
#if targetEnvironment(simulator)
        enum EnvironmentVariable: String {
            case animationsEnabled
            case showStringKeys
            
            case serviceNetwork
            case forceOffline
        }
        
        ProcessInfo.processInfo.environment.forEach { key, value in
            guard let variable: EnvironmentVariable = EnvironmentVariable(rawValue: key) else { return }
            
            switch variable {
                case .animationsEnabled:
                    dependencies.set(feature: .animationsEnabled, to: (value == "true"))
                    
                    guard value == "false" else { return }
                    
                    UIView.setAnimationsEnabled(false)
                    
                case .showStringKeys:
                    dependencies.set(feature: .showStringKeys, to: (value == "true"))
                    
                case .serviceNetwork:
                    let network: ServiceNetwork
                    
                    switch value {
                        case "testnet": network = .testnet
                        default: network = .mainnet
                    }
                    
                    DeveloperSettingsViewModel.updateServiceNetwork(to: network, using: dependencies)
                    
                case .forceOffline:
                    dependencies.set(feature: .forceOffline, to: (value == "true"))
            }
        }
#endif
    }
}

// MARK: - DocumentPickerResult

private class DocumentPickerResult: NSObject, UIDocumentPickerDelegate {
    private let onResult: (URL?) -> Void
    
    init(onResult: @escaping (URL?) -> Void) {
        self.onResult = onResult
    }
    
    // MARK: - UIDocumentPickerDelegate
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url: URL = urls.first else {
            self.onResult(nil)
            return
        }
        
        self.onResult(url)
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.onResult(nil)
    }
}

// MARK: - Listable Conformance

extension ServiceNetwork: @retroactive ContentIdentifiable {}
extension ServiceNetwork: @retroactive ContentEquatable {}
extension ServiceNetwork: Listable {}
extension Log.Level: @retroactive ContentIdentifiable {}
extension Log.Level: @retroactive ContentEquatable {}
extension Log.Level: Listable {}
