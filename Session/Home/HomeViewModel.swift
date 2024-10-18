// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

public class HomeViewModel: NavigatableStateHolder {
    public let navigatableState: NavigatableState = NavigatableState()
    
    public typealias SectionModel = ArraySection<Section, SessionThreadViewModel>
    
    // MARK: - Section
    
    public enum Section: Differentiable {
        case messageRequests
        case threads
        case loadMore
    }
    
    // MARK: - Variables
    
    public static let pageSize: Int = (UIDevice.current.isIPad ? 20 : 15)
    
    public struct State: Equatable {
        let showViewedSeedBanner: Bool
        let hasHiddenMessageRequests: Bool
        let unreadMessageRequestThreadCount: Int
        let userProfile: Profile
    }
    
    public let dependencies: Dependencies
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        typealias InitialData = (
            showViewedSeedBanner: Bool,
            hasHiddenMessageRequests: Bool,
            profile: Profile
        )
        
        let initialData: InitialData? = Storage.shared.read { db -> InitialData in
            (
                !db[.hasViewedSeed],
                db[.hasHiddenMessageRequests],
                Profile.fetchOrCreateCurrentUser(db)
            )
        }
        
        self.dependencies = dependencies
        self.state = State(
            showViewedSeedBanner: (initialData?.showViewedSeedBanner ?? true),
            hasHiddenMessageRequests: (initialData?.hasHiddenMessageRequests ?? false),
            unreadMessageRequestThreadCount: 0,
            userProfile: (initialData?.profile ?? Profile.fetchOrCreateCurrentUser())
        )
        self.pagedDataObserver = nil
        
        // Note: Since this references self we need to finish initializing before setting it, we
        // also want to skip the initial query and trigger it async so that the push animation
        // doesn't stutter (it should load basically immediately but without this there is a
        // distinct stutter)
        let userPublicKey: String = self.state.userProfile.id
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        self.pagedDataObserver = PagedDatabaseObserver(
            pagedTable: SessionThread.self,
            pageSize: HomeViewModel.pageSize,
            idColumn: .id,
            observedChanges: [
                PagedData.ObservedChanges(
                    table: SessionThread.self,
                    columns: [
                        .id,
                        .shouldBeVisible,
                        .pinnedPriority,
                        .mutedUntilTimestamp,
                        .onlyNotifyForMentions,
                        .markedAsUnread
                    ]
                ),
                PagedData.ObservedChanges(
                    table: Interaction.self,
                    columns: [
                        .body,
                        .wasRead,
                        .state
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
                        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
                        let threadVariants: [SessionThread.Variant] = [.legacyGroup, .group]
                        let targetRole: GroupMember.Role = GroupMember.Role.standard
                        
                        return SQL("""
                            JOIN \(Profile.self) ON (
                                (   -- Contact profile change
                                    \(profile[.id]) = \(thread[.id]) AND
                                    \(SQL("\(thread[.variant]) = \(SessionThread.Variant.contact)"))
                                ) OR ( -- Closed group profile change
                                    \(SQL("\(thread[.variant]) IN \(threadVariants)")) AND (
                                        profile.id = (  -- Front profile
                                            SELECT MIN(\(groupMember[.profileId]))
                                            FROM \(GroupMember.self)
                                            JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                                            WHERE (
                                                \(groupMember[.groupId]) = \(thread[.id]) AND
                                                \(SQL("\(groupMember[.role]) = \(targetRole)")) AND
                                                \(groupMember[.profileId]) != \(userPublicKey)
                                            )
                                        ) OR
                                        profile.id = (  -- Back profile
                                            SELECT MAX(\(groupMember[.profileId]))
                                            FROM \(GroupMember.self)
                                            JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                                            WHERE (
                                                \(groupMember[.groupId]) = \(thread[.id]) AND
                                                \(SQL("\(groupMember[.role]) = \(targetRole)")) AND
                                                \(groupMember[.profileId]) != \(userPublicKey)
                                            )
                                        ) OR (  -- Fallback profile
                                            profile.id = \(userPublicKey) AND
                                            (
                                                SELECT COUNT(\(groupMember[.profileId]))
                                                FROM \(GroupMember.self)
                                                JOIN \(Profile.self) ON \(profile[.id]) = \(groupMember[.profileId])
                                                WHERE (
                                                    \(groupMember[.groupId]) = \(thread[.id]) AND
                                                    \(SQL("\(groupMember[.role]) = \(targetRole)")) AND
                                                    \(groupMember[.profileId]) != \(userPublicKey)
                                                )
                                            ) = 1
                                        )
                                    )
                                )
                            )
                        """)
                    }()
                ),
                PagedData.ObservedChanges(
                    table: ClosedGroup.self,
                    columns: [.name],
                    joinToPagedType: {
                        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
                        
                        return SQL("JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])")
                    }()
                ),
                PagedData.ObservedChanges(
                    table: OpenGroup.self,
                    columns: [.name, .imageData],
                    joinToPagedType: {
                        let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
                        
                        return SQL("JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(thread[.id])")
                    }()
                ),
                PagedData.ObservedChanges(
                    table: ThreadTypingIndicator.self,
                    columns: [.threadId],
                    joinToPagedType: {
                        let typingIndicator: TypedTableAlias<ThreadTypingIndicator> = TypedTableAlias()
                        
                        return SQL("JOIN \(ThreadTypingIndicator.self) ON \(typingIndicator[.threadId]) = \(thread[.id])")
                    }()
                )
            ],
            /// **Note:** This `optimisedJoinSQL` value includes the required minimum joins needed for the query but differs
            /// from the JOINs that are actually used for performance reasons as the basic logic can be simpler for where it's used
            joinSQL: SessionThreadViewModel.optimisedJoinSQL,
            filterSQL: SessionThreadViewModel.homeFilterSQL(userPublicKey: userPublicKey),
            groupSQL: SessionThreadViewModel.groupSQL,
            orderSQL: SessionThreadViewModel.homeOrderSQL,
            dataQuery: SessionThreadViewModel.baseQuery(
                userPublicKey: userPublicKey,
                groupSQL: SessionThreadViewModel.groupSQL,
                orderSQL: SessionThreadViewModel.homeOrderSQL
            ),
            onChangeUnsorted: { [weak self] updatedData, updatedPageInfo in
                PagedData.processAndTriggerUpdates(
                    updatedData: self?.process(data: updatedData, for: updatedPageInfo),
                    currentDataRetriever: { self?.threadData },
                    onDataChangeRetriever: { self?.onThreadChange },
                    onUnobservedDataChange: { updatedData in
                        self?.unobservedThreadDataChanges = updatedData
                    }
                )
                
                self?.hasReceivedInitialThreadData = true
            }
        )
        
        // Run the initial query on a background thread so we don't block the main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The `.pageBefore` will query from a `0` offset loading the first page
            self?.pagedDataObserver?.load(.pageBefore)
        }
    }
    
    // MARK: - State
    
    /// This value is the current state of the view
    public private(set) var state: State
    
    /// This is all the data the screen needs to populate itself, please see the following link for tips to help optimise
    /// performance https://github.com/groue/GRDB.swift#valueobservation-performance
    ///
    /// **Note:** This observation will be triggered twice immediately (and be de-duped by the `removeDuplicates`)
    /// this is due to the behaviour of `ValueConcurrentObserver.asyncStartObservation` which triggers it's own
    /// fetch (after the ones in `ValueConcurrentObserver.asyncStart`/`ValueConcurrentObserver.syncStart`)
    /// just in case the database has changed between the two reads - unfortunately it doesn't look like there is a way to prevent this
    public lazy var observableState = ValueObservation
        .trackingConstantRegion { db -> State in try HomeViewModel.retrieveState(db) }
        .removeDuplicates()
        .handleEvents(didFail: { SNLog("[HomeViewModel] Observation failed with error: \($0)") })
    
    private static func retrieveState(_ db: Database) throws -> State {
        let hasViewedSeed: Bool = db[.hasViewedSeed]
        let hasHiddenMessageRequests: Bool = db[.hasHiddenMessageRequests]
        let userProfile: Profile = Profile.fetchOrCreateCurrentUser(db)
        let unreadMessageRequestThreadCount: Int = try SessionThread
            .unreadMessageRequestsCountQuery(userPublicKey: userProfile.id)
            .fetchOne(db)
            .defaulting(to: 0)
        
        return State(
            showViewedSeedBanner: !hasViewedSeed,
            hasHiddenMessageRequests: hasHiddenMessageRequests,
            unreadMessageRequestThreadCount: unreadMessageRequestThreadCount,
            userProfile: userProfile
        )
    }
    
    public func updateState(_ updatedState: State) {
        let oldState: State = self.state
        self.state = updatedState
        
        // If the messageRequest content changed then we need to re-process the thread data (assuming
        // we've received the initial thread data)
        guard
            self.hasReceivedInitialThreadData,
            (
                oldState.hasHiddenMessageRequests != updatedState.hasHiddenMessageRequests ||
                oldState.unreadMessageRequestThreadCount != updatedState.unreadMessageRequestThreadCount
            ),
            let currentPageInfo: PagedData.PageInfo = self.pagedDataObserver?.pageInfo.wrappedValue
        else { return }
        
        /// **MUST** have the same logic as in the 'PagedDataObserver.onChangeUnsorted' above
        let currentData: [SectionModel] = (self.unobservedThreadDataChanges ?? self.threadData)
        let updatedThreadData: [SectionModel] = self.process(
            data: (currentData.first(where: { $0.model == .threads })?.elements ?? []),
            for: currentPageInfo
        )
        
        PagedData.processAndTriggerUpdates(
            updatedData: updatedThreadData,
            currentDataRetriever: { [weak self] in (self?.unobservedThreadDataChanges ?? self?.threadData) },
            onDataChangeRetriever: { [weak self] in self?.onThreadChange },
            onUnobservedDataChange: { [weak self] updatedData in
                self?.unobservedThreadDataChanges = updatedData
            }
        )
    }
    
    // MARK: - Thread Data
    
    private var hasReceivedInitialThreadData: Bool = false
    public private(set) var unobservedThreadDataChanges: [SectionModel]?
    public private(set) var threadData: [SectionModel] = []
    public private(set) var pagedDataObserver: PagedDatabaseObserver<SessionThread, SessionThreadViewModel>?
    
    public var onThreadChange: (([SectionModel], StagedChangeset<[SectionModel]>) -> ())? {
        didSet {
            guard onThreadChange != nil else { return }
            
            // When starting to observe interaction changes we want to trigger a UI update just in case the
            // data was changed while we weren't observing
            if let changes: [SectionModel] = self.unobservedThreadDataChanges {
                PagedData.processAndTriggerUpdates(
                    updatedData: changes,
                    currentDataRetriever: { [weak self] in self?.threadData },
                    onDataChangeRetriever: { [weak self] in self?.onThreadChange },
                    onUnobservedDataChange: { [weak self] updatedData in
                        self?.unobservedThreadDataChanges = updatedData
                    }
                )
                self.unobservedThreadDataChanges = nil
            }
        }
    }
    
    private func process(data: [SessionThreadViewModel], for pageInfo: PagedData.PageInfo) -> [SectionModel] {
        let finalUnreadMessageRequestCount: Int = (self.state.hasHiddenMessageRequests ?
            0 :
            self.state.unreadMessageRequestThreadCount
        )
        let groupedOldData: [String: [SessionThreadViewModel]] = (self.threadData
            .first(where: { $0.model == .threads })?
            .elements)
            .defaulting(to: [])
            .grouped(by: \.threadId)
        
        return [
            // If there are no unread message requests then hide the message request banner
            (finalUnreadMessageRequestCount == 0 ?
                [] :
                [SectionModel(
                    section: .messageRequests,
                    elements: [
                        SessionThreadViewModel(
                            threadId: SessionThreadViewModel.messageRequestsSectionId,
                            unreadCount: UInt(finalUnreadMessageRequestCount)
                        )
                    ]
                )]
            ),
            [
                SectionModel(
                    section: .threads,
                    elements: data
                        .filter { threadViewModel in
                            threadViewModel.id != SessionThreadViewModel.invalidId &&
                            threadViewModel.id != SessionThreadViewModel.messageRequestsSectionId
                        }
                        .sorted { lhs, rhs -> Bool in
                            guard lhs.threadPinnedPriority == rhs.threadPinnedPriority else {
                                return lhs.threadPinnedPriority > rhs.threadPinnedPriority
                            }
                            
                            return lhs.lastInteractionDate > rhs.lastInteractionDate
                        }
                        .map { viewModel -> SessionThreadViewModel in
                            viewModel.populatingCurrentUserBlindedKeys(
                                currentUserBlinded15PublicKeyForThisThread: groupedOldData[viewModel.threadId]?
                                    .first?
                                    .currentUserBlinded15PublicKey,
                                currentUserBlinded25PublicKeyForThisThread: groupedOldData[viewModel.threadId]?
                                    .first?
                                    .currentUserBlinded25PublicKey
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
    
    public func updateThreadData(_ updatedData: [SectionModel]) {
        self.threadData = updatedData
    }
}
