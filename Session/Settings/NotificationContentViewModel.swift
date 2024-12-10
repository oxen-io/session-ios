// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class NotificationContentViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    typealias TableItem = Preferences.NotificationPreviewType
    
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Section
    
    public enum Section: SessionTableSection {
        case content
    }
    
    // MARK: - Content
    
    let title: String = "notificationsContent".localized()
    
    lazy var observation: TargetObservation = ObservationBuilder
        .databaseObservation(self) { db -> Preferences.NotificationPreviewType in
            db[.preferencesNotificationPreviewType].defaulting(to: .defaultPreviewType)
        }
        .map { [weak self, dependencies] currentSelection -> [SectionModel] in
            return [
                SectionModel(
                    model: .content,
                    elements: Preferences.NotificationPreviewType.allCases
                        .map { previewType in
                            SessionCell.Info(
                                id: previewType,
                                title: previewType.name,
                                trailingAccessory: .radio(
                                    isSelected: (currentSelection == previewType)
                                ),
                                onTap: {
                                    dependencies[singleton: .storage].writeAsync { db in
                                        db[.preferencesNotificationPreviewType] = previewType
                                    }
                                    
                                    self?.dismissScreen()
                                }
                            )
                        }
                )
            ]
        }
}
