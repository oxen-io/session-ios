// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class ConversationSettingsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    typealias TableItem = Section
    
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
        case messageTrimming
        case audioMessages
        case blockedContacts
        
        var title: String? {
            switch self {
                case .messageTrimming: return "conversationsMessageTrimming".localized()
                case .audioMessages: return "conversationsAudioMessages".localized()
                case .blockedContacts: return nil
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .blockedContacts: return .padding
                default: return .titleRoundedContent
            }
        }
    }
    
    // MARK: - Content
    
    private struct State: Equatable {
        let trimOpenGroupMessagesOlderThanSixMonths: Bool
        let shouldAutoPlayConsecutiveAudioMessages: Bool
    }
    
    let title: String = "sessionConversations".localized()
    
    lazy var observation: TargetObservation = ObservationBuilder
        .databaseObservation(self) { [weak self] db -> State in
            State(
                trimOpenGroupMessagesOlderThanSixMonths: db[.trimOpenGroupMessagesOlderThanSixMonths],
                shouldAutoPlayConsecutiveAudioMessages: db[.shouldAutoPlayConsecutiveAudioMessages]
            )
        }
        .mapWithPrevious { [dependencies] previous, current -> [SectionModel] in
            return [
                SectionModel(
                    model: .messageTrimming,
                    elements: [
                        SessionCell.Info(
                            id: .messageTrimming,
                            title: "conversationsMessageTrimmingTrimCommunities".localized(),
                            subtitle: "conversationsMessageTrimmingTrimCommunitiesDescription".localized(),
                            trailingAccessory: .toggle(
                                current.trimOpenGroupMessagesOlderThanSixMonths,
                                oldValue: previous?.trimOpenGroupMessagesOlderThanSixMonths,
                                accessibility: Accessibility(
                                    identifier: "Trim Communities - Switch"
                                )
                            ),
                            onTap: {
                                dependencies[singleton: .storage].write { db in
                                    db[.trimOpenGroupMessagesOlderThanSixMonths] = !db[.trimOpenGroupMessagesOlderThanSixMonths]
                                }
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .audioMessages,
                    elements: [
                        SessionCell.Info(
                            id: .audioMessages,
                            title: "conversationsAutoplayAudioMessage".localized(),
                            subtitle: "conversationsAutoplayAudioMessageDescription".localized(),
                            trailingAccessory: .toggle(
                                current.shouldAutoPlayConsecutiveAudioMessages,
                                oldValue: previous?.shouldAutoPlayConsecutiveAudioMessages,
                                accessibility: Accessibility(
                                    identifier: "Autoplay Audio Messages - Switch"
                                )
                            ),
                            onTap: {
                                dependencies[singleton: .storage].write { db in
                                    db[.shouldAutoPlayConsecutiveAudioMessages] = !db[.shouldAutoPlayConsecutiveAudioMessages]
                                }
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .blockedContacts,
                    elements: [
                        SessionCell.Info(
                            id: .blockedContacts,
                            title: "conversationsBlockedContacts".localized(),
                            styling: SessionCell.StyleInfo(
                                tintColor: .danger,
                                backgroundStyle: .noBackground
                            ),
                            onTap: { [weak self, dependencies] in
                                self?.transitionToScreen(
                                    SessionTableViewController(viewModel: BlockedContactsViewModel(using: dependencies))
                                )
                            }
                        )
                    ]
                )
            ]
        }
}
