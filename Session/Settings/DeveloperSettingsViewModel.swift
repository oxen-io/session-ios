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

class DeveloperSettingsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private var showAdvancedLogging: Bool = false
    private var databaseKeyEncryptionPassword: String = ""
    
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
        
        // MARK: - Conformance
        
        public typealias DifferenceIdentifier = String
        
        public var differenceIdentifier: String {
            switch self {
                case .developerMode: return "developerMode"
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
            }
        }
        
        public func isContentEqual(to source: TableItem) -> Bool {
            self.differenceIdentifier == source.differenceIdentifier
        }
        
        public static var allCases: [TableItem] {
            var result: [TableItem] = []
            switch TableItem.developerMode {
                case .developerMode: result.append(.developerMode); fallthrough
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
                
                case .exportDatabase: result.append(.exportDatabase)
            }
            
            return result
        }
    }
    
    // MARK: - Content
    
    private struct State: Equatable {
        let developerMode: Bool
        
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
                model: .general,
                elements: [
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
            ),
            SectionModel(
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
            ),
            SectionModel(
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
                case .developerMode: break      // Not a feature
                case .showStringKeys: updateFlag(for: .showStringKeys, to: nil)
                
                case .resetSnodeCache: break    // Not a feature
                case .exportDatabase: break     // Not a feature
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
        
        forceRefresh(type: .databaseQuery)
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
                    confirmStyle: .danger,
                    cancelStyle: .alert_text,
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
                                let exportInfo = try dependencies[singleton: .storage].exportInfo(password: password, using: dependencies)
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

extension ServiceNetwork: @retroactive ContentIdentifiable {}
extension ServiceNetwork: @retroactive ContentEquatable {}
extension ServiceNetwork: @retroactive Listable {}
extension Log.Level: @retroactive ContentIdentifiable {}
extension Log.Level: @retroactive ContentEquatable {}
extension Log.Level: Listable {}
