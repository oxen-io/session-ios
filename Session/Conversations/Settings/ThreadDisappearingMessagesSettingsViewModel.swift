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
        self.isNoteToSelf = (threadId == dependencies[cache: .general].sessionId.hexString)
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
                case .type: return "disappearingMessagesDeleteType".localized()
                // We need to keep these although the titles of them are the same
                // because we need them to trigger timer section to refresh when
                // the user selects different disappearing messages type
                case .timerLegacy, .timerDisappearAfterSend, .timerDisappearAfterRead: return "disappearingMessagesTimer".localized()
                case .noteToSelf: return nil
                case .group: return nil
            }
        }
        
        var style: SessionTableSectionStyle { return .titleRoundedContent }
        
        var footer: String? {
            switch self {
                case .group: 
                    return "\("disappearingMessagesDescription".localized())\n\("disappearingMessagesOnlyAdmins".localized())"
                default: return nil
            }
        }
    }
    
    // MARK: - Content
    
    let title: String = "disappearingMessages".localized()
    lazy var subtitle: String? = {
        switch (threadVariant, isNoteToSelf) {
            case (.contact, false): return "disappearingMessagesDescription1".localized()
            case (.group, _), (.legacyGroup, _): return "disappearingMessagesDisappearAfterSendDescription".localized()
            case (.community, _): return nil
            case (_, true): return "disappearingMessagesDescription".localized()
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
        .map { [weak self] shouldShowConfirmButton -> SessionButton.Info? in
            guard shouldShowConfirmButton else { return nil }
            
            return SessionButton.Info(
                style: .bordered,
                title: "set".localized(),
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
                                id: "off".localized(),
                                title: "off".localized(),
                                trailingAccessory: .radio(
                                    isSelected: !currentConfig.isEnabled,
                                    accessibility: Accessibility(
                                        identifier: "Off - Radio"
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disable disappearing messages (Off option)",
                                    label: "Disable disappearing messages (Off option)"
                                ),
                                onTap: { [weak self] in
                                    self?.configSubject.send(
                                        currentConfig.with(
                                            isEnabled: false,
                                            durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.off.seconds
                                        )
                                    )
                                }
                            ),
                            SessionCell.Info(
                                id: "disappearingMessagesDisappearAfterRead".localized(),
                                title: "disappearingMessagesDisappearAfterRead".localized(),
                                subtitle: "disappearingMessagesDisappearAfterReadDescription".localized(),
                                trailingAccessory: .radio(
                                    isSelected: (
                                        currentConfig.isEnabled &&
                                        currentConfig.type == .disappearAfterRead
                                    ),
                                    accessibility: Accessibility(
                                        identifier: "Disappear After Read - Radio"
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disappear after read option",
                                    label: "Disappear after read option"
                                ),
                                onTap: { [weak self, originalConfig] in
                                    switch (originalConfig.isEnabled, originalConfig.type) {
                                        case (true, .disappearAfterRead): self?.configSubject.send(originalConfig)
                                        default: self?.configSubject.send(
                                            currentConfig.with(
                                                isEnabled: true,
                                                durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.disappearAfterRead.seconds,
                                                type: .disappearAfterRead
                                            )
                                        )
                                    }
                                }
                            ),
                            SessionCell.Info(
                                id: "disappearingMessagesDisappearAfterSend".localized(),
                                title: "disappearingMessagesDisappearAfterSend".localized(),
                                subtitle: "disappearingMessagesDisappearAfterSendDescription".localized(),
                                trailingAccessory: .radio(
                                    isSelected: (
                                        currentConfig.isEnabled &&
                                        currentConfig.type == .disappearAfterSend
                                    ),
                                    accessibility: Accessibility(
                                        identifier: "Disappear After Send - Radio"
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disappear after send option",
                                    label: "Disappear after send option"
                                ),
                                onTap: { [weak self, originalConfig] in
                                    switch (originalConfig.isEnabled, originalConfig.type) {
                                        case (true, .disappearAfterSend): self?.configSubject.send(originalConfig)
                                        default: self?.configSubject.send(
                                            currentConfig.with(
                                                isEnabled: true,
                                                durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.disappearAfterSend.seconds,
                                                type: .disappearAfterSend
                                            )
                                        )
                                    }
                                }
                            )
                        ].compactMap { $0 }
                    ),
                    (!currentConfig.isEnabled ? nil :
                        SectionModel(
                            model: (currentConfig.type == .disappearAfterSend ?
                                .timerDisappearAfterSend :
                                .timerDisappearAfterRead
                            ),
                            elements: DisappearingMessagesConfiguration
                                .validDurationsSeconds(currentConfig.type ?? .disappearAfterSend, using: dependencies)
                                .map { duration in
                                    let title: String = duration.formatted(format: .long)

                                    return SessionCell.Info(
                                        id: title,
                                        title: title,
                                        trailingAccessory: .radio(
                                            isSelected: (
                                                currentConfig.isEnabled &&
                                                currentConfig.durationSeconds == duration
                                            ),
                                            accessibility: Accessibility(
                                                identifier: "\(title) - Radio"
                                            )
                                        ),
                                        accessibility: Accessibility(
                                            identifier: "Time option",
                                            label: "Time option"
                                        ),
                                        onTap: { [weak self] in
                                            self?.configSubject.send(
                                                currentConfig.with(
                                                    durationSeconds: duration
                                                )
                                            )
                                        }
                                    )
                                }
                        )
                    )
                ].compactMap { $0 }
            
            case (.legacyGroup, _), (.group, _), (_, true):
                return [
                    SectionModel(
                        model: (isNoteToSelf ? .noteToSelf : .group),
                        elements: [
                            SessionCell.Info(
                                id: "off".localized(),
                                title: "off".localized(),
                                trailingAccessory: .radio(
                                    isSelected: !currentConfig.isEnabled,
                                    accessibility: Accessibility(
                                        identifier: "Off - Radio"
                                    )
                                ),
                                isEnabled: (
                                    isNoteToSelf ||
                                    currentUserIsClosedGroupAdmin == true
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disable disappearing messages (Off option)",
                                    label: "Disable disappearing messages (Off option)"
                                ),
                                onTap: { [weak self] in
                                    self?.configSubject.send(
                                        currentConfig.with(
                                            isEnabled: false,
                                            durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.off.seconds
                                        )
                                    )
                                }
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
                                            ),
                                            accessibility: Accessibility(
                                                identifier: "\(title) - Radio"
                                            )
                                        ),
                                        isEnabled: (isNoteToSelf || currentUserIsClosedGroupAdmin == true),
                                        accessibility: Accessibility(
                                            identifier: "Time option",
                                            label: "Time option"
                                        ),
                                        onTap: { [weak self] in
                                            self?.configSubject.send(
                                                currentConfig.with(
                                                    isEnabled: true,
                                                    durationSeconds: duration,
                                                    type: .disappearAfterSend
                                                )
                                            )
                                        }
                                    )
                                }
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

        dependencies[singleton: .storage].writeAsync { [threadId, threadVariant, dependencies] db in
            // Update the local state
            try updatedConfig.upserted(db)
            
            let currentOffsetTimestampMs: Int64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
            let interactionId = try updatedConfig
                .saved(db)
                .insertControlMessage(
                    db,
                    threadVariant: threadVariant,
                    authorId: dependencies[cache: .general].sessionId.hexString,
                    timestampMs: currentOffsetTimestampMs,
                    serverHash: nil,
                    serverExpirationTimestamp: nil,
                    using: dependencies
                )
            
            // Update libSession
            switch threadVariant {
                case .contact:
                    try LibSession.update(
                        db,
                        sessionId: threadId,
                        disappearingMessagesConfig: updatedConfig,
                        using: dependencies
                    )
                
                case .legacyGroup:
                    try LibSession.update(
                        db,
                        legacyGroupSessionId: threadId,
                        disappearingConfig: updatedConfig,
                        using: dependencies
                    )
                    
                case .group:
                    try LibSession.update(
                        db,
                        groupSessionId: SessionId(.group, hex: threadId),
                        disappearingConfig: updatedConfig,
                        using: dependencies
                    )
                    
                default: break
            }
            
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
                                swarmPublicKey: threadId,
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
                    try MessageSender.send(
                        db,
                        message: ExpirationTimerUpdate()
                            .with(sentTimestamp: UInt64(currentOffsetTimestampMs))
                            .with(updatedConfig),
                        interactionId: interactionId,
                        threadId: threadId,
                        threadVariant: threadVariant,
                        using: dependencies
                    )
            }
        }
    }
}

extension String: Differentiable {}
