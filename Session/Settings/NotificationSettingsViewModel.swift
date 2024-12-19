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
                case .strategy: return "notificationsStrategy".localized()
                case .style: return "notificationsStyle".localized()
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
    
    let title: String = "sessionNotifications".localized()
    
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
                            title: "useFastMode".localized(),
                            subtitle: "notificationsFastModeDescriptionIos".localized(),
                            trailingAccessory: .toggle(
                                current.isUsingFullAPNs,
                                oldValue: previous?.isUsingFullAPNs,
                                accessibility: Accessibility(
                                    identifier: "Use Fast Mode - Switch"
                                )
                            ),
                            styling: SessionCell.StyleInfo(
                                allowedSeparators: [.top],
                                customPadding: SessionCell.Padding(bottom: Values.verySmallSpacing)
                            ),
                            // stringlint:ignore_contents
                            onTap: { [weak self] in
                                dependencies[defaults: .standard, key: .isUsingFullAPNs] = !dependencies[defaults: .standard, key: .isUsingFullAPNs]

                                // Force sync the push tokens on change
                                SyncPushTokensJob.run(uploadOnlyIfStale: false, using: dependencies)
                                self?.forceRefresh(type: .postDatabaseQuery)
                            }
                        ),
                        SessionCell.Info(
                            id: .strategyDeviceSettings,
                            title: SessionCell.TextInfo(
                                "notificationsGoToDevice".localized(),
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
                            title: "notificationsSound".localized(),
                            trailingAccessory: .dropDown { current.notificationSound.displayName },
                            onTap: { [weak self] in
                                self?.transitionToScreen(
                                    SessionTableViewController(
                                        viewModel: NotificationSoundViewModel(using: dependencies)
                                    )
                                )
                            }
                        ),
                        SessionCell.Info(
                            id: .styleSoundWhenAppIsOpen,
                            title: "notificationsSoundDescription".localized(),
                            trailingAccessory: .toggle(
                                current.playNotificationSoundInForeground,
                                oldValue: previous?.playNotificationSoundInForeground,
                                accessibility: Accessibility(
                                    identifier: "Sound when App is open - Switch"
                                )
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
                            title: "notificationsContent".localized(),
                            subtitle: "notificationsContentDescription".localized(),
                            trailingAccessory: .dropDown { current.previewType.name },
                            onTap: { [weak self] in
                                self?.transitionToScreen(
                                    SessionTableViewController(
                                        viewModel: NotificationContentViewModel(using: dependencies)
                                    )
                                )
                            }
                        )
                    ]
                )
            ]
        }
}
