// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionUtilitiesKit
import SignalUtilitiesKit
import SessionMessagingKit

class MessageRequestsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource, PagedObservationSource {
    typealias TableItem = SessionThreadViewModel
    typealias PagedTable = SessionThread
    typealias PagedDataModel = SessionThreadViewModel
    
    // MARK: - Variables
    
    public static let pageSize: Int = (UIDevice.current.isIPad ? 20 : 15)
    public let dependencies: Dependencies
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, SessionThreadViewModel> = ObservableTableSourceState()
    public let navigatableState: NavigatableState = NavigatableState()
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.pagedDataObserver = nil
        
        // Note: Since this references self we need to finish initializing before setting it, we
        // also want to skip the initial query and trigger it async so that the push animation
        // doesn't stutter (it should load basically immediately but without this there is a
        // distinct stutter)
        let userSessionId: SessionId = getUserSessionId(using: dependencies)
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        
        self.pagedDataObserver = PagedDatabaseObserver(
            pagedTable: SessionThread.self,
            pageSize: MessageRequestsViewModel.pageSize,
            idColumn: .id,
            observedChanges: [
                PagedData.ObservedChanges(
                    table: SessionThread.self,
                    columns: [
                        .id,
                        .shouldBeVisible
                    ]
                ),
                PagedData.ObservedChanges(
                    table: Interaction.self,
                    columns: [
                        .body,
                        .wasRead
                    ],
                    joinToPagedType: {
                        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                        
                        return SQL("JOIN \(Interaction.self) ON \(interaction[.threadId]) = \(thread[.id])")
                    }()
                ),
                PagedData.ObservedChanges(
                    table: Contact.self,
                    columns: [.isBlocked],
                    joinToPagedType: {
                        let contact: TypedTableAlias<Contact> = TypedTableAlias()
                        
                        return SQL("JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])")
                    }()
                ),
                PagedData.ObservedChanges(
                    table: Profile.self,
                    columns: [.name, .nickname, .profilePictureFileName],
                    joinToPagedType: {
                        let profile: TypedTableAlias<Profile> = TypedTableAlias()
                        
                        return SQL("JOIN \(Profile.self) ON \(profile[.id]) = \(thread[.id])")
                    }()
                ),
                PagedData.ObservedChanges(
                    table: RecipientState.self,
                    columns: [.state],
                    joinToPagedType: {
                        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                        let recipientState: TypedTableAlias<RecipientState> = TypedTableAlias()
                        
                        return """
                            JOIN \(Interaction.self) ON \(interaction[.threadId]) = \(thread[.id])
                            JOIN \(RecipientState.self) ON \(recipientState[.interactionId]) = \(interaction[.id])
                        """
                    }()
                )
            ],
            /// **Note:** This `optimisedJoinSQL` value includes the required minimum joins needed for the query but differs
            /// from the JOINs that are actually used for performance reasons as the basic logic can be simpler for where it's used
            joinSQL: SessionThreadViewModel.optimisedJoinSQL,
            filterSQL: SessionThreadViewModel.messageRequestsFilterSQL(userSessionId: userSessionId),
            groupSQL: SessionThreadViewModel.groupSQL,
            orderSQL: SessionThreadViewModel.messageRequetsOrderSQL,
            dataQuery: SessionThreadViewModel.baseQuery(
                userSessionId: userSessionId,
                groupSQL: SessionThreadViewModel.groupSQL,
                orderSQL: SessionThreadViewModel.messageRequetsOrderSQL
            ),
            onChangeUnsorted: { [weak self] updatedData, updatedPageInfo in
                PagedData.processAndTriggerUpdates(
                    updatedData: self?.process(data: updatedData, for: updatedPageInfo),
                    currentDataRetriever: { self?.tableData },
                    valueSubject: self?.pendingTableDataSubject
                )
            }
        )
        
        // Run the initial query on a background thread so we don't block the push transition
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The `.pageBefore` will query from a `0` offset loading the first page
            self?.pagedDataObserver?.load(.pageBefore)
        }
    }
    
    // MARK: - Section
    
    public enum Section: SessionTableSection {
        case threads
        case loadMore
        
        var style: SessionTableSectionStyle {
            switch self {
                case .threads: return .none
                case .loadMore: return .loadMore
            }
        }
    }
    
    // MARK: - Content
    
    public let title: String = "MESSAGE_REQUESTS_TITLE".localized()
    public let initialLoadMessage: String? = "LOADING_CONVERSATIONS".localized()
    public let emptyStateTextPublisher: AnyPublisher<String?, Never> = Just("MESSAGE_REQUESTS_EMPTY_TEXT".localized())
        .eraseToAnyPublisher()
    public let cellType: SessionTableViewCellType = .fullConversation
    public private(set) var pagedDataObserver: PagedDatabaseObserver<SessionThread, SessionThreadViewModel>?
    
    private func process(data: [SessionThreadViewModel], for pageInfo: PagedData.PageInfo) -> [SectionModel] {
        let groupedOldData: [String: [SessionCell.Info<SessionThreadViewModel>]] = (self.tableData
            .first(where: { $0.model == .threads })?
            .elements)
            .defaulting(to: [])
            .grouped(by: \.id.threadId)
        
        return [
            [
                SectionModel(
                    section: .threads,
                    elements: data
                        .sorted { lhs, rhs -> Bool in lhs.lastInteractionDate > rhs.lastInteractionDate }
                        .map { [dependencies] viewModel -> SessionCell.Info<SessionThreadViewModel> in
                            SessionCell.Info(
                                id: viewModel.populatingCurrentUserBlindedIds(
                                    currentUserBlinded15SessionIdForThisThread: groupedOldData[viewModel.threadId]?
                                        .first?
                                        .id
                                        .currentUserBlinded15SessionId,
                                    currentUserBlinded25SessionIdForThisThread: groupedOldData[viewModel.threadId]?
                                        .first?
                                        .id
                                        .currentUserBlinded25SessionId
                                ),
                                accessibility: Accessibility(
                                    identifier: "Message request"
                                ),
                                onTap: { [weak self] in
                                    let viewController: ConversationVC = ConversationVC(
                                        threadId: viewModel.threadId,
                                        threadVariant: viewModel.threadVariant,
                                        using: dependencies
                                    )
                                    self?.transitionToScreen(viewController, transitionType: .push)
                                }
                            )
                        }
                )
            ],
            (!data.isEmpty && (pageInfo.pageOffset + pageInfo.currentCount) < pageInfo.totalCount ?
                [SectionModel(section: .loadMore)] :
                []
            )
        ].flatMap { $0 }
    }
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = observableState
        .pendingTableDataSubject
        .map { [dependencies] (currentThreadData: [SectionModel], _: StagedChangeset<[SectionModel]>) in
            let threadInfo: [(id: String, variant: SessionThread.Variant)] = (currentThreadData
                .first(where: { $0.model == .threads })?
                .elements
                .map { ($0.id.id, $0.id.threadVariant) })
                .defaulting(to: [])
            
            return SessionButton.Info(
                style: .destructive,
                title: "MESSAGE_REQUESTS_CLEAR_ALL".localized(),
                isEnabled: !threadInfo.isEmpty,
                accessibility: Accessibility(
                    identifier: "Clear all"
                ),
                onTap: { [weak self] in
                    let modal: ConfirmationModal = ConfirmationModal(
                        info: ConfirmationModal.Info(
                            title: "MESSAGE_REQUESTS_CLEAR_ALL_CONFIRMATION_TITLE".localized(),
                            accessibility: Accessibility(
                                identifier: "Clear all"
                            ),
                            confirmTitle: "MESSAGE_REQUESTS_CLEAR_ALL_CONFIRMATION_ACTON".localized(),
                            confirmAccessibility: Accessibility(
                                identifier: "Clear"
                            ),
                            confirmStyle: .danger,
                            cancelStyle: .alert_text,
                            onConfirm: { _ in
                                // Clear the requests
                                dependencies[singleton: .storage].write { db in
                                    // Remove the one-to-one requests
                                    try SessionThread.deleteOrLeave(
                                        db,
                                        threadIds: threadInfo
                                            .filter { _, variant in variant == .contact }
                                            .map { id, _ in id },
                                        threadVariant: .contact,
                                        groupLeaveType: .silent,
                                        calledFromConfigHandling: false,
                                        using: dependencies
                                    )
                                    
                                    // Remove the group invites
                                    try SessionThread.deleteOrLeave(
                                        db,
                                        threadIds: threadInfo
                                            .filter { _, variant in variant == .legacyGroup || variant == .group }
                                            .map { id, _ in id },
                                        threadVariant: .group,
                                        groupLeaveType: .silent,
                                        calledFromConfigHandling: false,
                                        using: dependencies
                                    )
                                }
                            }
                        )
                    )

                    self?.transitionToScreen(modal, transitionType: .present)
                }
            )
        }
        .eraseToAnyPublisher()
    
    // MARK: - Functions
    
    func canEditRow(at indexPath: IndexPath) -> Bool {
        let section: SectionModel = tableData[indexPath.section]
        
        return (section.model == .threads)
    }
    
    func trailingSwipeActionsConfiguration(forRowAt indexPath: IndexPath, in tableView: UITableView, of viewController: UIViewController) -> UISwipeActionsConfiguration? {
        let section: SectionModel = tableData[indexPath.section]
        
        switch section.model {
            case .threads:
                let threadViewModel: SessionThreadViewModel = section.elements[indexPath.row].id
                
                return UIContextualAction.configuration(
                    for: UIContextualAction.generateSwipeActions(
                        [.block, .delete],
                        for: .trailing,
                        indexPath: indexPath,
                        tableView: tableView,
                        threadViewModel: threadViewModel,
                        viewController: viewController
                    )
                )
                
            default: return nil
        }
    }
}
