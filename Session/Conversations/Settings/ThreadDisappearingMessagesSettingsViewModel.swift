// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SessionSnodeKit

class ThreadDisappearingMessagesSettingsViewModel: SessionTableViewModel, NavigationItemSource, NavigatableStateHolder, ObservableTableSource {
    typealias TableItem = String
    
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private let threadId: String
    private let threadVariant: SessionThread.Variant
    private var isNoteToSelf: Bool
    private let currentUserIsClosedGroupMember: Bool?
    private let currentUserIsClosedGroupAdmin: Bool?
    private let originalConfig: DisappearingMessagesConfiguration
    private var configSubject: CurrentValueSubject<DisappearingMessagesConfiguration, Never>
    
    // MARK: - Initialization
    
    init(
        threadId: String,
        threadVariant: SessionThread.Variant,
        currentUserIsClosedGroupMember: Bool?,
        currentUserIsClosedGroupAdmin: Bool?,
        config: DisappearingMessagesConfiguration,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.threadVariant = threadVariant
        self.isNoteToSelf = (threadId == getUserSessionId(using: dependencies).hexString)
        self.currentUserIsClosedGroupMember = currentUserIsClosedGroupMember
        self.currentUserIsClosedGroupAdmin = currentUserIsClosedGroupAdmin
        self.originalConfig = config
        self.configSubject = CurrentValueSubject(config)
    }
    
    // MARK: - Config
    
    enum NavItem: Equatable {
        case save
    }
    
    public enum Section: SessionTableSection {
        case type
        case timerLegacy
        case timerDisappearAfterSend
        case timerDisappearAfterRead
        case noteToSelf
        case group
        
        var title: String? {
            switch self {
                case .type: return "DISAPPERING_MESSAGES_TYPE_TITLE".localized()
                // We need to keep these although the titles of them are the same
                // because we need them to trigger timer section to refresh when
                // the user selects different disappearing messages type
                case .timerLegacy, .timerDisappearAfterSend, .timerDisappearAfterRead: return "DISAPPERING_MESSAGES_TIMER_TITLE".localized()
                case .noteToSelf: return nil
                case .group: return nil
            }
        }
        
        var style: SessionTableSectionStyle { return .titleRoundedContent }
        
        var footer: String? {
            switch self {
                case .group: return "DISAPPERING_MESSAGES_GROUP_WARNING_ADMIN_ONLY".localized()
                default: return nil
            }
        }
    }
    
    // MARK: - Content
    
    let title: String = "DISAPPEARING_MESSAGES".localized()
    lazy var subtitle: String? = {
        switch (threadVariant, isNoteToSelf) {
            case (.contact, false): return "DISAPPERING_MESSAGES_SUBTITLE_CONTACTS".localized()
            case (.group, _): return "DISAPPERING_MESSAGES_SUBTITLE_GROUPS".localized()
            case (.community, _): return nil
                
            case (.legacyGroup, _), (_, true):
                guard dependencies[feature: .updatedDisappearingMessages] else {
                    return (isNoteToSelf ? nil : "DISAPPERING_MESSAGES_SUBTITLE_CONTACTS".localized())
                }
                
                return "DISAPPERING_MESSAGES_SUBTITLE_GROUPS".localized()
        }
    }()
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = configSubject
        .map { [originalConfig] currentConfig -> Bool in
            // Need to explicitly compare values because 'lastChangeTimestampMs' will differ
            return (
                currentConfig.isEnabled != originalConfig.isEnabled ||
                currentConfig.durationSeconds != originalConfig.durationSeconds ||
                currentConfig.type != originalConfig.type
            )
        }
        .removeDuplicates()
        .map { [weak self] shouldShowConfirmButton in
            guard shouldShowConfirmButton else { return nil }
            
            return SessionButton.Info(
                style: .bordered,
                title: "DISAPPERING_MESSAGES_SAVE_TITLE".localized(),
                isEnabled: true,
                accessibility: Accessibility(
                    identifier: "Set button",
                    label: "Set button"
                ),
                minWidth: 110,
                onTap: {
                    self?.saveChanges()
                    self?.dismissScreen()
                }
            )
        }
        .eraseToAnyPublisher()
    
    lazy var observation: TargetObservation = ObservationBuilder
        .subject(configSubject)
        .compactMap { [weak self] currentConfig -> [SectionModel]? in self?.content(currentConfig) }
            
    private func content(_ currentConfig: DisappearingMessagesConfiguration) -> [SectionModel] {
        switch (threadVariant, isNoteToSelf) {
            case (.contact, false):
                return [
                    SectionModel(
                        model: .type,
                        elements: [
                            SessionCell.Info(
                                id: "DISAPPEARING_MESSAGES_OFF".localized(),
                                title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                trailingAccessory: .radio(
                                    isSelected: !currentConfig.isEnabled
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disable disappearing messages (Off option)",
                                    label: "Disable disappearing messages (Off option)"
                                ),
                                onTap: { [weak self, dependencies] in
                                    self?.configSubject.send(
                                        currentConfig.with(
                                            isEnabled: false,
                                            durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.off.seconds,
                                            lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs(
                                                using: dependencies
                                            )
                                        )
                                    )
                                }
                            ),
                            (dependencies[feature: .updatedDisappearingMessages] ? nil :
                                SessionCell.Info(
                                    id: "DISAPPEARING_MESSAGES_TYPE_LEGACY_TITLE".localized(),
                                    title: "DISAPPEARING_MESSAGES_TYPE_LEGACY_TITLE".localized(),
                                    subtitle: "DISAPPEARING_MESSAGES_TYPE_LEGACY_DESCRIPTION".localized(),
                                    trailingAccessory: .radio(
                                        isSelected: (
                                            currentConfig.isEnabled &&
                                            !dependencies[feature: .updatedDisappearingMessages]
                                        )
                                    ),
                                    onTap: { [weak self, originalConfig, dependencies] in
                                        switch (originalConfig.isEnabled, originalConfig.type) {
                                            case (true, .disappearAfterRead): self?.configSubject.send(originalConfig)
                                            default: self?.configSubject.send(
                                                currentConfig.with(
                                                    isEnabled: true,
                                                    durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.legacy.seconds,
                                                    type: .disappearAfterRead, // Default for 1-1
                                                    lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs(
                                                        using: dependencies
                                                    )
                                                )
                                            )
                                        }
                                    }
                                )
                            ),
                            SessionCell.Info(
                                id: "DISAPPERING_MESSAGES_TYPE_AFTER_READ_TITLE".localized(),
                                title: "DISAPPERING_MESSAGES_TYPE_AFTER_READ_TITLE".localized(),
                                subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_READ_DESCRIPTION".localized(),
                                trailingAccessory: .radio(
                                    isSelected: (
                                        currentConfig.isEnabled &&
                                        currentConfig.type == .disappearAfterRead &&
                                        dependencies[feature: .updatedDisappearingMessages]
                                    )
                                ),
                                styling: SessionCell.StyleInfo(
                                    tintColor: (dependencies[feature: .updatedDisappearingMessages] ?
                                        .textPrimary :
                                        .disabled
                                    )
                                ),
                                isEnabled: dependencies[feature: .updatedDisappearingMessages],
                                accessibility: Accessibility(
                                    identifier: "Disappear after read option",
                                    label: "Disappear after read option"
                                ),
                                onTap: { [weak self, originalConfig, dependencies] in
                                    switch (originalConfig.isEnabled, originalConfig.type) {
                                        case (true, .disappearAfterRead): self?.configSubject.send(originalConfig)
                                        default: self?.configSubject.send(
                                            currentConfig.with(
                                                isEnabled: true,
                                                durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.disappearAfterRead.seconds,
                                                type: .disappearAfterRead,
                                                lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs(
                                                    using: dependencies
                                                )
                                            )
                                        )
                                    }
                                }
                            ),
                            SessionCell.Info(
                                id: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_DESCRIPTION".localized(),
                                trailingAccessory: .radio(
                                    isSelected: (
                                        currentConfig.isEnabled &&
                                        currentConfig.type == .disappearAfterSend &&
                                        dependencies[feature: .updatedDisappearingMessages]
                                    )
                                ),
                                styling: SessionCell.StyleInfo(
                                    tintColor: (dependencies[feature: .updatedDisappearingMessages] ?
                                        .textPrimary :
                                        .disabled
                                    )
                                ),
                                isEnabled: dependencies[feature: .updatedDisappearingMessages],
                                accessibility: Accessibility(
                                    identifier: "Disappear after send option",
                                    label: "Disappear after send option"
                                ),
                                onTap: { [weak self, originalConfig, dependencies] in
                                    switch (originalConfig.isEnabled, originalConfig.type) {
                                        case (true, .disappearAfterSend): self?.configSubject.send(originalConfig)
                                        default: self?.configSubject.send(
                                            currentConfig.with(
                                                isEnabled: true,
                                                durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.disappearAfterSend.seconds,
                                                type: .disappearAfterSend,
                                                lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs(
                                                    using: dependencies
                                                )
                                            )
                                        )
                                    }
                                }
                            )
                        ].compactMap { $0 }
                    ),
                    (!currentConfig.isEnabled ? nil :
                        SectionModel(
                            model: {
                                guard dependencies[feature: .updatedDisappearingMessages] else { return .timerLegacy }

                                return (currentConfig.type == .disappearAfterSend ?
                                    .timerDisappearAfterSend :
                                    .timerDisappearAfterRead
                                )
                            }(),
                            elements: DisappearingMessagesConfiguration
                                .validDurationsSeconds({
                                    guard dependencies[feature: .updatedDisappearingMessages] else {
                                        return .disappearAfterSend
                                    }

                                    return (currentConfig.type ?? .disappearAfterSend)
                                }(), using: dependencies)
                                .map { duration in
                                    let title: String = duration.formatted(format: .long)

                                    return SessionCell.Info(
                                        id: title,
                                        title: title,
                                        trailingAccessory: .radio(
                                            isSelected: (
                                                currentConfig.isEnabled &&
                                                currentConfig.durationSeconds == duration
                                            )
                                        ),
                                        accessibility: Accessibility(
                                            identifier: "Time option",
                                            label: "Time option"
                                        ),
                                        onTap: { [weak self, dependencies] in
                                            self?.configSubject.send(
                                                currentConfig.with(
                                                    durationSeconds: duration,
                                                    lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs(
                                                        using: dependencies
                                                    )
                                                )
                                            )
                                        }
                                    )
                                }
                        )
                    )
                ].compactMap { $0 }
                
            case (.group, _):
                return [
                    SectionModel(
                        model: .group,
                        elements: [
                            SessionCell.Info(
                                id: "DISAPPEARING_MESSAGES_OFF".localized(),
                                title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                trailingAccessory: .radio(
                                    isSelected: !currentConfig.isEnabled
                                ),
                                isEnabled: (currentUserIsClosedGroupAdmin == true),
                                accessibility: Accessibility(
                                    identifier: "Disable disappearing messages (Off option)",
                                    label: "Disable disappearing messages (Off option)"
                                ),
                                onTap: { [weak self, dependencies] in
                                    self?.configSubject.send(
                                        currentConfig.with(
                                            isEnabled: false,
                                            durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.off.seconds,
                                            lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs(
                                                using: dependencies
                                            )
                                        )
                                    )
                                }
                            )
                        ]
                        .appending(
                            contentsOf: DisappearingMessagesConfiguration
                                .validDurationsSeconds(.disappearAfterSend, using: dependencies)
                                .map { duration in
                                    let title: String = duration.formatted(format: .long)

                                    return SessionCell.Info(
                                        id: title,
                                        title: title,
                                        trailingAccessory: .radio(
                                            isSelected: (
                                                currentConfig.isEnabled &&
                                                currentConfig.durationSeconds == duration
                                            )
                                        ),
                                        isEnabled: (currentUserIsClosedGroupAdmin == true),
                                        accessibility: Accessibility(
                                            identifier: "Time option",
                                            label: "Time option"
                                        ),
                                        onTap: { [weak self, dependencies] in
                                            // If the new disappearing messages config feature flag isn't
                                            // enabled then the 'isEnabled' and 'type' values are set via
                                            // the first section so pass `nil` values to keep the existing
                                            // setting
                                            self?.configSubject.send(
                                                currentConfig.with(
                                                    isEnabled: true,
                                                    durationSeconds: duration,
                                                    type: .disappearAfterSend,
                                                    lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs(
                                                        using: dependencies
                                                    )
                                                )
                                            )
                                        }
                                    )
                                }
                        )
                    )
                ]

            case (.legacyGroup, _), (_, true):
                return [
                    (dependencies[feature: .updatedDisappearingMessages] ? nil :
                        SectionModel(
                            model: .type,
                            elements: [
                                SessionCell.Info(
                                    id: "DISAPPEARING_MESSAGES_OFF".localized(),
                                    title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                    trailingAccessory: .radio(
                                        isSelected: !currentConfig.isEnabled
                                    ),
                                    isEnabled: (
                                        isNoteToSelf ||
                                        currentUserIsClosedGroupMember == true
                                    ),
                                    accessibility: Accessibility(
                                        identifier: "Disable disappearing messages (Off option)",
                                        label: "Disable disappearing messages (Off option)"
                                    ),
                                    onTap: { [weak self, dependencies] in
                                        self?.configSubject.send(
                                            currentConfig.with(
                                                isEnabled: false,
                                                durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.off.seconds,
                                                lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs(
                                                    using: dependencies
                                                )
                                            )
                                        )
                                    }
                                ),
                                SessionCell.Info(
                                    id: "DISAPPEARING_MESSAGES_TYPE_LEGACY_TITLE".localized(),
                                    title: "DISAPPEARING_MESSAGES_TYPE_LEGACY_TITLE".localized(),
                                    subtitle: "DISAPPEARING_MESSAGES_TYPE_LEGACY_DESCRIPTION".localized(),
                                    trailingAccessory: .radio(
                                        isSelected: (
                                            currentConfig.isEnabled &&
                                            !dependencies[feature: .updatedDisappearingMessages]
                                        )
                                    ),
                                    isEnabled: (
                                        isNoteToSelf ||
                                        currentUserIsClosedGroupMember == true
                                    ),
                                    onTap: { [weak self, originalConfig, dependencies] in
                                        switch (originalConfig.isEnabled, originalConfig.type) {
                                            case (true, .disappearAfterSend): self?.configSubject.send(originalConfig)
                                            default: self?.configSubject.send(
                                                currentConfig.with(
                                                    isEnabled: true,
                                                    durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.legacy.seconds,
                                                    type: .disappearAfterSend, // Default for closed group & note to self
                                                    lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs(
                                                        using: dependencies
                                                    )
                                                )
                                            )
                                        }
                                    }
                                ),
                                SessionCell.Info(
                                    id: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                    title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                    subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_DESCRIPTION".localized(),
                                    trailingAccessory: .radio(isSelected: false),
                                    styling: SessionCell.StyleInfo(tintColor: .disabled),
                                    isEnabled: false
                                )
                            ]
                        )
                    ),
                    (!dependencies[feature: .updatedDisappearingMessages] && !currentConfig.isEnabled ? nil :
                        SectionModel(
                            model: {
                                guard dependencies[feature: .updatedDisappearingMessages] else {
                                    return (currentConfig.type == .disappearAfterSend ?
                                        .timerDisappearAfterSend :
                                        .timerDisappearAfterRead
                                    )
                                }

                                return (isNoteToSelf ? .noteToSelf : .group)
                            }(),
                            elements: [
                                (!dependencies[feature: .updatedDisappearingMessages] ? nil :
                                    SessionCell.Info(
                                        id: "DISAPPEARING_MESSAGES_OFF".localized(),
                                        title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                        trailingAccessory: .radio(
                                            isSelected: !currentConfig.isEnabled
                                        ),
                                        isEnabled: (
                                            isNoteToSelf ||
                                            currentUserIsClosedGroupMember == true
                                        ),
                                        accessibility: Accessibility(
                                            identifier: "Disable disappearing messages (Off option)",
                                            label: "Disable disappearing messages (Off option)"
                                        ),
                                        onTap: { [weak self, dependencies] in
                                            self?.configSubject.send(
                                                currentConfig.with(
                                                    isEnabled: false,
                                                    durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.off.seconds,
                                                    lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs(
                                                        using: dependencies
                                                    )
                                                )
                                            )
                                        }
                                    )
                                )
                            ]
                            .compactMap { $0 }
                            .appending(
                                contentsOf: DisappearingMessagesConfiguration
                                    .validDurationsSeconds(.disappearAfterSend, using: dependencies)
                                    .map { duration in
                                        let title: String = duration.formatted(format: .long)

                                        return SessionCell.Info(
                                            id: title,
                                            title: title,
                                            trailingAccessory: .radio(
                                                isSelected: (
                                                    currentConfig.isEnabled &&
                                                    currentConfig.durationSeconds == duration
                                                )
                                            ),
                                            isEnabled: (
                                                isNoteToSelf ||
                                                currentUserIsClosedGroupMember == true
                                            ),
                                            accessibility: Accessibility(
                                                identifier: "Time option",
                                                label: "Time option"
                                            ),
                                            onTap: { [weak self, dependencies] in
                                                // If the new disappearing messages config feature flag isn't
                                                // enabled then the 'isEnabled' and 'type' values are set via
                                                // the first section so pass `nil` values to keep the existing
                                                // setting
                                                self?.configSubject.send(
                                                    currentConfig.with(
                                                        isEnabled: (dependencies[feature: .updatedDisappearingMessages] ?
                                                            true :
                                                            nil
                                                        ),
                                                        durationSeconds: duration,
                                                        type: (dependencies[feature: .updatedDisappearingMessages] ?
                                                            .disappearAfterSend :
                                                           nil
                                                        ),
                                                        lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs(
                                                            using: dependencies
                                                        )
                                                    )
                                                )
                                            }
                                        )
                                    }
                            )
                        )
                    )
                ].compactMap { $0 }

            case (.community, _):
                return [] // Should not happen
        }
    }
    
    // MARK: - Functions
    
    private func saveChanges() {
        let updatedConfig: DisappearingMessagesConfiguration = self.configSubject.value

        guard self.originalConfig != updatedConfig else { return }

        dependencies[singleton: .storage].writeAsync(using: dependencies) { [threadId, threadVariant, dependencies, originalConfig] db in
            try updatedConfig.upserted(db)
            
            _ = try Interaction
                .filter(Interaction.Columns.threadId == threadId)
                .filter(Interaction.Columns.variant == Interaction.Variant.infoDisappearingMessagesUpdate)
                .deleteAll(db)
            
            let currentOffsetTimestampMs: Int64 = SnodeAPI.currentOffsetTimestampMs(using: dependencies)
            
            let interaction: Interaction = try Interaction(
                threadId: threadId,
                authorId: getUserSessionId(db, using: dependencies).hexString,
                variant: .infoDisappearingMessagesUpdate,
                body: updatedConfig.messageInfoString(
                    with: nil,
                    isPreviousOff: !originalConfig.isEnabled,
                    using: dependencies
                ),
                timestampMs: currentOffsetTimestampMs,
                expiresInSeconds: (updatedConfig.isEnabled ? nil : originalConfig.durationSeconds),
                expiresStartedAtMs: (!updatedConfig.isEnabled && originalConfig.type == .disappearAfterSend ? Double(currentOffsetTimestampMs) : nil)
            )
            .inserted(db)
            
            // Send a control message that the disappearing messages setting changed
            switch threadVariant {
                case .group:
                    try MessageSender.send(
                        db,
                        message: GroupUpdateInfoChangeMessage(
                            changeType: .disappearingMessages,
                            updatedExpiration: UInt32(updatedConfig.isEnabled ? updatedConfig.durationSeconds : 0),
                            sentTimestamp: UInt64(currentOffsetTimestampMs),
                            authMethod: try Authentication.with(
                                db,
                                sessionIdHexString: threadId,
                                using: dependencies
                            ),
                            using: dependencies
                        ),
                        interactionId: nil,
                        threadId: threadId,
                        threadVariant: .group,
                        using: dependencies
                    )
                    
                default:
                    let duration: UInt32? = {
                        guard !dependencies[feature: .updatedDisappearingMessages] else { return nil }
                        return UInt32(floor(updatedConfig.isEnabled ? updatedConfig.durationSeconds : 0))
                    }()

                    try MessageSender.send(
                        db,
                        message: ExpirationTimerUpdate(
                            syncTarget: nil,
                            duration: duration
                        ),
                        interactionId: interaction.id,
                        threadId: threadId,
                        threadVariant: threadVariant,
                        using: dependencies
                    )
            }
        }
        
        // Contacts & legacy closed groups need to update LibSession
        dependencies[singleton: .storage].writeAsync(using: dependencies) { [threadId, threadVariant, dependencies] db in
            switch threadVariant {
                case .contact:
                    try LibSession
                        .update(
                            db,
                            sessionId: threadId,
                            disappearingMessagesConfig: updatedConfig,
                            using: dependencies
                        )
                
                case .legacyGroup:
                    try LibSession
                        .update(
                            db,
                            legacyGroupSessionId: threadId,
                            disappearingConfig: updatedConfig,
                            using: dependencies
                        )
                    
                case .group:
                    try LibSession
                        .update(
                            db,
                            groupSessionId: SessionId(.group, hex: threadId),
                            disappearingConfig: updatedConfig,
                            using: dependencies
                        )
                    
                default: break
            }
        }
    }
}
