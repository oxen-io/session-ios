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
    private let config: DisappearingMessagesConfiguration
    private var currentSelection: CurrentValueSubject<DisappearingMessagesConfiguration, Error>
    private var shouldShowConfirmButton: CurrentValueSubject<Bool, Never>
    
    // MARK: - Initialization
    
    init(
        threadId: String,
        threadVariant: SessionThread.Variant,
        currentUserIsClosedGroupMember: Bool?,
        currentUserIsClosedGroupAdmin: Bool?,
        config: DisappearingMessagesConfiguration,
        using dependencies: Dependencies = Dependencies()
    ) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.threadVariant = threadVariant
        self.isNoteToSelf = (threadId == getUserHexEncodedPublicKey(using: dependencies))
        self.currentUserIsClosedGroupMember = currentUserIsClosedGroupMember
        self.currentUserIsClosedGroupAdmin = currentUserIsClosedGroupAdmin
        self.config = config
        self.currentSelection = CurrentValueSubject(config)
        self.shouldShowConfirmButton = CurrentValueSubject(false)
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
                case .group: return "disappearingMessagesOnlyAdmins".localized()
                default: return nil
            }
        }
    }
    
    // MARK: - Content
    
    let title: String = "disappearingMessages".localized()
    lazy var subtitle: String? = {
        guard Features.useNewDisappearingMessagesConfig else {
            return (isNoteToSelf ? nil : "disappearingMessagesDescription".localized())
        }
        
        if threadVariant == .contact && !isNoteToSelf {
            return "disappearingMessagesDescription1".localized()
        }
        
        return "disappearingMessagesDisappearAfterSendDescription".localized()
    }()
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = shouldShowConfirmButton
        .removeDuplicates()
        .map { [weak self] shouldShowConfirmButton in
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
        .subject(currentSelection)
        .map { [weak self, threadVariant, isNoteToSelf, config, currentUserIsClosedGroupMember, currentUserIsClosedGroupAdmin] currentSelection -> [SectionModel] in
            switch (threadVariant, isNoteToSelf) {
                case (.contact, false):
                    return [
                        SectionModel(
                            model: .type,
                            elements: [
                                SessionCell.Info(
                                    id: "off".localized(),
                                    title: "off".localized(),
                                    rightAccessory: .radio(
                                        isSelected: { (self?.currentSelection.value.isEnabled == false) }
                                    ),
                                    accessibility: Accessibility(
                                        identifier: "Disable disappearing messages (Off option)",
                                        label: "Disable disappearing messages (Off option)"
                                    ),
                                    onTap: {
                                        let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                            .with(
                                                isEnabled: false,
                                                durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.off.seconds
                                            )
                                        self?.shouldShowConfirmButton.send(updatedConfig != config)
                                        self?.currentSelection.send(updatedConfig)
                                    }
                                ),
                                (Features.useNewDisappearingMessagesConfig ? nil :
                                    SessionCell.Info(
                                        id: "deleteAfterLegacyDisappearingMessagesLegacy".localized(),
                                        title: "deleteAfterLegacyDisappearingMessagesLegacy".localized(),
                                        subtitle: "deleteAfterLegacyDisappearingMessagesOriginal".localized(),
                                        rightAccessory: .radio(
                                            isSelected: {
                                                (self?.currentSelection.value.isEnabled == true) &&
                                                !Features.useNewDisappearingMessagesConfig
                                            }
                                        ),
                                        onTap: {
                                            let updatedConfig: DisappearingMessagesConfiguration = {
                                                if (config.isEnabled == true && config.type == .disappearAfterRead) {
                                                    return config
                                                }
                                                return currentSelection
                                                    .with(
                                                        isEnabled: true,
                                                        durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.legacy.seconds,
                                                        type: .disappearAfterRead // Default for 1-1
                                                    )
                                            }()
                                            self?.shouldShowConfirmButton.send(updatedConfig != config)
                                            self?.currentSelection.send(updatedConfig)
                                        }
                                    )
                                ),
                                SessionCell.Info(
                                    id: "disappearingMessagesDisappearAfterRead".localized(),
                                    title: "disappearingMessagesDisappearAfterRead".localized(),
                                    subtitle: "disappearingMessagesDisappearAfterReadDescription".localized(),
                                    rightAccessory: .radio(
                                        isSelected: {
                                            (self?.currentSelection.value.isEnabled == true) &&
                                            (self?.currentSelection.value.type == .disappearAfterRead) &&
                                            Features.useNewDisappearingMessagesConfig
                                        }
                                    ),
                                    styling: SessionCell.StyleInfo(
                                        tintColor: (Features.useNewDisappearingMessagesConfig ?
                                            .textPrimary :
                                            .disabled
                                        )
                                    ),
                                    isEnabled: Features.useNewDisappearingMessagesConfig,
                                    accessibility: Accessibility(
                                        identifier: "Disappear after read option",
                                        label: "Disappear after read option"
                                    ),
                                    onTap: {
                                        let updatedConfig: DisappearingMessagesConfiguration = {
                                            if (config.isEnabled == true && config.type == .disappearAfterRead) {
                                                return config
                                            }
                                            return currentSelection
                                                .with(
                                                    isEnabled: true,
                                                    durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.disappearAfterRead.seconds,
                                                    type: .disappearAfterRead
                                                )
                                        }()
                                        self?.shouldShowConfirmButton.send(updatedConfig != config)
                                        self?.currentSelection.send(updatedConfig)
                                    }
                                ),
                                SessionCell.Info(
                                    id: "disappearingMessagesDisappearAfterSend".localized(),
                                    title: "disappearingMessagesDisappearAfterSend".localized(),
                                    subtitle: "disappearingMessagesDisappearAfterSendDescription".localized(),
                                    rightAccessory: .radio(
                                        isSelected: {
                                            (self?.currentSelection.value.isEnabled == true) &&
                                            (self?.currentSelection.value.type == .disappearAfterSend) &&
                                            Features.useNewDisappearingMessagesConfig
                                        }
                                    ),
                                    styling: SessionCell.StyleInfo(
                                        tintColor: (Features.useNewDisappearingMessagesConfig ?
                                            .textPrimary :
                                            .disabled
                                        )
                                    ),
                                    isEnabled: Features.useNewDisappearingMessagesConfig,
                                    accessibility: Accessibility(
                                        identifier: "Disappear after send option",
                                        label: "Disappear after send option"
                                    ),
                                    onTap: {
                                        let updatedConfig: DisappearingMessagesConfiguration = {
                                            if (config.isEnabled == true && config.type == .disappearAfterSend) {
                                                return config
                                            }
                                            return currentSelection
                                                .with(
                                                    isEnabled: true,
                                                    durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.disappearAfterSend.seconds,
                                                    type: .disappearAfterSend
                                                )
                                        }()
                                        self?.shouldShowConfirmButton.send(updatedConfig != config)
                                        self?.currentSelection.send(updatedConfig)
                                    }
                                )
                            ].compactMap { $0 }
                        ),
                        (currentSelection.isEnabled == false ? nil :
                            SectionModel(
                                model: {
                                    guard Features.useNewDisappearingMessagesConfig else { return .timerLegacy }
                                    return currentSelection.type == .disappearAfterSend ?
                                        .timerDisappearAfterSend :
                                        .timerDisappearAfterRead
                                }(),
                                elements: DisappearingMessagesConfiguration
                                    .validDurationsSeconds({
                                        guard Features.useNewDisappearingMessagesConfig else { return .disappearAfterSend }
                                        return currentSelection.type ?? .disappearAfterSend
                                    }())
                                    .map { duration in
                                        let title: String = duration.formatted(format: .long)

                                        return SessionCell.Info(
                                            id: title,
                                            title: title,
                                            rightAccessory: .radio(
                                                isSelected: {
                                                    (self?.currentSelection.value.isEnabled == true) &&
                                                    (self?.currentSelection.value.durationSeconds == duration)
                                                }
                                            ),
                                            accessibility: Accessibility(
                                                identifier: "Time option",
                                                label: "Time option"
                                            ),
                                            onTap: {
                                                let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                    .with(
                                                        durationSeconds: duration
                                                    )
                                                self?.shouldShowConfirmButton.send(updatedConfig != config)
                                                self?.currentSelection.send(updatedConfig)
                                            }
                                        )
                                    }
                            )
                        )
                    ].compactMap { $0 }

                case (.legacyGroup, _), (.group, _), (_, true):
                    return [
                        (Features.useNewDisappearingMessagesConfig ? nil :
                            SectionModel(
                                model: .type,
                                elements: [
                                    SessionCell.Info(
                                        id: "off".localized(),
                                        title: "off".localized(),
                                        rightAccessory: .radio(
                                            isSelected: { (self?.currentSelection.value.isEnabled == false) }
                                        ),
                                        isEnabled: (
                                            isNoteToSelf ||
                                            currentUserIsClosedGroupMember == true
                                        ),
                                        accessibility: Accessibility(
                                            identifier: "Disable disappearing messages (Off option)",
                                            label: "Disable disappearing messages (Off option)"
                                        ),
                                        onTap: {
                                            let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                .with(
                                                    isEnabled: false,
                                                    durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.off.seconds
                                                )
                                            self?.shouldShowConfirmButton.send(updatedConfig != config)
                                            self?.currentSelection.send(updatedConfig)
                                        }
                                    ),
                                    SessionCell.Info(
                                        id: "deleteAfterLegacyDisappearingMessagesLegacy".localized(),
                                        title: "deleteAfterLegacyDisappearingMessagesLegacy".localized(),
                                        subtitle: "deleteAfterLegacyDisappearingMessagesOriginal".localized(),
                                        rightAccessory: .radio(
                                            isSelected: {
                                                (self?.currentSelection.value.isEnabled == true) &&
                                                !Features.useNewDisappearingMessagesConfig
                                            }
                                        ),
                                        isEnabled: (
                                            isNoteToSelf ||
                                            currentUserIsClosedGroupMember == true
                                        ),
                                        onTap: {
                                            let updatedConfig: DisappearingMessagesConfiguration = {
                                                if (config.isEnabled == true && config.type == .disappearAfterSend) {
                                                    return config
                                                }
                                                return currentSelection
                                                    .with(
                                                        isEnabled: true,
                                                        durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.legacy.seconds,
                                                        type: .disappearAfterSend // Default for closed group & note to self
                                                    )
                                            }()
                                            self?.shouldShowConfirmButton.send(updatedConfig != config)
                                            self?.currentSelection.send(updatedConfig)
                                        }
                                    ),
                                    SessionCell.Info(
                                        id: "disappearingMessagesDisappearAfterSend".localized(),
                                        title: "disappearingMessagesDisappearAfterSend".localized(),
                                        subtitle: "disappearingMessagesDisappearAfterSendDescription".localized(),
                                        rightAccessory: .radio(isSelected: { false }),
                                        styling: SessionCell.StyleInfo(tintColor: .disabled),
                                        isEnabled: false
                                    )
                                ]
                            )
                        ),
                        (!Features.useNewDisappearingMessagesConfig && currentSelection.isEnabled == false ? nil :
                            SectionModel(
                                model: {
                                    guard Features.useNewDisappearingMessagesConfig else {
                                        return (currentSelection.type == .disappearAfterSend ?
                                            .timerDisappearAfterSend :
                                            .timerDisappearAfterRead
                                        )
                                    }

                                    return (isNoteToSelf ? .noteToSelf : .group)
                                }(),
                                elements: [
                                    (!Features.useNewDisappearingMessagesConfig ? nil :
                                        SessionCell.Info(
                                            id: "off".localized(),
                                            title: "off".localized(),
                                            rightAccessory: .radio(
                                                isSelected: { (self?.currentSelection.value.isEnabled == false) }
                                            ),
                                            isEnabled: (
                                                isNoteToSelf ||
                                                currentUserIsClosedGroupAdmin == true
                                            ),
                                            accessibility: Accessibility(
                                                identifier: "Disable disappearing messages (Off option)",
                                                label: "Disable disappearing messages (Off option)"
                                            ),
                                            onTap: {
                                                let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                    .with(
                                                        isEnabled: false,
                                                        durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.off.seconds
                                                    )
                                                self?.shouldShowConfirmButton.send(updatedConfig != config)
                                                self?.currentSelection.send(updatedConfig)
                                            }
                                        )
                                    )
                                ]
                                .compactMap { $0 }
                                .appending(
                                    contentsOf: DisappearingMessagesConfiguration
                                        .validDurationsSeconds(.disappearAfterSend)
                                        .map { duration in
                                            let title: String = duration.formatted(format: .long)

                                            return SessionCell.Info(
                                                id: title,
                                                title: title,
                                                rightAccessory: .radio(
                                                    isSelected: {
                                                        (self?.currentSelection.value.isEnabled == true) &&
                                                        (self?.currentSelection.value.durationSeconds == duration)
                                                    }
                                                ),
                                                isEnabled: (
                                                    isNoteToSelf ||
                                                    (currentUserIsClosedGroupMember == true && !Features.useNewDisappearingMessagesConfig) ||
                                                    currentUserIsClosedGroupAdmin == true
                                                ),
                                                accessibility: Accessibility(
                                                    identifier: "Time option",
                                                    label: "Time option"
                                                ),
                                                onTap: {
                                                    // If the new disappearing messages config feature flag isn't
                                                    // enabled then the 'isEnabled' and 'type' values are set via
                                                    // the first section so pass `nil` values to keep the existing
                                                    // setting
                                                    let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                        .with(
                                                            isEnabled: (Features.useNewDisappearingMessagesConfig ?
                                                                true :
                                                                nil
                                                            ),
                                                            durationSeconds: duration,
                                                            type: (Features.useNewDisappearingMessagesConfig ?
                                                                .disappearAfterSend :
                                                               nil
                                                            )
                                                        )
                                                    self?.shouldShowConfirmButton.send(updatedConfig != config)
                                                    self?.currentSelection.send(updatedConfig)
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
        let updatedConfig: DisappearingMessagesConfiguration = self.currentSelection.value

        guard self.config != updatedConfig else { return }

        dependencies.storage.writeAsync(using: dependencies) { [threadId, threadVariant, dependencies] db in
            let userPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
            let currentTimestampMs: Int64 = SnodeAPI.currentOffsetTimestampMs()
            
            let interactionId = try updatedConfig
                .saved(db)
                .insertControlMessage(
                    db,
                    threadVariant: threadVariant,
                    authorId: userPublicKey,
                    timestampMs: currentTimestampMs,
                    serverHash: nil,
                    serverExpirationTimestamp: nil
                )

            let duration: UInt32? = {
                guard !Features.useNewDisappearingMessagesConfig else { return nil }
                return UInt32(floor(updatedConfig.isEnabled ? updatedConfig.durationSeconds : 0))
            }()
            
            let expirationTimerUpdateMessage: ExpirationTimerUpdate = ExpirationTimerUpdate(
                syncTarget: nil,
                duration: duration
            )
            .with(sentTimestamp: UInt64(currentTimestampMs))
            .with(updatedConfig)

            try MessageSender.send(
                db,
                message: expirationTimerUpdateMessage,
                interactionId: interactionId,
                threadId: threadId,
                threadVariant: threadVariant,
                using: dependencies
            )
        }
        
        // Contacts & legacy closed groups need to update the LibSession
        dependencies.storage.writeAsync(using: dependencies) { [threadId, threadVariant] db in
            switch threadVariant {
                case .contact:
                    try LibSession
                        .update(
                            db,
                            sessionId: threadId,
                            disappearingMessagesConfig: updatedConfig
                        )
                
                case .legacyGroup:
                    try LibSession
                        .update(
                            db,
                            groupPublicKey: threadId,
                            disappearingConfig: updatedConfig
                        )
                    
                default: break
            }
        }
    }
}
