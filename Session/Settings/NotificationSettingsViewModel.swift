// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class NotificationSettingsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Config
    
    public enum Section: SessionTableSection {
        case strategy
        case style
        case content
        
        var title: String? {
            switch self {
                case .strategy: return "NOTIFICATIONS_SECTION_STRATEGY".localized()
                case .style: return "NOTIFICATIONS_SECTION_STYLE".localized()
                case .content: return nil
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .content: return .padding
                default: return .titleRoundedContent
            }
        }
    }
    
    public enum TableItem: Differentiable {
        case strategyUseFastMode
        case strategyDeviceSettings
        case styleSound
        case styleSoundWhenAppIsOpen
        case content
    }
    
    // MARK: - Content
    
    private struct State: Equatable {
        let isUsingFullAPNs: Bool
        let notificationSound: Preferences.Sound
        let playNotificationSoundInForeground: Bool
        let previewType: Preferences.NotificationPreviewType
    }
    
    let title: String = "NOTIFICATIONS_TITLE".localized()
    
    lazy var observation: TargetObservation = ObservationBuilder
        .databaseObservation(self) { db -> State in
            State(
                isUsingFullAPNs: false, // Set later the the data flow
                notificationSound: db[.defaultNotificationSound]
                    .defaulting(to: Preferences.Sound.defaultNotificationSound),
                playNotificationSoundInForeground: db[.playNotificationSoundInForeground],
                previewType: db[.preferencesNotificationPreviewType]
                    .defaulting(to: Preferences.NotificationPreviewType.defaultPreviewType)
            )
        }
        .map { [dependencies] dbState -> State in
            State(
                isUsingFullAPNs: dependencies[defaults: .standard, key: .isUsingFullAPNs],
                notificationSound: dbState.notificationSound,
                playNotificationSoundInForeground: dbState.playNotificationSoundInForeground,
                previewType: dbState.previewType
            )
        }
        .mapWithPrevious { [dependencies] previous, current -> [SectionModel] in
            return [
                SectionModel(
                    model: .strategy,
                    elements: [
                        SessionCell.Info(
                            id: .strategyUseFastMode,
                            title: "NOTIFICATIONS_STRATEGY_FAST_MODE_TITLE".localized(),
                            subtitle: "NOTIFICATIONS_STRATEGY_FAST_MODE_DESCRIPTION".localized(),
                            trailingAccessory: .toggle(
                                current.isUsingFullAPNs,
                                oldValue: previous?.isUsingFullAPNs
                            ),
                            styling: SessionCell.StyleInfo(
                                allowedSeparators: [.top],
                                customPadding: SessionCell.Padding(bottom: Values.verySmallSpacing)
                            ),
                            onTap: { [weak self] in
                                dependencies[defaults: .standard, key: .isUsingFullAPNs] = !dependencies[defaults: .standard, key: .isUsingFullAPNs]

                                // Force sync the push tokens on change
                                SyncPushTokensJob.run(uploadOnlyIfStale: false)
                                self?.forceRefresh(type: .postDatabaseQuery)
                            }
                        ),
                        SessionCell.Info(
                            id: .strategyDeviceSettings,
                            title: SessionCell.TextInfo(
                                "NOTIFICATIONS_STRATEGY_FAST_MODE_ACTION".localized(),
                                font: .subtitleBold
                            ),
                            styling: SessionCell.StyleInfo(
                                tintColor: .settings_tertiaryAction,
                                allowedSeparators: [.bottom],
                                customPadding: SessionCell.Padding(top: Values.verySmallSpacing)
                            ),
                            onTap: { UIApplication.shared.openSystemSettings() }
                        )
                    ]
                ),
                SectionModel(
                    model: .style,
                    elements: [
                        SessionCell.Info(
                            id: .styleSound,
                            title: "NOTIFICATIONS_STYLE_SOUND_TITLE".localized(),
                            trailingAccessory: .dropDown { current.notificationSound.displayName },
                            onTap: { [weak self] in
                                self?.transitionToScreen(
                                    SessionTableViewController(viewModel: NotificationSoundViewModel())
                                )
                            }
                        ),
                        SessionCell.Info(
                            id: .styleSoundWhenAppIsOpen,
                            title: "NOTIFICATIONS_STYLE_SOUND_WHEN_OPEN_TITLE".localized(),
                            trailingAccessory: .toggle(
                                current.playNotificationSoundInForeground,
                                oldValue: previous?.playNotificationSoundInForeground
                            ),
                            onTap: {
                                dependencies[singleton: .storage].write { db in
                                    db[.playNotificationSoundInForeground] = !db[.playNotificationSoundInForeground]
                                }
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .content,
                    elements: [
                        SessionCell.Info(
                            id: .content,
                            title: "NOTIFICATIONS_STYLE_CONTENT_TITLE".localized(),
                            subtitle: "NOTIFICATIONS_STYLE_CONTENT_DESCRIPTION".localized(),
                            trailingAccessory: .dropDown { current.previewType.name },
                            onTap: { [weak self] in
                                self?.transitionToScreen(
                                    SessionTableViewController(viewModel: NotificationContentViewModel())
                                )
                            }
                        )
                    ]
                )
            ]
        }
}
