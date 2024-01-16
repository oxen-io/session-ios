// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit
import SessionUIKit

public class ConversationViewModel: OWSAudioPlayerDelegate {
    public typealias SectionModel = ArraySection<Section, MessageViewModel>
    
    // MARK: - FocusBehaviour
    
    public enum FocusBehaviour {
        case none
        case highlight
    }
    
    // MARK: - ContentSwapLocation
    
    public enum ContentSwapLocation {
        case none
        case earlier
        case later
    }
    
    // MARK: - Action
    
    public enum Action {
        case none
        case compose
        case audioCall
        case videoCall
    }
    
    // MARK: - Section
    
    public enum Section: Differentiable, Equatable, Comparable, Hashable {
        case loadOlder
        case messages
        case loadNewer
    }
    
    // MARK: - Variables
    
    public static let pageSize: Int = 50
    
    private var threadId: String
    public let initialThreadVariant: SessionThread.Variant
    public var sentMessageBeforeUpdate: Bool = false
    public var lastSearchedText: String?
    public let focusedInteractionInfo: Interaction.TimestampInfo? // Note: This is used for global search
    public let focusBehaviour: FocusBehaviour
    private let initialUnreadInteractionId: Int64?
    private let markAsReadTrigger: PassthroughSubject<(SessionThreadViewModel.ReadTarget, Int64?), Never> = PassthroughSubject()
    private var markAsReadPublisher: AnyPublisher<Void, Never>?
    public let dependencies: Dependencies
    
    public lazy var blockedBannerMessage: String = {
        let threadData: SessionThreadViewModel = self._threadData.wrappedValue
        
        switch threadData.threadVariant {
            case .contact:
                let name: String = Profile.displayName(
                    id: threadData.threadId,
                    threadVariant: threadData.threadVariant
                )
                
                return "\(name) is blocked. Unblock them?"
                
            default: return "Thread is blocked. Unblock it?"
        }
    }()
    
    // MARK: - Initialization
    
    init(
        threadId: String,
        threadVariant: SessionThread.Variant,
        focusedInteractionInfo: Interaction.TimestampInfo?,
        using dependencies: Dependencies
    ) {
        typealias InitialData = (
            userSessionId: SessionId,
            initialUnreadInteractionInfo: Interaction.TimestampInfo?,
            threadIsBlocked: Bool,
            threadIsMessageRequest: Bool,
            currentUserIsClosedGroupMember: Bool?,
            openGroupPermissions: OpenGroup.Permissions?,
            blinded15SessionId: SessionId?,
            blinded25SessionId: SessionId?
        )
        
        let initialData: InitialData? = dependencies[singleton: .storage].read { db -> InitialData in
            let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
            let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
            let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
            
            // If we have a specified 'focusedInteractionInfo' then use that, otherwise retrieve the oldest
            // unread interaction and start focused around that one
            let initialUnreadInteractionInfo: Interaction.TimestampInfo? = try Interaction
                .select(.id, .timestampMs)
                .filter(interaction[.wasRead] == false)
                .filter(interaction[.threadId] == threadId)
                .order(interaction[.timestampMs].asc)
                .asRequest(of: Interaction.TimestampInfo.self)
                .fetchOne(db)
            let threadIsBlocked: Bool = (threadVariant != .contact ? false :
                try Contact
                    .filter(id: threadId)
                    .select(.isBlocked)
                    .asRequest(of: Bool.self)
                    .fetchOne(db)
                    .defaulting(to: false)
            )
            let threadIsMessageRequest: Bool = try {
                switch threadVariant {
                    case .contact:
                        let isApproved: Bool = try Contact
                            .filter(id: threadId)
                            .select(.isApproved)
                            .asRequest(of: Bool.self)
                            .fetchOne(db)
                            .defaulting(to: true)
                        
                        return !isApproved
                        
                    case .group:
                        let isInvite: Bool = try ClosedGroup
                            .filter(id: threadId)
                            .select(.invited)
                            .asRequest(of: Bool.self)
                            .fetchOne(db)
                            .defaulting(to: true)
                        
                        return !isInvite
                        
                    default: return false
                }
            }()
            let currentUserIsClosedGroupMember: Bool? = (![.legacyGroup, .group].contains(threadVariant) ? nil :
                GroupMember
                    .filter(groupMember[.groupId] == threadId)
                    .filter(groupMember[.profileId] == userSessionId.hexString)
                    .filter(groupMember[.role] == GroupMember.Role.standard)
                    .isNotEmpty(db)
            )
            let openGroupPermissions: OpenGroup.Permissions? = (threadVariant != .community ? nil :
                try OpenGroup
                    .filter(id: threadId)
                    .select(.permissions)
                    .asRequest(of: OpenGroup.Permissions.self)
                    .fetchOne(db)
            )
            let blinded15SessionId: SessionId? = SessionThread.getCurrentUserBlindedSessionId(
                db,
                threadId: threadId,
                threadVariant: threadVariant,
                blindingPrefix: .blinded15
            )
            let blinded25SessionId: SessionId? = SessionThread.getCurrentUserBlindedSessionId(
                db,
                threadId: threadId,
                threadVariant: threadVariant,
                blindingPrefix: .blinded25
            )
            
            return (
                userSessionId,
                initialUnreadInteractionInfo,
                threadIsBlocked,
                threadIsMessageRequest,
                currentUserIsClosedGroupMember,
                openGroupPermissions,
                blinded15SessionId,
                blinded25SessionId
            )
        }
        
        self.threadId = threadId
        self.initialThreadVariant = threadVariant
        self.focusedInteractionInfo = (focusedInteractionInfo ?? initialData?.initialUnreadInteractionInfo)
        self.focusBehaviour = (focusedInteractionInfo == nil ? .none : .highlight)
        self.initialUnreadInteractionId = initialData?.initialUnreadInteractionInfo?.id
        self._threadData = Atomic(
            SessionThreadViewModel(
                threadId: threadId,
                threadVariant: threadVariant,
                threadIsNoteToSelf: (initialData?.userSessionId.hexString == threadId),
                threadIsMessageRequest: initialData?.threadIsMessageRequest,
                threadIsBlocked: initialData?.threadIsBlocked,
                currentUserIsClosedGroupMember: initialData?.currentUserIsClosedGroupMember,
                openGroupPermissions: initialData?.openGroupPermissions
            ).populatingCurrentUserBlindedIds(
                currentUserBlinded15SessionIdForThisThread: initialData?.blinded15SessionId?.hexString,
                currentUserBlinded25SessionIdForThisThread: initialData?.blinded25SessionId?.hexString
            )
        )
        self.pagedDataObserver = nil
        self.dependencies = dependencies
        
        // Note: Since this references self we need to finish initializing before setting it, we
        // also want to skip the initial query and trigger it async so that the push animation
        // doesn't stutter (it should load basically immediately but without this there is a
        // distinct stutter)
        self.pagedDataObserver = self.setupPagedObserver(
            for: threadId,
            userSessionId: (initialData?.userSessionId ?? getUserSessionId()),
            blinded15SessionId: initialData?.blinded15SessionId,
            blinded25SessionId: initialData?.blinded25SessionId,
            using: dependencies
        )
        
        // Run the initial query on a background thread so we don't block the push transition
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // If we don't have a `initialFocusedInfo` then default to `.pageBefore` (it'll query
            // from a `0` offset)
            switch (focusedInteractionInfo ?? initialData?.initialUnreadInteractionInfo) {
                case .some(let info): self?.pagedDataObserver?.load(.initialPageAround(id: info.id))
                case .none: self?.pagedDataObserver?.load(.pageBefore)
            }
        }
    }
    
    // MARK: - Thread Data
    
    private var _threadData: Atomic<SessionThreadViewModel>
    
    /// This value is the current state of the view
    public var threadData: SessionThreadViewModel { _threadData.wrappedValue }
    
    /// This is all the data the screen needs to populate itself, please see the following link for tips to help optimise
    /// performance https://github.com/groue/GRDB.swift#valueobservation-performance
    ///
    /// **Note:** The 'trackingConstantRegion' is optimised in such a way that the request needs to be static
    /// otherwise there may be situations where it doesn't get updates, this means we can't have conditional queries
    ///
    /// **Note:** This observation will be triggered twice immediately (and be de-duped by the `removeDuplicates`)
    /// this is due to the behaviour of `ValueConcurrentObserver.asyncStartObservation` which triggers it's own
    /// fetch (after the ones in `ValueConcurrentObserver.asyncStart`/`ValueConcurrentObserver.syncStart`)
    /// just in case the database has changed between the two reads - unfortunately it doesn't look like there is a way to prevent this
    public typealias ThreadObservation = ValueObservation<ValueReducers.Trace<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<SessionThreadViewModel?>>>>
    public lazy var observableThreadData: ThreadObservation = setupObservableThreadData(for: self.threadId)
    
    private func setupObservableThreadData(for threadId: String) -> ThreadObservation {
        return ValueObservation
            .trackingConstantRegion { [weak self, dependencies] db -> SessionThreadViewModel? in
                let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                let recentReactionEmoji: [String] = try Emoji.getRecent(db, withDefaultEmoji: true)
                let threadViewModel: SessionThreadViewModel? = try SessionThreadViewModel
                    .conversationQuery(threadId: threadId, userSessionId: userSessionId)
                    .fetchOne(db)
                
                return threadViewModel
                    .map { $0.with(recentReactionEmoji: recentReactionEmoji) }
                    .map { viewModel -> SessionThreadViewModel in
                        viewModel.populatingCurrentUserBlindedIds(
                            db,
                            currentUserBlinded15SessionIdForThisThread: self?.threadData.currentUserBlinded15SessionId,
                            currentUserBlinded25SessionIdForThisThread: self?.threadData.currentUserBlinded25SessionId
                        )
                    }
            }
            .removeDuplicates()
            .handleEvents(didFail: { SNLog("[ConversationViewModel] Observation failed with error: \($0)") })
    }

    public func updateThreadData(_ updatedData: SessionThreadViewModel) {
        self._threadData.mutate { $0 = updatedData }
    }
    
    // MARK: - Interaction Data
    
    private var lastInteractionIdMarkedAsRead: Int64? = nil
    private var lastInteractionTimestampMsMarkedAsRead: Int64 = 0
    public private(set) var unobservedInteractionDataChanges: ([SectionModel], StagedChangeset<[SectionModel]>)?
    public private(set) var interactionData: [SectionModel] = []
    public private(set) var reactionExpandedInteractionIds: Set<Int64> = []
    public private(set) var pagedDataObserver: PagedDatabaseObserver<Interaction, MessageViewModel>?
    
    public var onInteractionChange: (([SectionModel], StagedChangeset<[SectionModel]>) -> ())? {
        didSet {
            // When starting to observe interaction changes we want to trigger a UI update just in case the
            // data was changed while we weren't observing
            if let changes: ([SectionModel], StagedChangeset<[SectionModel]>) = self.unobservedInteractionDataChanges {
                let performChange: (([SectionModel], StagedChangeset<[SectionModel]>) -> ())? = onInteractionChange
                
                switch Thread.isMainThread {
                    case true: performChange?(changes.0, changes.1)
                    case false: DispatchQueue.main.async { performChange?(changes.0, changes.1) }
                }
                
                self.unobservedInteractionDataChanges = nil
            }
        }
    }
    
    private func setupPagedObserver(
        for threadId: String,
        userSessionId: SessionId,
        blinded15SessionId: SessionId?,
        blinded25SessionId: SessionId?,
        using dependencies: Dependencies
    ) -> PagedDatabaseObserver<Interaction, MessageViewModel> {
        return PagedDatabaseObserver(
            pagedTable: Interaction.self,
            pageSize: ConversationViewModel.pageSize,
            idColumn: .id,
            observedChanges: [
                PagedData.ObservedChanges(
                    table: Interaction.self,
                    columns: Interaction.Columns
                        .allCases
                        .filter { $0 != .wasRead }
                ),
                PagedData.ObservedChanges(
                    table: Attachment.self,
                    columns: [.state],
                    joinToPagedType: {
                        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                        let linkPreview: TypedTableAlias<LinkPreview> = TypedTableAlias()
                        let linkPreviewAttachment: TypedTableAlias<Attachment> = TypedTableAlias()
                        
                        return SQL("""
                               LEFT JOIN \(LinkPreview.self) ON (
                                   \(linkPreview[.url]) = \(interaction[.linkPreviewUrl]) AND
                                   \(Interaction.linkPreviewFilterLiteral())
                               )
                               LEFT JOIN \(linkPreviewAttachment) ON \(linkPreviewAttachment[.id]) = \(linkPreview[.attachmentId])
                            """
                        )
                    }()
                ),
                PagedData.ObservedChanges(
                    table: Contact.self,
                    columns: [.isTrusted],
                    joinToPagedType: {
                        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                        let contact: TypedTableAlias<Contact> = TypedTableAlias()
                        
                        return SQL("JOIN \(Contact.self) ON \(contact[.id]) = \(interaction[.threadId])")
                    }()
                ),
                PagedData.ObservedChanges(
                    table: Profile.self,
                    columns: [.profilePictureFileName],
                    joinToPagedType: {
                        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                        let profile: TypedTableAlias<Profile> = TypedTableAlias()
                        
                        return SQL("JOIN \(Profile.self) ON \(profile[.id]) = \(interaction[.authorId])")
                    }()
                ),
                PagedData.ObservedChanges(
                    table: RecipientState.self,
                    columns: [.state, .readTimestampMs, .mostRecentFailureText],
                    joinToPagedType: {
                        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                        let recipientState: TypedTableAlias<RecipientState> = TypedTableAlias()
                        
                        return SQL("LEFT JOIN \(RecipientState.self) ON \(recipientState[.interactionId]) = \(interaction[.id])")
                    }()
                ),
            ],
            filterSQL: MessageViewModel.filterSQL(threadId: threadId),
            groupSQL: MessageViewModel.groupSQL,
            orderSQL: MessageViewModel.orderSQL,
            dataQuery: MessageViewModel.baseQuery(
                userSessionId: userSessionId,
                blinded15SessionId: blinded15SessionId,
                blinded25SessionId: blinded25SessionId,
                orderSQL: MessageViewModel.orderSQL,
                groupSQL: MessageViewModel.groupSQL
            ),
            associatedRecords: [
                AssociatedRecord<MessageViewModel.AttachmentInteractionInfo, MessageViewModel>(
                    trackedAgainst: Attachment.self,
                    observedChanges: [
                        PagedData.ObservedChanges(
                            table: Attachment.self,
                            columns: [.state]
                        )
                    ],
                    dataQuery: MessageViewModel.AttachmentInteractionInfo.baseQuery,
                    joinToPagedType: MessageViewModel.AttachmentInteractionInfo.joinToViewModelQuerySQL,
                    associateData: MessageViewModel.AttachmentInteractionInfo.createAssociateDataClosure()
                ),
                AssociatedRecord<MessageViewModel.ReactionInfo, MessageViewModel>(
                    trackedAgainst: Reaction.self,
                    observedChanges: [
                        PagedData.ObservedChanges(
                            table: Reaction.self,
                            columns: [.count]
                        )
                    ],
                    dataQuery: MessageViewModel.ReactionInfo.baseQuery,
                    joinToPagedType: MessageViewModel.ReactionInfo.joinToViewModelQuerySQL,
                    associateData: MessageViewModel.ReactionInfo.createAssociateDataClosure()
                ),
                AssociatedRecord<MessageViewModel.TypingIndicatorInfo, MessageViewModel>(
                    trackedAgainst: ThreadTypingIndicator.self,
                    observedChanges: [
                        PagedData.ObservedChanges(
                            table: ThreadTypingIndicator.self,
                            events: [.insert, .delete],
                            columns: []
                        )
                    ],
                    dataQuery: MessageViewModel.TypingIndicatorInfo.baseQuery,
                    joinToPagedType: MessageViewModel.TypingIndicatorInfo.joinToViewModelQuerySQL,
                    associateData: MessageViewModel.TypingIndicatorInfo.createAssociateDataClosure()
                )
            ],
            onChangeUnsorted: { [weak self] updatedData, updatedPageInfo in
                self?.resolveOptimisticUpdates(with: updatedData)
                
                PagedData.processAndTriggerUpdates(
                    updatedData: self?.process(
                        data: updatedData,
                        for: updatedPageInfo,
                        optimisticMessages: (self?.optimisticallyInsertedMessages.wrappedValue.values)
                            .map { $0.map { $0.messageViewModel } },
                        initialUnreadInteractionId: self?.initialUnreadInteractionId
                    ),
                    currentDataRetriever: { self?.interactionData },
                    onDataChange: self?.onInteractionChange,
                    onUnobservedDataChange: { updatedData, changeset in
                        self?.unobservedInteractionDataChanges = (changeset.isEmpty ?
                            nil :
                            (updatedData, changeset)
                        )
                    }
                )
            },
            using: dependencies
        )
    }
    
    private func process(
        data: [MessageViewModel],
        for pageInfo: PagedData.PageInfo,
        optimisticMessages: [MessageViewModel]?,
        initialUnreadInteractionId: Int64?
    ) -> [SectionModel] {
        let threadData: SessionThreadViewModel = self._threadData.wrappedValue
        let typingIndicator: MessageViewModel? = data.first(where: { $0.isTypingIndicator == true })
        let sortedData: [MessageViewModel] = data
            .filter { $0.id != MessageViewModel.optimisticUpdateId }    // Remove old optimistic updates
            .appending(contentsOf: (optimisticMessages ?? []))          // Insert latest optimistic updates
            .filter { !$0.cellType.isPostProcessed }                    // Remove headers and other
            .sorted { lhs, rhs -> Bool in lhs.timestampMs < rhs.timestampMs }
        
        // We load messages from newest to oldest so having a pageOffset larger than zero means
        // there are newer pages to load
        return [
            (!data.isEmpty && (pageInfo.pageOffset + pageInfo.currentCount) < pageInfo.totalCount ?
                [SectionModel(section: .loadOlder)] :
                []
            ),
            [
                SectionModel(
                    section: .messages,
                    elements: sortedData
                        .enumerated()
                        .map { index, cellViewModel -> MessageViewModel in
                            cellViewModel.withClusteringChanges(
                                prevModel: (index > 0 ? sortedData[index - 1] : nil),
                                nextModel: (index < (sortedData.count - 1) ? sortedData[index + 1] : nil),
                                isLast: (
                                    // The database query sorts by timestampMs descending so the "last"
                                    // interaction will actually have a 'pageOffset' of '0' even though
                                    // it's the last element in the 'sortedData' array
                                    index == (sortedData.count - 1) &&
                                    pageInfo.pageOffset == 0
                                ),
                                isLastOutgoing: (
                                    cellViewModel.id == sortedData
                                        .filter {
                                            $0.authorId == threadData.currentUserSessionId ||
                                            $0.authorId == threadData.currentUserBlinded15SessionId ||
                                            $0.authorId == threadData.currentUserBlinded25SessionId
                                        }
                                        .last?
                                        .id
                                ),
                                currentUserBlinded15SessionId: threadData.currentUserBlinded15SessionId,
                                currentUserBlinded25SessionId: threadData.currentUserBlinded25SessionId
                            )
                        }
                        .reduce([]) { result, message in
                            let updatedResult: [MessageViewModel] = result
                                .appending(initialUnreadInteractionId == nil || message.id != initialUnreadInteractionId ?
                                   nil :
                                    MessageViewModel(
                                        timestampMs: message.timestampMs,
                                        cellType: .unreadMarker
                                    )
                            )
                            
                            guard message.shouldShowDateHeader else {
                                return updatedResult.appending(message)
                            }
                            
                            return updatedResult
                                .appending(
                                    MessageViewModel(
                                        timestampMs: message.timestampMs,
                                        cellType: .dateHeader
                                    )
                                )
                                .appending(message)
                        }
                        .appending(typingIndicator)
                )
            ],
            (!data.isEmpty && pageInfo.pageOffset > 0 ?
                [SectionModel(section: .loadNewer)] :
                []
            )
        ].flatMap { $0 }
    }
    
    public func updateInteractionData(_ updatedData: [SectionModel]) {
        self.interactionData = updatedData
    }
    
    // MARK: - Optimistic Message Handling
    
    public typealias OptimisticMessageData = (
        id: UUID,
        messageViewModel: MessageViewModel,
        interaction: Interaction,
        attachmentData: [Attachment]?,
        linkPreviewDraft: LinkPreviewDraft?,
        linkPreviewAttachment: Attachment?,
        quoteModel: QuotedReplyModel?
    )
    
    private var optimisticallyInsertedMessages: Atomic<[UUID: OptimisticMessageData]> = Atomic([:])
    private var optimisticMessageAssociatedInteractionIds: Atomic<[Int64: UUID]> = Atomic([:])
    
    public func optimisticallyAppendOutgoingMessage(
        text: String?,
        sentTimestampMs: Int64,
        attachments: [SignalAttachment]?,
        linkPreviewDraft: LinkPreviewDraft?,
        quoteModel: QuotedReplyModel?
    ) -> OptimisticMessageData {
        // Generate the optimistic data
        let optimisticMessageId: UUID = UUID()
        let threadData: SessionThreadViewModel = self._threadData.wrappedValue
        let currentUserProfile: Profile = Profile.fetchOrCreateCurrentUser()
        let interaction: Interaction = Interaction(
            threadId: threadData.threadId,
            authorId: (threadData.currentUserBlinded15SessionId ?? threadData.currentUserSessionId),
            variant: .standardOutgoing,
            body: text,
            timestampMs: sentTimestampMs,
            hasMention: Interaction.isUserMentioned(
                publicKeysToCheck: [
                    threadData.currentUserSessionId,
                    threadData.currentUserBlinded15SessionId,
                    threadData.currentUserBlinded25SessionId
                ].compactMap { $0 },
                body: text
            ),
            linkPreviewUrl: linkPreviewDraft?.urlString
        )
        let optimisticAttachments: [Attachment]? = attachments
            .map { Attachment.prepare(attachments: $0) }
        let linkPreviewAttachment: Attachment? = linkPreviewDraft.map { draft in
            try? LinkPreview.generateAttachmentIfPossible(
                imageData: draft.jpegImageData,
                mimeType: MimeTypeUtil.MimeType.imageJpeg
            )
        }
        
        // Generate the actual 'MessageViewModel'
        let messageViewModel: MessageViewModel = MessageViewModel(
            optimisticMessageId: optimisticMessageId,
            threadId: threadData.threadId,
            threadVariant: threadData.threadVariant,
            threadHasDisappearingMessagesEnabled: (threadData.disappearingMessagesConfiguration?.isEnabled ?? false),
            threadOpenGroupServer: threadData.openGroupServer,
            threadOpenGroupPublicKey: threadData.openGroupPublicKey,
            threadContactNameInternal: threadData.threadContactName(),
            timestampMs: interaction.timestampMs,
            receivedAtTimestampMs: interaction.receivedAtTimestampMs,
            authorId: interaction.authorId,
            authorNameInternal: currentUserProfile.displayName(),
            body: interaction.body,
            expiresStartedAtMs: interaction.expiresStartedAtMs,
            expiresInSeconds: interaction.expiresInSeconds,
            isSenderOpenGroupModerator: OpenGroupManager.isUserModeratorOrAdmin(
                publicKey: threadData.currentUserSessionId,
                for: threadData.openGroupRoomToken,
                on: threadData.openGroupServer,
                using: dependencies
            ),
            currentUserProfile: currentUserProfile,
            quote: quoteModel.map { model in
                // Don't care about this optimistic quote (the proper one will be generated in the database)
                Quote(
                    interactionId: -1,    // Can't save to db optimistically
                    authorId: model.authorId,
                    timestampMs: model.timestampMs,
                    body: model.body,
                    attachmentId: model.attachment?.id
                )
            },
            quoteAttachment: quoteModel?.attachment,
            linkPreview: linkPreviewDraft.map { draft in
                LinkPreview(
                    url: draft.urlString,
                    title: draft.title,
                    attachmentId: nil    // Can't save to db optimistically
                )
            },
            linkPreviewAttachment: linkPreviewAttachment,
            attachments: optimisticAttachments
        )
        let optimisticData: OptimisticMessageData = (
            optimisticMessageId,
            messageViewModel,
            interaction,
            optimisticAttachments,
            linkPreviewDraft,
            linkPreviewAttachment,
            quoteModel
        )
        
        optimisticallyInsertedMessages.mutate { $0[optimisticMessageId] = optimisticData }
        forceUpdateDataIfPossible()
        
        return optimisticData
    }
    
    public func failedToStoreOptimisticOutgoingMessage(id: UUID, error: Error) {
        optimisticallyInsertedMessages.mutate {
            $0[id] = $0[id].map {
                (
                    $0.id,
                    $0.messageViewModel.with(
                        state: .failed,
                        mostRecentFailureText: "FAILED_TO_STORE_OUTGOING_MESSAGE".localized()
                    ),
                    $0.interaction,
                    $0.attachmentData,
                    $0.linkPreviewDraft,
                    $0.linkPreviewAttachment,
                    $0.quoteModel
                )
            }
        }
        
        forceUpdateDataIfPossible()
    }
    
    /// Record an association between an `optimisticMessageId` and a specific `interactionId`
    public func associate(optimisticMessageId: UUID, to interactionId: Int64?) {
        guard let interactionId: Int64 = interactionId else { return }
        
        optimisticMessageAssociatedInteractionIds.mutate { $0[interactionId] = optimisticMessageId }
    }
    
    public func optimisticMessageData(for optimisticMessageId: UUID) -> OptimisticMessageData? {
        return optimisticallyInsertedMessages.wrappedValue[optimisticMessageId]
    }
    
    /// Remove any optimisticUpdate entries which have an associated interactionId in the provided data
    private func resolveOptimisticUpdates(with data: [MessageViewModel]) {
        let interactionIds: [Int64] = data.map { $0.id }
        let idsToRemove: [UUID] = optimisticMessageAssociatedInteractionIds
            .mutate { associatedIds in interactionIds.compactMap { associatedIds.removeValue(forKey: $0) } }
        
        optimisticallyInsertedMessages.mutate { messages in idsToRemove.forEach { messages.removeValue(forKey: $0) } }
    }
    
    private func forceUpdateDataIfPossible() {
        // If we can't get the current page data then don't bother trying to update (it's not going to work)
        guard let currentPageInfo: PagedData.PageInfo = self.pagedDataObserver?.pageInfo.wrappedValue else { return }
        
        /// **MUST** have the same logic as in the 'PagedDataObserver.onChangeUnsorted' above
        let currentData: [SectionModel] = (unobservedInteractionDataChanges?.0 ?? interactionData)
        
        PagedData.processAndTriggerUpdates(
            updatedData: process(
                data: (currentData.first(where: { $0.model == .messages })?.elements ?? []),
                for: currentPageInfo,
                optimisticMessages: optimisticallyInsertedMessages.wrappedValue.values.map { $0.messageViewModel },
                initialUnreadInteractionId: initialUnreadInteractionId
            ),
            currentDataRetriever: { [weak self] in self?.interactionData },
            onDataChange: self.onInteractionChange,
            onUnobservedDataChange: { [weak self] updatedData, changeset in
                self?.unobservedInteractionDataChanges = (changeset.isEmpty ?
                    nil :
                    (updatedData, changeset)
                )
            }
        )
    }
    
    // MARK: - Mentions
    
    public func mentions(for query: String = "") -> [MentionInfo] {
        let threadData: SessionThreadViewModel = self._threadData.wrappedValue
        
        return dependencies[singleton: .storage]
            .read { [dependencies] db -> [MentionInfo] in
                let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                let pattern: FTS5Pattern? = try? SessionThreadViewModel.pattern(db, searchTerm: query, forTable: Profile.self)
                let capabilities: Set<Capability.Variant> = (threadData.threadVariant != .community ?
                    nil :
                    try? Capability
                        .select(.variant)
                        .filter(Capability.Columns.openGroupServer == threadData.openGroupServer)
                        .asRequest(of: Capability.Variant.self)
                        .fetchSet(db)
                )
                .defaulting(to: [])
                let targetPrefixes: [SessionId.Prefix] = (capabilities.contains(.blind) ?
                    [.blinded15, .blinded25] :
                    [.standard]
                )
                
                return (try MentionInfo
                    .query(
                        userPublicKey: userSessionId.hexString,
                        threadId: threadData.threadId,
                        threadVariant: threadData.threadVariant,
                        targetPrefixes: targetPrefixes,
                        pattern: pattern
                    )?
                    .fetchAll(db))
                    .defaulting(to: [])
            }
            .defaulting(to: [])
    }
    
    // MARK: - Functions
    
    public func updateDraft(to draft: String) {
        let threadId: String = self.threadId
        let currentDraft: String = dependencies[singleton: .storage]
            .read { db in
                try SessionThread
                    .select(.messageDraft)
                    .filter(id: threadId)
                    .asRequest(of: String.self)
                    .fetchOne(db)
            }
            .defaulting(to: "")
        
        // Only write the updated draft to the database if it's changed (avoid unnecessary writes)
        guard draft != currentDraft else { return }
        
        dependencies[singleton: .storage].writeAsync { db in
            try SessionThread
                .filter(id: threadId)
                .updateAll(db, SessionThread.Columns.messageDraft.set(to: draft))
        }
    }
    
    /// This method indicates whether the client should try to mark the thread or it's messages as read (it's an optimisation for fully read
    /// conversations so we can avoid iterating through the visible conversation cells every scroll)
    public func shouldTryMarkAsRead() -> Bool {
        return (
            (threadData.threadUnreadCount ?? 0) > 0 ||
            threadData.threadWasMarkedUnread == true
        )
    }
    
    /// This method marks a thread as read and depending on the target may also update the interactions within a thread as read
    public func markAsRead(
        target: SessionThreadViewModel.ReadTarget,
        timestampMs: Int64?
    ) {
        /// Since this method now gets triggered when scrolling we want to try to optimise it and avoid busying the database
        /// write queue when it isn't needed, in order to do this we:
        /// - Throttle the updates to 100ms (quick enough that users shouldn't notice, but will help the DB when the user flings the list)
        /// - Only mark interactions as read if they have newer `timestampMs` or `id` values (ie. were sent later or were more-recent
        /// entries in the database), **Note:** Old messages will be marked as read upon insertion so shouldn't be an issue
        ///
        /// The `ThreadViewModel.markAsRead` method also tries to avoid marking as read if a conversation is already fully read
        if markAsReadPublisher == nil {
            markAsReadPublisher = markAsReadTrigger
                .throttle(for: .milliseconds(100), scheduler: DispatchQueue.global(qos: .userInitiated), latest: true)
                .handleEvents(
                    receiveOutput: { [weak self] target, timestampMs in
                        let threadData: SessionThreadViewModel? = self?._threadData.wrappedValue
                        
                        switch target {
                            case .thread: threadData?.markAsRead(target: target)
                            case .threadAndInteractions(let interactionId):
                                guard
                                    timestampMs == nil ||
                                    (self?.lastInteractionTimestampMsMarkedAsRead ?? 0) < (timestampMs ?? 0) ||
                                    (self?.lastInteractionIdMarkedAsRead ?? 0) < (interactionId ?? 0)
                                else {
                                    threadData?.markAsRead(target: .thread)
                                    return
                                }
                                
                                // If we were given a timestamp then update the 'lastInteractionTimestampMsMarkedAsRead'
                                // to avoid needless updates
                                if let timestampMs: Int64 = timestampMs {
                                    self?.lastInteractionTimestampMsMarkedAsRead = timestampMs
                                }
                                
                                self?.lastInteractionIdMarkedAsRead = (interactionId ?? threadData?.interactionId)
                                threadData?.markAsRead(target: target)
                        }
                    }
                )
                .map { _ in () }
                .eraseToAnyPublisher()
            
            markAsReadPublisher?.sinkUntilComplete()
        }
        
        markAsReadTrigger.send((target, timestampMs))
    }
    
    public func swapToThread(updatedThreadId: String, focussedMessageId: Int64?) {
        self.threadId = updatedThreadId
        self.observableThreadData = self.setupObservableThreadData(for: updatedThreadId)
        self.pagedDataObserver = self.setupPagedObserver(
            for: updatedThreadId,
            userSessionId: getUserSessionId(using: dependencies),
            blinded15SessionId: nil,
            blinded25SessionId: nil,
            using: dependencies
        )
        
        // Try load everything up to the initial visible message, fallback to just the initial page of messages
        // if we don't have one
        switch focussedMessageId {
            case .some(let id): self.pagedDataObserver?.load(.initialPageAround(id: id))
            case .none: self.pagedDataObserver?.load(.pageBefore)
        }
    }
    
    public func trustContact() {
        guard self._threadData.wrappedValue.threadVariant == .contact else { return }
        
        dependencies[singleton: .storage].writeAsync { [threadId, dependencies] db in
            try Contact
                .filter(id: threadId)
                .updateAll(db, Contact.Columns.isTrusted.set(to: true))
            
            // Start downloading any pending attachments for this contact (UI will automatically be
            // updated due to the database observation)
            try Attachment
                .stateInfo(authorId: threadId, state: .pendingDownload)
                .fetchAll(db)
                .forEach { attachmentDownloadInfo in
                    dependencies[singleton: .jobRunner].add(
                        db,
                        job: Job(
                            variant: .attachmentDownload,
                            threadId: threadId,
                            interactionId: attachmentDownloadInfo.interactionId,
                            details: AttachmentDownloadJob.Details(
                                attachmentId: attachmentDownloadInfo.attachmentId
                            )
                        ),
                        canStartJob: true,
                        using: dependencies
                    )
                }
        }
    }
    
    public func unblockContact() {
        guard self._threadData.wrappedValue.threadVariant == .contact else { return }
        
        dependencies[singleton: .storage].writeAsync { [threadId, dependencies] db in
            try Contact
                .filter(id: threadId)
                .updateAllAndConfig(db, Contact.Columns.isBlocked.set(to: false), using: dependencies)
        }
    }
    
    public func expandReactions(for interactionId: Int64) {
        reactionExpandedInteractionIds.insert(interactionId)
    }
    
    public func collapseReactions(for interactionId: Int64) {
        reactionExpandedInteractionIds.remove(interactionId)
    }
    
    public func deletionActions(
        for cellViewModel: MessageViewModel,
        threadName: String
    ) -> DeletionBehaviours {
        struct InteractionInfo: FetchableRecord, Decodable {
            let serverHash: String?
            let openGroupServerMessageId: Int64?
        }
        struct OpenGroupInfo: FetchableRecord, Decodable {
            let server: String
            let roomToken: String
        }
        struct GroupAuthData: Codable, FetchableRecord {
            let groupIdentityPrivateKey: Data?
            let authData: Data?
        }
        
        return dependencies[singleton: .storage].read(using: dependencies) { [dependencies] db -> DeletionBehaviours in
            let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
            let interactionInfo: InteractionInfo = try Interaction
                .filter(id: cellViewModel.id)
                .select(.serverHash, .openGroupServerMessageId)
                .asRequest(of: InteractionInfo.self)
                .fetchOne(db) ?? { throw MessageSenderError.invalidMessage }()
            let groupAuthData: GroupAuthData? = try? ClosedGroup
                .filter(id: cellViewModel.threadId)
                .select(.authData, .groupIdentityPrivateKey)
                .asRequest(of: GroupAuthData.self)
                .fetchOne(db)
            let groupAuthInfo: Authentication.Info? = {
                switch (groupAuthData?.groupIdentityPrivateKey, groupAuthData?.authData) {
                    case (.none, .none): return nil
                    case (.some(let groupIdentityPrivateKey), _):
                        return .groupAdmin(
                            groupSessionId: SessionId(.group, hex: cellViewModel.threadId),
                            ed25519SecretKey: Array(groupIdentityPrivateKey)
                        )
                        
                    case (_, .some(let authData)):
                        return .groupMember(
                            groupSessionId: SessionId(.group, hex: cellViewModel.threadId),
                            authData: authData
                        )
                }
            }()
            let dataToSwitchOn = (
                cellViewModel.threadVariant,
                cellViewModel.variant,
                interactionInfo.serverHash,
                interactionInfo.openGroupServerMessageId,
                groupAuthInfo
            )
            
            /// The methods we use to delete a message depends on the type of conversation it belongs to
            switch dataToSwitchOn {
                /// If a message has not been sent then only support a local deletion (or the user has missing/invalid auth data)
                ///
                /// **Note:** It's possible for the user to press the delete button before the send completes and then trigger the deletion
                /// after the send has completed - there isn't really a good way to completely handle this so just rely on the user to avoid
                /// deleting in this situation
                case (_, _, .none, .none, _), (.community, _, .some, .none, _), (.group, _, .none, .some, _), (.contact, _, .none, .some, _), (.group, _, .some, _, .none), (.group, _, .some, _, .standard):
                    return DeletionBehaviours.deleteForMe(id: cellViewModel.id)
                    
                /// Delete from the current device
                /// Delete from all participant devices via an `UnsendRequest`
                /// Delete from the current users swarm
                case (.contact, _, .some(let serverHash), _, _):
                    guard cellViewModel.threadId != userSessionId.hexString else {
                        return DeletionBehaviours(
                            actions: [
                                DeletionBehaviours.Action(
                                    title: "delete_message_for_me_and_my_devices".localized(),
                                    behaviours: [
                                        .preparedRequest(try MessageSender
                                            .preparedSend(
                                                db,
                                                message: UnsendRequest(
                                                    timestamp: UInt64(cellViewModel.timestampMs),
                                                    author: (cellViewModel.variant == .standardOutgoing ?
                                                        userSessionId.hexString :
                                                                cellViewModel.authorId
                                                    )
                                                ),
                                                to: .contact(publicKey: cellViewModel.threadId),
                                                namespace: .default,
                                                interactionId: nil,
                                                fileIds: []
                                            )),
                                        .preparedRequest(try SnodeAPI
                                            .preparedDeleteMessages(
                                                serverHashes: [serverHash],
                                                requireSuccessfulDeletion: false,
                                                authMethod: try Authentication.with(
                                                    db,
                                                    sessionIdHexString: userSessionId.hexString,
                                                    using: dependencies
                                                ),
                                                using: dependencies
                                            )
                                            .map { _, _ in () }),
                                        .deleteFromDatabase(cellViewModel.id)
                                    ]
                                )
                            ]
                        )
                    }
                    
                    return DeletionBehaviours(
                        actions: [
                            DeletionBehaviours.deleteForMe(id: cellViewModel.id).actions[0],
                            DeletionBehaviours.Action(
                                title: String(format: "delete_message_for_me_and_recipient".localized(), threadName),
                                accessibility: Accessibility(identifier: "Delete for everyone"),
                                behaviours: [
                                    .preparedRequest(try MessageSender
                                        .preparedSend(
                                            db,
                                            message: UnsendRequest(
                                                timestamp: UInt64(cellViewModel.timestampMs),
                                                author: (cellViewModel.variant == .standardOutgoing ?
                                                    userSessionId.hexString :
                                                            cellViewModel.authorId
                                                )
                                            ),
                                            to: .contact(publicKey: cellViewModel.threadId),
                                            namespace: .default,
                                            interactionId: nil,
                                            fileIds: []
                                        )),
                                    .preparedRequest(try SnodeAPI
                                        .preparedDeleteMessages(
                                            serverHashes: [serverHash],
                                            requireSuccessfulDeletion: false,
                                            authMethod: try Authentication.with(
                                                db,
                                                sessionIdHexString: userSessionId.hexString,
                                                using: dependencies
                                            ),
                                            using: dependencies
                                        )
                                        .map { _, _ in () }),
                                    .deleteFromDatabase(cellViewModel.id)
                                ]
                            )
                        ]
                    )
                
                /// **Message sent by current user**
                /// Delete from all participant devices via an `UnsendRequest`
                /// Delete from the current device
                ///
                /// **Note:** We **cannot** delete from the current users swarm in legacy groups
                case (.legacyGroup, .standardOutgoing, _, _, _):
                    return DeletionBehaviours(
                        actions: [
                            DeletionBehaviours.deleteForMe(id: cellViewModel.id).actions[0],
                            DeletionBehaviours.Action(
                                title: "delete_message_for_everyone".localized(),
                                accessibility: Accessibility(identifier: "Delete for everyone"),
                                behaviours: [
                                    .preparedRequest(try MessageSender
                                        .preparedSend(
                                            db,
                                            message: UnsendRequest(
                                                timestamp: UInt64(cellViewModel.timestampMs),
                                                author: (cellViewModel.variant == .standardOutgoing ?
                                                    userSessionId.hexString :
                                                    cellViewModel.authorId
                                                )
                                            ),
                                            to: .closedGroup(groupPublicKey: cellViewModel.threadId),
                                            namespace: .legacyClosedGroup,
                                            interactionId: nil,
                                            fileIds: []
                                        )),
                                    .deleteFromDatabase(cellViewModel.id)
                                ]
                            )
                        ]
                    )
                    
                /// **Message not sent by current user**
                /// Delete from the current device
                case (.legacyGroup, _, _, _, _):
                    return DeletionBehaviours.deleteForMe(id: cellViewModel.id)
                
                /// **Message sent by current user and a standard member**
                /// Delete from all participant devices via an `GroupUpdateDeleteMemberContentMessage`
                /// Delete from the current device
                case (.group, .standardOutgoing, .some(let serverHash), _, .groupMember):
                    return DeletionBehaviours(
                        actions: [
                            DeletionBehaviours.deleteForMe(id: cellViewModel.id).actions[0],
                            DeletionBehaviours.Action(
                                title: "delete_message_for_everyone".localized(),
                                accessibility: Accessibility(identifier: "Delete for everyone"),
                                behaviours: [
                                    /// **Note:** No signature for member delete content
                                    .preparedRequest(try MessageSender
                                        .preparedSend(
                                            db,
                                            message: GroupUpdateDeleteMemberContentMessage(
                                                memberSessionIds: [],
                                                messageHashes: [serverHash],
                                                sentTimestamp: UInt64(
                                                    SnodeAPI.currentOffsetTimestampMs(using: dependencies)
                                                ),
                                                authMethod: nil,
                                                using: dependencies
                                            ),
                                            to: .closedGroup(groupPublicKey: cellViewModel.threadId),
                                            namespace: .groupMessages,
                                            interactionId: nil,
                                            fileIds: []
                                        )),
                                    .deleteFromDatabase(cellViewModel.id)
                                ]
                            )
                        ]
                    )
                
                /// **Message not sent by current user and a standard member**
                /// Delete from the current device
                case (.group, _, _, _, .groupMember):
                    return DeletionBehaviours.deleteForMe(id: cellViewModel.id)
                    
                /// **Member is a group admin**
                /// **If user is an admin** delete from all participant devices via an `GroupUpdateDeleteMemberContentMessage`
                /// **If user is an admin** delete from the group swarm
                /// Delete from the current device
                case (.group, _, .some(let serverHash), _, .groupAdmin(let groupSessionId, let ed25519SecretKey)):
                    return DeletionBehaviours(
                        actions: [
                            DeletionBehaviours.deleteForMe(id: cellViewModel.id).actions[0],
                            DeletionBehaviours.Action(
                                title: "delete_message_for_everyone".localized(),
                                accessibility: Accessibility(identifier: "Delete for everyone"),
                                behaviours: [
                                    .preparedRequest(try MessageSender
                                        .preparedSend(
                                            db,
                                            message: GroupUpdateDeleteMemberContentMessage(
                                                memberSessionIds: [],
                                                messageHashes: [serverHash],
                                                sentTimestamp: UInt64(
                                                    SnodeAPI.currentOffsetTimestampMs(using: dependencies)
                                                ),
                                                authMethod: Authentication.groupAdmin(
                                                    groupSessionId: groupSessionId,
                                                    ed25519SecretKey: ed25519SecretKey
                                                ),
                                                using: dependencies
                                            ),
                                            to: .closedGroup(groupPublicKey: cellViewModel.threadId),
                                            namespace: .groupMessages,
                                            interactionId: nil,
                                            fileIds: []
                                        )),
                                    .preparedRequest(try SnodeAPI
                                        .preparedDeleteMessages(
                                            serverHashes: [serverHash],
                                            requireSuccessfulDeletion: false,
                                            authMethod: Authentication.groupAdmin(
                                                groupSessionId: groupSessionId,
                                                ed25519SecretKey: ed25519SecretKey
                                            ),
                                            using: dependencies
                                        )
                                        .map { _, _ in () }),
                                    .deleteFromDatabase(cellViewModel.id)
                                ]
                            )
                        ]
                    )
                    
                /// **If message hasn't been sent yet** delete from the current device
                ///     **Note:** We don't support local deletion after sending because it can't be synced easily between devices and the
                ///     message would return if the user left and rejoined the community)
                /// **If user is an admin OR message sent by current user** delete from the open group
                case (.community, _, _, .some(let openGroupServerMessageId), _):
                    guard
                        let openGroupInfo: OpenGroupInfo = try? OpenGroup
                            .filter(id: cellViewModel.threadId)
                            .select(.roomToken, .server)
                            .asRequest(of: OpenGroupInfo.self)
                            .fetchOne(db),
                        (
                            cellViewModel.variant == .standardOutgoing ||
                            OpenGroupManager.isUserModeratorOrAdmin(
                                db,
                                publicKey: userSessionId.hexString,
                                for: openGroupInfo.roomToken,
                                on: openGroupInfo.server,
                                using: dependencies
                            )
                        )
                    else { return DeletionBehaviours(actions: []) }
                    
                    return DeletionBehaviours(
                        actions: [
                            DeletionBehaviours.Action(
                                title: "delete_message_for_everyone".localized(),
                                accessibility: Accessibility(identifier: "Delete for everyone"),
                                behaviours: [
                                    .preparedRequest(try OpenGroupAPI
                                        .preparedMessageDelete(
                                            db,
                                            id: openGroupServerMessageId,
                                            in: openGroupInfo.roomToken,
                                            on: openGroupInfo.server
                                        )
                                        .map { _, _ in () }),
                                    .deleteFromDatabase(cellViewModel.id)
                                ]
                            )
                        ]
                    )
            }
        }
        .defaulting(to: DeletionBehaviours.deleteForMe(id: cellViewModel.id))
    }
    
    // MARK: - Audio Playback
    
    public struct PlaybackInfo {
        let state: AudioPlaybackState
        let progress: TimeInterval
        let playbackRate: Double
        let oldPlaybackRate: Double
        let updateCallback: (PlaybackInfo?, Error?) -> ()
        
        public func with(
            state: AudioPlaybackState? = nil,
            progress: TimeInterval? = nil,
            playbackRate: Double? = nil,
            updateCallback: ((PlaybackInfo?, Error?) -> ())? = nil
        ) -> PlaybackInfo {
            return PlaybackInfo(
                state: (state ?? self.state),
                progress: (progress ?? self.progress),
                playbackRate: (playbackRate ?? self.playbackRate),
                oldPlaybackRate: self.playbackRate,
                updateCallback: (updateCallback ?? self.updateCallback)
            )
        }
    }
    
    private var audioPlayer: Atomic<OWSAudioPlayer?> = Atomic(nil)
    private var currentPlayingInteraction: Atomic<Int64?> = Atomic(nil)
    private var playbackInfo: Atomic<[Int64: PlaybackInfo]> = Atomic([:])
    
    public func playbackInfo(for viewModel: MessageViewModel, updateCallback: ((PlaybackInfo?, Error?) -> ())? = nil) -> PlaybackInfo? {
        // Use the existing info if it already exists (update it's callback if provided as that means
        // the cell was reloaded)
        if let currentPlaybackInfo: PlaybackInfo = playbackInfo.wrappedValue[viewModel.id] {
            let updatedPlaybackInfo: PlaybackInfo = currentPlaybackInfo
                .with(updateCallback: updateCallback)
            
            playbackInfo.mutate { $0[viewModel.id] = updatedPlaybackInfo }
            
            return updatedPlaybackInfo
        }
        
        // Validate the item is a valid audio item
        guard
            let updateCallback: ((PlaybackInfo?, Error?) -> ()) = updateCallback,
            let attachment: Attachment = viewModel.attachments?.first,
            attachment.isAudio,
            attachment.isValid,
            let originalFilePath: String = attachment.originalFilePath,
            FileManager.default.fileExists(atPath: originalFilePath)
        else { return nil }
        
        // Create the info with the update callback
        let newPlaybackInfo: PlaybackInfo = PlaybackInfo(
            state: .stopped,
            progress: 0,
            playbackRate: 1,
            oldPlaybackRate: 1,
            updateCallback: updateCallback
        )
        
        // Cache the info
        playbackInfo.mutate { $0[viewModel.id] = newPlaybackInfo }
        
        return newPlaybackInfo
    }
    
    public func playOrPauseAudio(for viewModel: MessageViewModel) {
        guard
            let attachment: Attachment = viewModel.attachments?.first,
            let originalFilePath: String = attachment.originalFilePath,
            FileManager.default.fileExists(atPath: originalFilePath)
        else { return }
        
        // If the user interacted with the currently playing item
        guard currentPlayingInteraction.wrappedValue != viewModel.id else {
            let currentPlaybackInfo: PlaybackInfo? = playbackInfo.wrappedValue[viewModel.id]
            let updatedPlaybackInfo: PlaybackInfo? = currentPlaybackInfo?
                .with(
                    state: (currentPlaybackInfo?.state != .playing ? .playing : .paused),
                    playbackRate: 1
                )
            
            audioPlayer.wrappedValue?.playbackRate = 1
            
            switch currentPlaybackInfo?.state {
                case .playing: audioPlayer.wrappedValue?.pause()
                default: audioPlayer.wrappedValue?.play()
            }
            
            // Update the state and then update the UI with the updated state
            playbackInfo.mutate { $0[viewModel.id] = updatedPlaybackInfo }
            updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, nil)
            return
        }
        
        // First stop any existing audio
        audioPlayer.wrappedValue?.stop()
        
        // Then setup the state for the new audio
        currentPlayingInteraction.mutate { $0 = viewModel.id }
        
        let currentPlaybackTime: TimeInterval? = playbackInfo.wrappedValue[viewModel.id]?.progress
        audioPlayer.mutate { [weak self] player in
            // Note: We clear the delegate and explicitly set to nil here as when the OWSAudioPlayer
            // gets deallocated it triggers state changes which cause UI bugs when auto-playing
            player?.delegate = nil
            player = nil
            
            let audioPlayer: OWSAudioPlayer = OWSAudioPlayer(
                mediaUrl: URL(fileURLWithPath: originalFilePath),
                audioBehavior: .audioMessagePlayback,
                delegate: self
            )
            audioPlayer.play()
            audioPlayer.setCurrentTime(currentPlaybackTime ?? 0)
            player = audioPlayer
        }
    }
    
    public func speedUpAudio(for viewModel: MessageViewModel) {
        // If we aren't playing the specified item then just start playing it
        guard viewModel.id == currentPlayingInteraction.wrappedValue else {
            playOrPauseAudio(for: viewModel)
            return
        }
        
        let updatedPlaybackInfo: PlaybackInfo? = playbackInfo.wrappedValue[viewModel.id]?
            .with(playbackRate: 1.5)
        
        // Speed up the audio player
        audioPlayer.wrappedValue?.playbackRate = 1.5
        
        playbackInfo.mutate { $0[viewModel.id] = updatedPlaybackInfo }
        updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, nil)
    }
    
    public func stopAudio() {
        audioPlayer.wrappedValue?.stop()
        
        currentPlayingInteraction.mutate { $0 = nil }
        audioPlayer.mutate {
            // Note: We clear the delegate and explicitly set to nil here as when the OWSAudioPlayer
            // gets deallocated it triggers state changes which cause UI bugs when auto-playing
            $0?.delegate = nil
            $0 = nil
        }
    }
    
    // MARK: - OWSAudioPlayerDelegate
    
    public func audioPlaybackState() -> AudioPlaybackState {
        guard let interactionId: Int64 = currentPlayingInteraction.wrappedValue else { return .stopped }
        
        return (playbackInfo.wrappedValue[interactionId]?.state ?? .stopped)
    }
    
    public func setAudioPlaybackState(_ state: AudioPlaybackState) {
        guard let interactionId: Int64 = currentPlayingInteraction.wrappedValue else { return }
        
        let updatedPlaybackInfo: PlaybackInfo? = playbackInfo.wrappedValue[interactionId]?
            .with(state: state)
        
        playbackInfo.mutate { $0[interactionId] = updatedPlaybackInfo }
        updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, nil)
    }
    
    public func setAudioProgress(_ progress: CGFloat, duration: CGFloat) {
        guard let interactionId: Int64 = currentPlayingInteraction.wrappedValue else { return }
        
        let updatedPlaybackInfo: PlaybackInfo? = playbackInfo.wrappedValue[interactionId]?
            .with(progress: TimeInterval(progress))
        
        playbackInfo.mutate { $0[interactionId] = updatedPlaybackInfo }
        updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, nil)
    }
    
    public func audioPlayerDidFinishPlaying(_ player: OWSAudioPlayer, successfully: Bool) {
        guard let interactionId: Int64 = currentPlayingInteraction.wrappedValue else { return }
        guard successfully else { return }
        
        let updatedPlaybackInfo: PlaybackInfo? = playbackInfo.wrappedValue[interactionId]?
            .with(
                state: .stopped,
                progress: 0,
                playbackRate: 1
            )
        
        // Safe the changes and send one final update to the UI
        playbackInfo.mutate { $0[interactionId] = updatedPlaybackInfo }
        updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, nil)
        
        // Clear out the currently playing record
        currentPlayingInteraction.mutate { $0 = nil }
        audioPlayer.mutate {
            // Note: We clear the delegate and explicitly set to nil here as when the OWSAudioPlayer
            // gets deallocated it triggers state changes which cause UI bugs when auto-playing
            $0?.delegate = nil
            $0 = nil
        }
        
        // If the next interaction is another voice message then autoplay it
        guard
            let messageSection: SectionModel = self.interactionData
                .first(where: { $0.model == .messages }),
            let currentIndex: Int = messageSection.elements
                .firstIndex(where: { $0.id == interactionId }),
            currentIndex < (messageSection.elements.count - 1),
            messageSection.elements[currentIndex + 1].cellType == .voiceMessage,
            dependencies[singleton: .storage, key: .shouldAutoPlayConsecutiveAudioMessages]
        else { return }
        
        let nextItem: MessageViewModel = messageSection.elements[currentIndex + 1]
        playOrPauseAudio(for: nextItem)
    }
    
    public func showInvalidAudioFileAlert() {
        guard let interactionId: Int64 = currentPlayingInteraction.wrappedValue else { return }
        
        let updatedPlaybackInfo: PlaybackInfo? = playbackInfo.wrappedValue[interactionId]?
            .with(
                state: .stopped,
                progress: 0,
                playbackRate: 1
            )
        
        currentPlayingInteraction.mutate { $0 = nil }
        playbackInfo.mutate { $0[interactionId] = updatedPlaybackInfo }
        updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, AttachmentError.invalidData)
    }
}

// MARK: - ConversationViewModel.DeletionBehaviours

public extension ConversationViewModel {
    struct DeletionBehaviours {
        struct Action {
            let title: String
            let accessibility: Accessibility?
            let behaviours: [Behaviour]
            
            init(title: String, accessibility: Accessibility? = nil, behaviours: [Behaviour]) {
                self.title = title
                self.accessibility = accessibility
                self.behaviours = behaviours
            }
        }
        
        enum Behaviour {
            case deleteFromDatabase(Int64)
            case preparedRequest(HTTP.PreparedRequest<Void>)
        }
        
        static let defaultTitle: String = "delete_message_for_me".localized()
        
        let actions: [Action]
        
        // MARK: - Functions
        
        static func deleteForMe(id: Int64) -> DeletionBehaviours {
            DeletionBehaviours(
                actions: [
                    Action(
                        title: "delete_message_for_me".localized(),
                        accessibility: Accessibility(identifier: "Delete for me"),
                        behaviours: [.deleteFromDatabase(id)]
                    )
                ]
            )
        }
        
        /// Indicates whether the specified action is solely a "deleteFromDatabase" action
        public func isOnlyDeleteFromDatabase(at index: Int) -> Bool {
            guard index >= 0, index < actions.count else { return false }
            
            switch (actions[index].behaviours.count, actions[index].behaviours.first) {
                case (1, .deleteFromDatabase): return true
                default: return false
            }
        }
        
        /// Collect the actions and construct a publisher which triggers each action before returning the result
        public func publisherForAction(at index: Int, using dependencies: Dependencies) -> AnyPublisher<Void, Error> {
            guard index >= 0, index < actions.count else {
                return Fail(error: StorageError.objectNotFound).eraseToAnyPublisher()
            }
            
            var result: AnyPublisher<Void, Error> = Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
            
            actions[index].behaviours.forEach { behaviour in
                switch behaviour {
                    case .deleteFromDatabase(let id):
                        result = result
                            .flatMap { _ in
                                dependencies[singleton: .storage].writePublisher(using: dependencies) { db in
                                    _ = try Interaction
                                        .filter(id: id)
                                        .deleteAll(db)
                                }
                            }
                            .eraseToAnyPublisher()
                        
                    case .preparedRequest(let preparedRequest):
                        result = result
                            .flatMap { _ in preparedRequest.send(using: dependencies) }
                            .map { _, _ in () }
                            .eraseToAnyPublisher()
                }
            }
            
            return result
        }
    }
}
