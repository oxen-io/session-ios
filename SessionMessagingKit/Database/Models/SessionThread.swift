// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

public struct SessionThread: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "thread" }
    public static let contact = hasOne(Contact.self, using: Contact.threadForeignKey)
    public static let closedGroup = hasOne(ClosedGroup.self, using: ClosedGroup.threadForeignKey)
    public static let openGroup = hasOne(OpenGroup.self, using: OpenGroup.threadForeignKey)
    public static let disappearingMessagesConfiguration = hasOne(
        DisappearingMessagesConfiguration.self,
        using: DisappearingMessagesConfiguration.threadForeignKey
    )
    public static let interactions = hasMany(Interaction.self, using: Interaction.threadForeignKey)
    public static let typingIndicator = hasOne(
        ThreadTypingIndicator.self,
        using: ThreadTypingIndicator.threadForeignKey
    )
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case variant
        case creationDateTimestamp
        case shouldBeVisible
        @available(*, deprecated, message: "use 'pinnedPriority > 0' instead") case isPinned
        case messageDraft
        case notificationSound
        case mutedUntilTimestamp
        case onlyNotifyForMentions
        case markedAsUnread
        case pinnedPriority
    }
    
    public enum Variant: Int, Codable, Hashable, DatabaseValueConvertible, CaseIterable {
        case contact
        case legacyGroup
        case community
        case group
    }

    /// Unique identifier for a thread (formerly known as uniqueId)
    ///
    /// This value will depend on the variant:
    /// **contact:** The contact id
    /// **closedGroup:** The closed group public key
    /// **openGroup:** The `\(server.lowercased()).\(room)` value
    public let id: String
    
    /// Enum indicating what type of thread this is
    public let variant: Variant
    
    /// A timestamp indicating when this thread was created
    public let creationDateTimestamp: TimeInterval
    
    /// A flag indicating whether the thread should be visible
    public let shouldBeVisible: Bool
    
    /// A flag indicating whether the thread is pinned
    @available(*, deprecated, message: "use 'pinnedPriority > 0' instead")
    private let isPinned: Bool = false
    
    /// The value the user started entering into the input field before they left the conversation screen
    public let messageDraft: String?
    
    /// The sound which should be used when receiving a notification for this thread
    ///
    /// **Note:** If unset this will use the `Preferences.Sound.defaultNotificationSound`
    public let notificationSound: Preferences.Sound?
    
    /// Timestamp (seconds since epoch) for when this thread should stop being muted
    public let mutedUntilTimestamp: TimeInterval?
    
    /// A flag indicating whether the thread should only notify for mentions
    public let onlyNotifyForMentions: Bool
    
    /// A flag indicating whether this thread has been manually marked as unread by the user
    public let markedAsUnread: Bool?
    
    /// A value indicating the priority of this conversation within the pinned conversations
    public let pinnedPriority: Int32?
    
    // MARK: - Relationships
    
    public var contact: QueryInterfaceRequest<Contact> {
        request(for: SessionThread.contact)
    }
    
    public var closedGroup: QueryInterfaceRequest<ClosedGroup> {
        request(for: SessionThread.closedGroup)
    }
    
    public var openGroup: QueryInterfaceRequest<OpenGroup> {
        request(for: SessionThread.openGroup)
    }
    
    public var disappearingMessagesConfiguration: QueryInterfaceRequest<DisappearingMessagesConfiguration> {
        request(for: SessionThread.disappearingMessagesConfiguration)
    }
    
    public var interactions: QueryInterfaceRequest<Interaction> {
        request(for: SessionThread.interactions)
    }
    
    public var typingIndicator: QueryInterfaceRequest<ThreadTypingIndicator> {
        request(for: SessionThread.typingIndicator)
    }
    
    // MARK: - Initialization
    
    public init(
        id: String,
        variant: Variant,
        creationDateTimestamp: TimeInterval? = nil,
        shouldBeVisible: Bool = false,
        isPinned: Bool = false,
        messageDraft: String? = nil,
        notificationSound: Preferences.Sound? = nil,
        mutedUntilTimestamp: TimeInterval? = nil,
        onlyNotifyForMentions: Bool = false,
        markedAsUnread: Bool? = false,
        pinnedPriority: Int32? = nil,
        using dependencies: Dependencies = Dependencies()
    ) {
        self.id = id
        self.variant = variant
        self.creationDateTimestamp = (
            creationDateTimestamp ??
            TimeInterval(Double(SnodeAPI.currentOffsetTimestampMs(using: dependencies)) / 1000)
        )
        self.shouldBeVisible = shouldBeVisible
        self.messageDraft = messageDraft
        self.notificationSound = notificationSound
        self.mutedUntilTimestamp = mutedUntilTimestamp
        self.onlyNotifyForMentions = onlyNotifyForMentions
        self.markedAsUnread = markedAsUnread
        self.pinnedPriority = ((pinnedPriority ?? 0) > 0 ? pinnedPriority :
            (isPinned ? 1 : 0)
        )
    }
    
    // MARK: - Custom Database Interaction
    
    public func willInsert(_ db: Database) throws {
        db[.hasSavedThread] = true
    }
}

// MARK: - GRDB Interactions

public extension SessionThread {
    /// Fetches or creates a SessionThread with the specified id, variant and visible state
    ///
    /// **Notes:**
    /// - The `variant` will be ignored if an existing thread is found
    /// - This method **will** save the newly created SessionThread to the database
    @discardableResult static func fetchOrCreate(
        _ db: Database,
        id: ID,
        variant: Variant,
        shouldBeVisible: Bool?,
        calledFromConfigHandling: Bool,
        using dependencies: Dependencies = Dependencies()
    ) throws -> SessionThread {
        guard let existingThread: SessionThread = try? fetchOne(db, id: id) else {
            return try SessionThread(
                id: id,
                variant: variant,
                shouldBeVisible: (shouldBeVisible ?? false),
                using: dependencies
            ).upserted(db)
        }
        
        // If the `shouldBeVisible` state matches then we can finish early
        guard
            let desiredVisibility: Bool = shouldBeVisible,
            existingThread.shouldBeVisible != desiredVisibility
        else { return existingThread }
        
        // Update the `shouldBeVisible` state
        try SessionThread
            .filter(id: id)
            .updateAllAndConfig(
                db,
                SessionThread.Columns.shouldBeVisible.set(to: shouldBeVisible),
                calledFromConfigHandling: calledFromConfigHandling,
                using: dependencies
            )
        
        // Retrieve the updated thread and return it (we don't recursively call this method
        // just in case something weird happened and the above update didn't work, as that
        // would result in an infinite loop)
        return (try fetchOne(db, id: id))
            .defaulting(
                to: try SessionThread(
                    id: id,
                    variant: variant,
                    shouldBeVisible: desiredVisibility,
                    using: dependencies
                ).upserted(db)
            )
    }
    
    static func canSendReadReceipt(
        _ db: Database,
        threadId: String,
        threadVariant maybeThreadVariant: SessionThread.Variant? = nil,
        isBlocked maybeIsBlocked: Bool? = nil,
        isMessageRequest maybeIsMessageRequest: Bool? = nil
    ) throws -> Bool {
        let threadVariant: SessionThread.Variant = try {
            try maybeThreadVariant ??
            SessionThread
                .filter(id: threadId)
                .select(.variant)
                .asRequest(of: SessionThread.Variant.self)
                .fetchOne(db, orThrow: StorageError.objectNotFound)
        }()
        let threadIsBlocked: Bool = try {
            try maybeIsBlocked ??
            (
                threadVariant == .contact &&
                Contact
                    .filter(id: threadId)
                    .select(.isBlocked)
                    .asRequest(of: Bool.self)
                    .fetchOne(db, orThrow: StorageError.objectNotFound)
            )
        }()
        let threadIsMessageRequest: Bool = SessionThread
            .filter(id: threadId)
            .filter(
                SessionThread.isMessageRequest(
                    userSessionId: getUserSessionId(db),
                    includeNonVisible: true
                )
            )
            .isNotEmpty(db)
        
        return (
            !threadIsBlocked &&
            !threadIsMessageRequest
        )
    }
    
    @available(*, unavailable, message: "should not be used until pin re-ordering is built")
    static func refreshPinnedPriorities(_ db: Database, adding threadId: String) throws {
        struct PinnedPriority: TableRecord, ColumnExpressible {
            public typealias Columns = CodingKeys
            public enum CodingKeys: String, CodingKey, ColumnExpression {
                case id
                case rowIndex
            }
        }
        
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let pinnedPriority: TypedTableAlias<PinnedPriority> = TypedTableAlias()
        let rowIndexLiteral: SQL = SQL(stringLiteral: PinnedPriority.Columns.rowIndex.name)
        let pinnedPriorityLiteral: SQL = SQL(stringLiteral: SessionThread.Columns.pinnedPriority.name)
        
        try db.execute(literal: """
            WITH \(PinnedPriority.self) AS (
                SELECT
                    \(thread[.id]),
                    ROW_NUMBER() OVER (
                        ORDER BY \(SQL("\(thread[.id]) != \(threadId)")),
                        \(thread[.pinnedPriority]) ASC
                    ) AS \(rowIndexLiteral)
                FROM \(SessionThread.self)
                WHERE
                    \(thread[.pinnedPriority]) > 0 OR
                    \(SQL("\(thread[.id]) = \(threadId)"))
            )

            UPDATE \(SessionThread.self)
            SET \(pinnedPriorityLiteral) = (
                SELECT \(pinnedPriority[.rowIndex])
                FROM \(PinnedPriority.self)
                WHERE \(pinnedPriority[.id]) = \(thread[.id])
            )
        """)
    }
    
    static func deleteOrLeave(
        _ db: Database,
        threadId: String,
        threadVariant: Variant,
        groupLeaveType: ClosedGroup.LeaveType,
        calledFromConfigHandling: Bool,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        try deleteOrLeave(
            db,
            threadIds: [threadId],
            threadVariant: threadVariant,
            groupLeaveType: groupLeaveType,
            calledFromConfigHandling: calledFromConfigHandling,
            using: dependencies
        )
    }
    
    static func deleteOrLeave(
        _ db: Database,
        threadIds: [String],
        threadVariant: Variant,
        groupLeaveType: ClosedGroup.LeaveType,
        calledFromConfigHandling: Bool,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        let remainingThreadIds: Set<String> = threadIds.asSet().removing(userSessionId.hexString)
        
        switch (threadVariant, groupLeaveType) {
            case (.contact, .standard), (.contact, .silent):
                // Clear any interactions for the deleted thread
                _ = try Interaction
                    .filter(threadIds.contains(Interaction.Columns.threadId))
                    .deleteAll(db)
                
                // We need to custom handle the 'Note to Self' conversation (it should just be
                // hidden locally rather than deleted)
                if threadIds.contains(userSessionId.hexString) {
                    _ = try SessionThread
                        .filter(id: userSessionId.hexString)
                        .updateAllAndConfig(
                            db,
                            SessionThread.Columns.pinnedPriority.set(to: 0),
                            SessionThread.Columns.shouldBeVisible.set(to: false),
                            calledFromConfigHandling: calledFromConfigHandling,
                            using: dependencies
                        )
                }
                
                // Update any other threads to be hidden (don't want to actually delete the thread
                // record in case it's settings get changed while it's not visible)
                _ = try SessionThread
                    .filter(ids: remainingThreadIds)
                    .updateAllAndConfig(
                        db,
                        SessionThread.Columns.pinnedPriority.set(to: LibSession.hiddenPriority),
                        SessionThread.Columns.shouldBeVisible.set(to: false),
                        calledFromConfigHandling: calledFromConfigHandling,
                        using: dependencies
                    )
                
            case (.contact, .forced):
                // If this wasn't called from config handling then we need to hide the conversation
                if !calledFromConfigHandling {
                    try LibSession
                        .hide(db, contactIds: threadIds, using: dependencies)
                }
                
                _ = try SessionThread
                    .filter(ids: remainingThreadIds)
                    .deleteAll(db)
                
            case (.legacyGroup, .standard), (.group, .standard):
                try threadIds.forEach { threadId in
                    try MessageSender.leave(db, groupPublicKey: threadId, using: dependencies)
                }
                
            case (.legacyGroup, .silent), (.legacyGroup, .forced), (.group, .forced), (.group, .silent):
                try ClosedGroup.removeData(
                    db,
                    threadIds: threadIds,
                    dataToRemove: .allData,
                    calledFromConfigHandling: calledFromConfigHandling,
                    using: dependencies
                )
                
            case (.community, _):
                threadIds.forEach { threadId in
                    OpenGroupManager.shared.delete(
                        db,
                        openGroupId: threadId,
                        calledFromConfigHandling: calledFromConfigHandling,
                        using: dependencies
                    )
                }
        }
    }
}

// MARK: - Convenience

public extension SessionThread {
    static func isMessageRequest(
        _ db: Database,
        threadId: String,
        userSessionId: SessionId,
        includeNonVisible: Bool = false
    ) -> Bool {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        let request: SQLRequest<String> = """
            SELECT \(thread[.id])
            FROM \(SessionThread.self)
            LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])
            LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
            WHERE (
                \(thread[.id]) = \(threadId) AND
                \(SessionThread.isMessageRequest(userSessionId: userSessionId, includeNonVisible: includeNonVisible))
            )
        """
        
        return ((try? request.fetchOne(db)) != nil)
    }
    
    static func unreadMessageRequestsCountQuery(userSessionId: SessionId, includeNonVisible: Bool = false) -> SQLRequest<Int> {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        
        return """
            SELECT COUNT(DISTINCT id) FROM (
                SELECT \(thread[.id]) AS id
                FROM \(SessionThread.self)
                JOIN \(Interaction.self) ON (
                    \(interaction[.threadId]) = \(thread[.id]) AND
                    \(interaction[.wasRead]) = false
                )
                LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])
                LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
                WHERE (
                    \(SessionThread.isMessageRequest(userSessionId: userSessionId, includeNonVisible: includeNonVisible))
                )
            )
        """
    }
    
    /// This method can be used to filter a thread query to only include messages requests
    ///
    /// **Note:** In order to use this filter you **MUST** have a `joining(required/optional:)` to the
    /// `SessionThread.contact` association or it won't work
    static func isMessageRequest(
        userSessionId: SessionId,
        includeNonVisible: Bool = false
    ) -> SQLExpression {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        let shouldBeVisibleSQL: SQL = (includeNonVisible ?
            SQL(stringLiteral: "true") :
            SQL("\(thread[.shouldBeVisible]) = true")
        )
        
        return SQL(
            """
                \(shouldBeVisibleSQL) AND (
                    COALESCE(\(closedGroup[.invited]), false) = true OR (
                        \(SQL("\(thread[.variant]) = \(SessionThread.Variant.contact)")) AND
                        \(SQL("\(thread[.id]) != \(userSessionId.hexString)")) AND
                        IFNULL(\(contact[.isApproved]), false) = false
                    )
                )
            """
        ).sqlExpression
    }
    
    func isNoteToSelf(_ db: Database? = nil) -> Bool {
        return (
            variant == .contact &&
            id == getUserSessionId(db).hexString
        )
    }
    
    func shouldShowNotification(_ db: Database, for interaction: Interaction, isMessageRequest: Bool) -> Bool {
        // Ensure that the thread isn't muted and either the thread isn't only notifying for mentions
        // or the user was actually mentioned
        guard
            Date().timeIntervalSince1970 > (self.mutedUntilTimestamp ?? 0) &&
            (
                self.variant == .contact ||
                self.variant == .group ||
                !self.onlyNotifyForMentions ||
                interaction.hasMention
            )
        else { return false }
        
        let userSessionId: SessionId = getUserSessionId(db)
        
        // No need to notify the user for self-send messages
        guard interaction.authorId != userSessionId.hexString else { return false }
        
        // If the thread is a message request then we only want to notify for the first message
        if (self.variant == .contact || self.variant == .group) && isMessageRequest {
            let hasHiddenMessageRequests: Bool = db[.hasHiddenMessageRequests]
            
            /// If the user hasn't hidden the message requests section then only show the notification if all the other contact message request
            /// threads have been read, for group message requests we won't receive messages so should only ever trigger a single notification
            if !hasHiddenMessageRequests {
                let numUnreadMessageRequestThreads: Int = (try? SessionThread
                    .unreadMessageRequestsCountQuery(userSessionId: userSessionId, includeNonVisible: true)
                    .fetchOne(db))
                    .defaulting(to: 1)
                
                guard numUnreadMessageRequestThreads == 1 else { return false }
            }
            
            // We only want to show a notification for the first interaction in the thread
            guard ((try? self.interactions.fetchCount(db)) ?? 0) <= 1 else { return false }
            
            // Need to re-show the message requests section if it had been hidden
            if hasHiddenMessageRequests {
                db[.hasHiddenMessageRequests] = false
            }
        }
        
        return true
    }
    
    static func displayName(
        threadId: String,
        variant: Variant,
        closedGroupName: String? = nil,
        openGroupName: String? = nil,
        isNoteToSelf: Bool = false,
        profile: Profile? = nil
    ) -> String {
        switch variant {
            case .legacyGroup, .group: return (closedGroupName ?? "Unknown Group")
            case .community: return (openGroupName ?? "Unknown Community")
            case .contact:
                guard !isNoteToSelf else { return "NOTE_TO_SELF".localized() }
                guard let profile: Profile = profile else {
                    return Profile.truncated(id: threadId, truncating: .middle)
                }
                
                return profile.displayName()
        }
    }
    
    static func getCurrentUserBlindedSessionId(
        _ db: Database? = nil,
        threadId: String,
        threadVariant: Variant,
        blindingPrefix: SessionId.Prefix,
        using dependencies: Dependencies = Dependencies()
    ) -> SessionId? {
        guard threadVariant == .community else { return nil }
        guard let db: Database = db else {
            return dependencies[singleton: .storage].read { db in
                getCurrentUserBlindedSessionId(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    blindingPrefix: blindingPrefix,
                    using: dependencies
                )
            }
        }
        
        // Retrieve the relevant open group info
        struct OpenGroupInfo: Decodable, FetchableRecord {
            let publicKey: String
            let server: String
        }
        
        guard
            let userEdKeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db),
            let openGroupInfo: OpenGroupInfo = try? OpenGroup
                .filter(id: threadId)
                .select(.publicKey, .server)
                .asRequest(of: OpenGroupInfo.self)
                .fetchOne(db)
        else { return nil }
        
        // Check the capabilities to ensure the SOGS is blinded (or whether we have no capabilities)
        let capabilities: Set<Capability.Variant> = (try? Capability
            .select(.variant)
            .filter(Capability.Columns.openGroupServer == openGroupInfo.server.lowercased())
            .asRequest(of: Capability.Variant.self)
            .fetchSet(db))
            .defaulting(to: [])
        
        guard capabilities.isEmpty || capabilities.contains(.blind) else { return nil }
        
        switch blindingPrefix {
            case .blinded15:
                return dependencies[singleton: .crypto]
                    .generate(
                        .blinded15KeyPair(
                            serverPublicKey: openGroupInfo.publicKey,
                            ed25519SecretKey: userEdKeyPair.secretKey
                        )
                    )
                    .map { SessionId(.blinded15, publicKey: $0.publicKey) }
                
            case .blinded25:
                return dependencies[singleton: .crypto]
                    .generate(
                        .blinded25KeyPair(
                            serverPublicKey: openGroupInfo.publicKey,
                            ed25519SecretKey: userEdKeyPair.secretKey
                        )
                    )
                    .map { SessionId(.blinded25, publicKey: $0.publicKey) }
                
            default: return nil
        }
    }
}
