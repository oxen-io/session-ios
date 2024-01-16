// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

public struct Interaction: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "interaction" }
    internal static let threadForeignKey = ForeignKey([Columns.threadId], to: [SessionThread.Columns.id])
    internal static let linkPreviewForeignKey = ForeignKey(
        [Columns.linkPreviewUrl],
        to: [LinkPreview.Columns.url]
    )
    public static let thread = belongsTo(SessionThread.self, using: threadForeignKey)
    public static let profile = hasOne(Profile.self, using: Profile.interactionForeignKey)
    public static let interactionAttachments = hasMany(
        InteractionAttachment.self,
        using: InteractionAttachment.interactionForeignKey
    )
    public static let attachments = hasMany(
        Attachment.self,
        through: interactionAttachments,
        using: InteractionAttachment.attachment
    )
    public static let quote = hasOne(Quote.self, using: Quote.interactionForeignKey)
    
    /// Whenever using this `linkPreview` association make sure to filter the result using
    /// `.filter(literal: Interaction.linkPreviewFilterLiteral)` to ensure the correct LinkPreview is returned
    public static let linkPreview = hasOne(LinkPreview.self, using: LinkPreview.interactionForeignKey)
    public static func linkPreviewFilterLiteral(
        interaction: TypedTableAlias<Interaction> = TypedTableAlias(),
        linkPreview: TypedTableAlias<LinkPreview> = TypedTableAlias()
    ) -> SQL {
        let halfResolution: Double = LinkPreview.timstampResolution

        return "(\(interaction[.timestampMs]) BETWEEN (\(linkPreview[.timestamp]) - \(halfResolution)) * 1000 AND (\(linkPreview[.timestamp]) + \(halfResolution)) * 1000)" // stringlint:disable
    }
    public static let recipientStates = hasMany(RecipientState.self, using: RecipientState.interactionForeignKey)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case id
        case serverHash
        case messageUuid
        case threadId
        case authorId
        
        case variant
        case body
        case timestampMs
        case receivedAtTimestampMs
        case wasRead
        case hasMention
        
        case expiresInSeconds
        case expiresStartedAtMs
        case linkPreviewUrl
        
        // Open Group specific properties
        
        case openGroupServerMessageId
        case openGroupWhisperMods
        case openGroupWhisperTo
    }
    
    public enum Variant: Int, Codable, Hashable, DatabaseValueConvertible {
        case standardIncoming
        case standardOutgoing
        case standardIncomingDeleted
        
        // Info Message Types (spacing the values out to make it easier to extend)
        case infoLegacyGroupCreated = 1000
        case infoLegacyGroupUpdated
        case infoLegacyGroupCurrentUserLeft
        case infoGroupCurrentUserErrorLeaving
        case infoGroupCurrentUserLeaving
        case infoGroupInfoInvited
        case infoGroupInfoUpdated
        case infoGroupMembersUpdated
        
        case infoDisappearingMessagesUpdate = 2000
        
        case infoScreenshotNotification = 3000
        case infoMediaSavedNotification
        
        case infoMessageRequestAccepted = 4000
        
        case infoCall = 5000
        
        // MARK: - Convenience
        
        public static let variantsToIncrementUnreadCount: [Variant] = [
            .standardIncoming, .infoCall
        ]
        
        public var isInfoMessage: Bool {
            switch self {
                case .infoLegacyGroupCreated, .infoLegacyGroupUpdated, .infoLegacyGroupCurrentUserLeft,
                    .infoGroupCurrentUserLeaving, .infoGroupCurrentUserErrorLeaving,
                    .infoDisappearingMessagesUpdate, .infoScreenshotNotification, .infoMediaSavedNotification,
                    .infoMessageRequestAccepted, .infoCall, .infoGroupInfoInvited, .infoGroupInfoUpdated,
                    .infoGroupMembersUpdated:
                    return true
                    
                case .standardIncoming, .standardOutgoing, .standardIncomingDeleted:
                    return false
            }
        }
        
        public var isGroupControlMessage: Bool {
            switch self {
                case .infoLegacyGroupCreated, .infoLegacyGroupUpdated, .infoLegacyGroupCurrentUserLeft,
                    .infoGroupCurrentUserLeaving, .infoGroupCurrentUserErrorLeaving, .infoGroupInfoInvited,
                    .infoGroupInfoUpdated, .infoGroupMembersUpdated:
                    return true
                default:
                    return false
            }
        }
        
        public var isGroupLeavingStatus: Bool {
            switch self {
                case .infoLegacyGroupCurrentUserLeft, .infoGroupCurrentUserLeaving, .infoGroupCurrentUserErrorLeaving:
                    return true
                default:
                    return false
            }
        }
        
        /// This flag controls whether the `wasRead` flag is automatically set to true based on the message variant (as a result it they will
        /// or won't affect the unread count)
        fileprivate var canBeUnread: Bool {
            switch self {
                case .standardIncoming: return true
                case .infoCall: return true

                case .infoDisappearingMessagesUpdate, .infoScreenshotNotification,
                    .infoMediaSavedNotification, .infoGroupInfoInvited:
                    /// These won't be counted as unread messages but need to be able to be in an unread state so that they can disappear
                    /// after being read (if we don't do this their expiration timer will start immediately when received)
                    return true
                
                case .standardOutgoing, .standardIncomingDeleted: return false
                
                case .infoLegacyGroupCreated, .infoLegacyGroupUpdated, .infoLegacyGroupCurrentUserLeft,
                    .infoGroupCurrentUserLeaving, .infoGroupCurrentUserErrorLeaving,
                    .infoMessageRequestAccepted, .infoGroupInfoUpdated, .infoGroupMembersUpdated:
                    return false
            }
        }
        
        fileprivate var shouldFollowDisappearingMessagesConfiguration: Bool {
            switch self {
                case .standardIncoming, .standardOutgoing,
                    .infoCall,
                    .infoDisappearingMessagesUpdate,
                    .infoLegacyGroupCreated, .infoLegacyGroupUpdated, .infoLegacyGroupCurrentUserLeft,
                    .infoGroupCurrentUserLeaving, .infoGroupInfoInvited, .infoGroupInfoUpdated,
                    .infoGroupMembersUpdated, .infoScreenshotNotification, .infoMediaSavedNotification:
                    return true
                
                default: return false
            }
        }
    }
    
    /// The `id` value is auto incremented by the database, if the `Interaction` hasn't been inserted into
    /// the database yet this value will be `nil`
    public private(set) var id: Int64? = nil
    
    /// The hash returned by the server when this message was created on the server
    ///
    /// **Notes:**
    /// - This will only be populated for `standardIncoming`/`standardOutgoing` interactions from
    /// either `contact` or `closedGroup` threads
    /// - This value will differ for "sync" messages (messages we resend to the current to ensure it appears
    /// on all linked devices) because the data in the message is slightly different
    public let serverHash: String?
    
    /// The UUID specified when sending the message to allow for custom updating and de-duping behaviours
    ///
    /// **Note:** Currently only `infoCall` messages utilise this value
    public let messageUuid: String?
    
    /// The id of the thread that this interaction belongs to (used to expose the `thread` variable)
    public let threadId: String
    
    /// The id of the user who sent the interaction, also used to expose the `profile` variable)
    ///
    /// **Note:** For any "info" messages this value will always be the current user public key (this is because these
    /// messages are created locally based on control messages and the initiator of a control message doesn't always
    /// get transmitted)
    public let authorId: String
    
    /// The type of interaction
    public let variant: Variant
    
    /// The body of this interaction
    public let body: String?
    
    /// When the interaction was created in milliseconds since epoch
    ///
    /// **Notes:**
    /// - This value will be `0` if it hasn't been set yet
    /// - The code sorts messages using this value
    /// - This value will ber overwritten by the `serverTimestamp` for open group messages
    public let timestampMs: Int64
    
    /// When the interaction was received in milliseconds since epoch
    ///
    /// **Note:** This value will be `0` if it hasn't been set yet
    public let receivedAtTimestampMs: Int64
    
    /// A flag indicating whether the interaction has been read (this is a flag rather than a timestamp because
    /// we couldn’t know if a read timestamp is accurate)
    ///
    /// This flag is used:
    ///  - In conjunction with `Interaction.variantsToIncrementUnreadCount` to determine the unread count for a thread
    ///  - In order to determine whether the "Disappear After Read" expiration type should be started
    ///
    /// **Note:** This flag is not applicable to standardOutgoing or standardIncomingDeleted interactions
    public private(set) var wasRead: Bool
    
    /// A flag indicating whether the current user was mentioned in this interaction (or the associated quote)
    public let hasMention: Bool
    
    /// The number of seconds until this message should expire
    public private(set) var expiresInSeconds: TimeInterval?
    
    /// The timestamp in milliseconds since 1970 at which this messages expiration timer started counting
    /// down (this is stored in order to allow the `expiresInSeconds` value to be updated before a
    /// message has expired)
    public private(set) var expiresStartedAtMs: Double?
    
    /// This value is the url for the link preview for this interaction
    ///
    /// **Note:** This is also used for open group invitations
    public let linkPreviewUrl: String?
    
    // Open Group specific properties
    
    /// The `openGroupServerMessageId` value will only be set for messages from SOGS
    public let openGroupServerMessageId: Int64?
    
    /// This flag indicates whether this interaction is a whisper to the mods of an Open Group
    public let openGroupWhisperMods: Bool
    
    /// This value is the id of the user within an Open Group who is the target of this whisper interaction
    public let openGroupWhisperTo: String?
    
    // MARK: - Relationships
         
    public var thread: QueryInterfaceRequest<SessionThread> {
        request(for: Interaction.thread)
    }
    
    public var profile: QueryInterfaceRequest<Profile> {
        request(for: Interaction.profile)
    }
    
    /// Depending on the data associated to this interaction this array will represent different things, these
    /// cases are mutually exclusive:
    ///
    /// **Quote:** The thumbnails associated to the `Quote`
    /// **LinkPreview:** The thumbnails associated to the `LinkPreview`
    /// **Other:** The files directly attached to the interaction
    public var attachments: QueryInterfaceRequest<Attachment> {
        let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
        
        return request(for: Interaction.attachments)
            .order(interactionAttachment[.albumIndex])
    }

    public var quote: QueryInterfaceRequest<Quote> {
        request(for: Interaction.quote)
    }

    public var linkPreview: QueryInterfaceRequest<LinkPreview> {
        /// **Note:** This equation **MUST** match the `linkPreviewFilterLiteral` logic
        let halfResolution: Double = LinkPreview.timstampResolution
        
        return request(for: Interaction.linkPreview)
            .filter(
                (timestampMs >= (LinkPreview.Columns.timestamp - halfResolution) * 1000) &&
                (timestampMs <= (LinkPreview.Columns.timestamp + halfResolution) * 1000)
            )
    }
    
    public var recipientStates: QueryInterfaceRequest<RecipientState> {
        request(for: Interaction.recipientStates)
    }
    
    // MARK: - Initialization
    
    internal init(
        id: Int64? = nil,
        serverHash: String?,
        messageUuid: String?,
        threadId: String,
        authorId: String,
        variant: Variant,
        body: String?,
        timestampMs: Int64,
        receivedAtTimestampMs: Int64,
        wasRead: Bool,
        hasMention: Bool,
        expiresInSeconds: TimeInterval?,
        expiresStartedAtMs: Double?,
        linkPreviewUrl: String?,
        openGroupServerMessageId: Int64?,
        openGroupWhisperMods: Bool,
        openGroupWhisperTo: String?
    ) {
        self.id = id
        self.serverHash = serverHash
        self.messageUuid = messageUuid
        self.threadId = threadId
        self.authorId = authorId
        self.variant = variant
        self.body = body
        self.timestampMs = timestampMs
        self.receivedAtTimestampMs = receivedAtTimestampMs
        self.wasRead = (wasRead || !variant.canBeUnread)
        self.hasMention = hasMention
        self.expiresInSeconds = expiresInSeconds
        self.expiresStartedAtMs = expiresStartedAtMs
        self.linkPreviewUrl = linkPreviewUrl
        self.openGroupServerMessageId = openGroupServerMessageId
        self.openGroupWhisperMods = openGroupWhisperMods
        self.openGroupWhisperTo = openGroupWhisperTo
    }
    
    public init(
        serverHash: String? = nil,
        messageUuid: String? = nil,
        threadId: String,
        authorId: String,
        variant: Variant,
        body: String? = nil,
        timestampMs: Int64 = 0,
        wasRead: Bool = false,
        hasMention: Bool = false,
        expiresInSeconds: TimeInterval? = nil,
        expiresStartedAtMs: Double? = nil,
        linkPreviewUrl: String? = nil,
        openGroupServerMessageId: Int64? = nil,
        openGroupWhisperMods: Bool = false,
        openGroupWhisperTo: String? = nil
    ) {
        self.serverHash = serverHash
        self.messageUuid = messageUuid
        self.threadId = threadId
        self.authorId = authorId
        self.variant = variant
        self.body = body
        self.timestampMs = timestampMs
        self.receivedAtTimestampMs = {
            switch variant {
                case .standardIncoming, .standardOutgoing: return SnodeAPI.currentOffsetTimestampMs()

                /// For TSInteractions which are not `standardIncoming` and `standardOutgoing` use the `timestampMs` value
                default: return timestampMs
            }
        }()
        self.wasRead = (wasRead || !variant.canBeUnread)
        self.hasMention = hasMention
        self.expiresInSeconds = expiresInSeconds
        self.expiresStartedAtMs = expiresStartedAtMs
        self.linkPreviewUrl = linkPreviewUrl
        self.openGroupServerMessageId = openGroupServerMessageId
        self.openGroupWhisperMods = openGroupWhisperMods
        self.openGroupWhisperTo = openGroupWhisperTo
    }
    
    // MARK: - Custom Database Interaction
    
    public mutating func willInsert(_ db: Database) throws {
        // Automatically mark interactions which can't be unread as read so the unread count
        // isn't impacted
        self.wasRead = (self.wasRead || !self.variant.canBeUnread)
        
        // Automatically add disapeparing messages configuration
        if self.variant.shouldFollowDisappearingMessagesConfiguration,
           self.expiresInSeconds == nil,
           self.expiresStartedAtMs == nil
        {
            guard
                let disappearingMessagesConfiguration = try? DisappearingMessagesConfiguration.fetchOne(db, id: self.threadId),
                disappearingMessagesConfiguration.isEnabled
            else {
                self.expiresInSeconds = 0
                return
            }
            
            self.expiresInSeconds = disappearingMessagesConfiguration.durationSeconds
        }
    }
    
    public func aroundInsert(_ db: Database, insert: () throws -> InsertionSuccess) throws {
        let success: InsertionSuccess = try insert()
        
        guard
            let threadVariant: SessionThread.Variant = try? SessionThread
                .filter(id: threadId)
                .select(.variant)
                .asRequest(of: SessionThread.Variant.self)
                .fetchOne(db)
        else {
            SNLog("Inserted an interaction but couldn't find it's associated thead")
            return
        }
        
        switch variant {
            case .standardOutgoing:
                // New outgoing messages should immediately determine their recipient list
                // from current thread state
                switch threadVariant {
                    case .contact:
                        try RecipientState(
                            interactionId: success.rowID,
                            recipientId: threadId,  // Will be the contact id
                            state: .sending
                        ).insert(db)
                        
                    case .legacyGroup, .group:
                        let closedGroupMemberIds: Set<String> = (try? GroupMember
                            .select(.profileId)
                            .filter(GroupMember.Columns.groupId == threadId)
                            .asRequest(of: String.self)
                            .fetchSet(db))
                            .defaulting(to: [])
                        
                        guard !closedGroupMemberIds.isEmpty else {
                            SNLog("Inserted an interaction but couldn't find it's associated thread members")
                            return
                        }
                        
                        // Exclude the current user when creating recipient states (as they will never
                        // receive the message resulting in the message getting flagged as failed)
                        let userSessionId: SessionId = getUserSessionId(db)
                        try closedGroupMemberIds
                            .filter { memberId -> Bool in memberId != userSessionId.hexString }
                            .forEach { memberId in
                                try RecipientState(
                                    interactionId: success.rowID,
                                    recipientId: memberId,
                                    state: .sending
                                ).insert(db)
                            }
                        
                    case .community:
                        // Since we use the 'RecipientState' type to manage the message state
                        // we need to ensure we have a state for all threads; so for open groups
                        // we just use the open group id as the 'recipientId' value
                        try RecipientState(
                            interactionId: success.rowID,
                            recipientId: threadId,  // Will be the open group id
                            state: .sending
                        ).insert(db)
                }
                
            default: break
        }
        
        // Start the disappearing messages timer if needed
        if self.expiresStartedAtMs != nil {
            Dependencies()[singleton: .jobRunner].upsert(
                db,
                job: DisappearingMessagesJob.updateNextRunIfNeeded(db),
                canStartJob: true,
                using: Dependencies()
            )
        }
    }
    
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        self.id = inserted.rowID
    }
}

// MARK: - Mutation

public extension Interaction {
    func with(
        serverHash: String? = nil,
        authorId: String? = nil,
        body: String? = nil,
        timestampMs: Int64? = nil,
        wasRead: Bool? = nil,
        hasMention: Bool? = nil,
        expiresInSeconds: TimeInterval? = nil,
        expiresStartedAtMs: Double? = nil,
        openGroupServerMessageId: Int64? = nil
    ) -> Interaction {
        return Interaction(
            id: self.id,
            serverHash: (serverHash ?? self.serverHash),
            messageUuid: self.messageUuid,
            threadId: self.threadId,
            authorId: (authorId ?? self.authorId),
            variant: self.variant,
            body: (body ?? self.body),
            timestampMs: (timestampMs ?? self.timestampMs),
            receivedAtTimestampMs: self.receivedAtTimestampMs,
            wasRead: ((wasRead ?? self.wasRead) || !self.variant.canBeUnread),
            hasMention: (hasMention ?? self.hasMention),
            expiresInSeconds: (expiresInSeconds ?? self.expiresInSeconds),
            expiresStartedAtMs: (expiresStartedAtMs ?? self.expiresStartedAtMs),
            linkPreviewUrl: self.linkPreviewUrl,
            openGroupServerMessageId: (openGroupServerMessageId ?? self.openGroupServerMessageId),
            openGroupWhisperMods: self.openGroupWhisperMods,
            openGroupWhisperTo: self.openGroupWhisperTo
        )
    }
}

// MARK: - GRDB Interactions

public extension Interaction {
    struct ReadInfo: Decodable, FetchableRecord {
        let id: Int64
        let variant: Interaction.Variant
        let timestampMs: Int64
        let wasRead: Bool
    }
    
    static func fetchUnreadCount(
        _ db: Database,
        using dependencies: Dependencies = Dependencies()
    ) throws -> Int {
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        
        return try Interaction
            .filter(Interaction.Columns.wasRead == false)
            .filter(Interaction.Variant.variantsToIncrementUnreadCount.contains(Interaction.Columns.variant))
            .filter(
                // Only count mentions if 'onlyNotifyForMentions' is set
                thread[.onlyNotifyForMentions] == false ||
                Interaction.Columns.hasMention == true
            )
            .joining(
                required: Interaction.thread
                    .aliased(thread)
                    .joining(optional: SessionThread.contact)
                    .filter(
                        // Ignore muted threads
                        SessionThread.Columns.mutedUntilTimestamp == nil ||
                        SessionThread.Columns.mutedUntilTimestamp < dependencies.dateNow.timeIntervalSince1970
                    )
                    .filter(
                        // Ignore message request threads
                        SessionThread.Columns.variant != SessionThread.Variant.contact ||
                        !SessionThread.isMessageRequest(userSessionId: userSessionId)
                    )
            )
            .fetchCount(db)
    }
    
    /// This will update the `wasRead` state the the interaction
    ///
    /// - Parameters
    ///   - interactionId: The id of the specific interaction to mark as read
    ///   - threadId: The id of the thread the interaction belongs to
    ///   - includingOlder: Setting this to `true` will updated the `wasRead` flag for all older interactions as well
    ///   - trySendReadReceipt: Setting this to `true` will schedule a `ReadReceiptJob`
    static func markAsRead(
        _ db: Database,
        interactionId: Int64?,
        threadId: String,
        threadVariant: SessionThread.Variant,
        includingOlder: Bool,
        trySendReadReceipt: Bool,
        using dependencies: Dependencies
    ) throws {
        guard let interactionId: Int64 = interactionId else { return }
        
        // Since there is no guarantee on the order messages are inserted into the database
        // fetch the timestamp for the interaction and set everything before that as read
        let maybeInteractionInfo: Interaction.ReadInfo? = try Interaction
            .select(.id, .variant, .timestampMs, .wasRead)
            .filter(id: interactionId)
            .asRequest(of: Interaction.ReadInfo.self)
            .fetchOne(db)
        
        // If we aren't including older interactions then update and save the current one
        guard includingOlder, let interactionInfo: Interaction.ReadInfo = maybeInteractionInfo else {
            // Only mark as read and trigger the subsequent jobs if the interaction is
            // actually not read (no point updating and triggering db changes otherwise)
            guard
                maybeInteractionInfo?.wasRead == false,
                let timestampMs: Int64 = maybeInteractionInfo?.timestampMs,
                let variant: Variant = try Interaction
                    .filter(id: interactionId)
                    .select(.variant)
                    .asRequest(of: Variant.self)
                    .fetchOne(db)
            else { return }
            
            _ = try Interaction
                .filter(id: interactionId)
                .updateAll(db, Columns.wasRead.set(to: true))
            
            try Interaction.scheduleReadJobs(
                db,
                threadId: threadId,
                threadVariant: threadVariant,
                interactionInfo: [
                    Interaction.ReadInfo(
                        id: interactionId,
                        variant: variant,
                        timestampMs: 0,
                        wasRead: false
                    )
                ],
                lastReadTimestampMs: timestampMs,
                trySendReadReceipt: trySendReadReceipt,
                calledFromConfigHandling: false,
                using: dependencies
            )
            return
        }
        
        let interactionQuery = Interaction
            .filter(Interaction.Columns.threadId == threadId)
            .filter(Interaction.Columns.timestampMs <= interactionInfo.timestampMs)
            .filter(Interaction.Columns.wasRead == false)
        let interactionInfoToMarkAsRead: [Interaction.ReadInfo] = try interactionQuery
            .select(.id, .variant, .timestampMs, .wasRead)
            .asRequest(of: Interaction.ReadInfo.self)
            .fetchAll(db)
        
        // If there are no other interactions to mark as read then just schedule the jobs
        // for this interaction (need to ensure the disapeparing messages run for sync'ed
        // outgoing messages which will always have 'wasRead' as false)
        guard !interactionInfoToMarkAsRead.isEmpty else {
            try Interaction.scheduleReadJobs(
                db,
                threadId: threadId,
                threadVariant: threadVariant,
                interactionInfo: [interactionInfo],
                lastReadTimestampMs: interactionInfo.timestampMs,
                trySendReadReceipt: trySendReadReceipt,
                calledFromConfigHandling: false,
                using: dependencies
            )
            return
        }
        
        // Update the `wasRead` flag to true
        try interactionQuery.updateAll(db, Columns.wasRead.set(to: true))
        
        // Retrieve the interaction ids we want to update
        try Interaction.scheduleReadJobs(
            db,
            threadId: threadId,
            threadVariant: threadVariant,
            interactionInfo: interactionInfoToMarkAsRead,
            lastReadTimestampMs: interactionInfo.timestampMs,
            trySendReadReceipt: trySendReadReceipt,
            calledFromConfigHandling: false,
            using: dependencies
        )
    }
    
    /// This method flags sent messages as read for the specified recipients
    ///
    /// **Note:** This method won't update the 'wasRead' flag (it will be updated via the above method)
    @discardableResult static func markAsRead(
        _ db: Database,
        recipientId: String,
        timestampMsValues: [Int64],
        readTimestampMs: Int64
    ) throws -> Set<Int64> {
        guard db[.areReadReceiptsEnabled] == true else { return [] }
        
        // Update the read state
        let rowIds: [Int64] = try RecipientState
            .select(Column.rowID)
            .filter(RecipientState.Columns.recipientId == recipientId)
            .joining(
                required: RecipientState.interaction
                    .filter(timestampMsValues.contains(Columns.timestampMs))
                    .filter(Columns.variant == Variant.standardOutgoing)
            )
            .asRequest(of: Int64.self)
            .fetchAll(db)
        
        // If there were no 'rowIds' then no need to run the below queries, all of the timestamps
        // and for pending read receipts
        guard !rowIds.isEmpty else { return timestampMsValues.asSet() }
        
        // Update the 'readTimestampMs' if it doesn't match (need to do this to prevent
        // the UI update from being triggered for a redundant update)
        try RecipientState
            .filter(rowIds.contains(Column.rowID))
            .filter(RecipientState.Columns.readTimestampMs == nil)
            .updateAll(
                db,
                RecipientState.Columns.readTimestampMs.set(to: readTimestampMs)
            )
        
        // If the message still appeared to be sending then mark it as sent
        try RecipientState
            .filter(rowIds.contains(Column.rowID))
            .filter(RecipientState.Columns.state == RecipientState.State.sending)
            .updateAll(
                db,
                RecipientState.Columns.state.set(to: RecipientState.State.sent)
            )
        
        // Retrieve the set of timestamps which were updated
        let timestampsUpdated: Set<Int64> = try Interaction
            .select(Columns.timestampMs)
            .filter(timestampMsValues.contains(Columns.timestampMs))
            .filter(Columns.variant == Variant.standardOutgoing)
            .joining(
                required: Interaction.recipientStates
                    .filter(rowIds.contains(Column.rowID))
            )
            .asRequest(of: Int64.self)
            .fetchSet(db)
        
        // Return the timestamps which weren't updated
        return timestampMsValues
            .asSet()
            .subtracting(timestampsUpdated)
    }
    
    static func scheduleReadJobs(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        interactionInfo: [Interaction.ReadInfo],
        lastReadTimestampMs: Int64,
        trySendReadReceipt: Bool,
        calledFromConfigHandling: Bool,
        using dependencies: Dependencies
    ) throws {
        guard !interactionInfo.isEmpty else { return }
        
        // Update the last read timestamp if needed
        if !calledFromConfigHandling {
            try LibSession.syncThreadLastReadIfNeeded(
                db,
                threadId: threadId,
                threadVariant: threadVariant,
                lastReadTimestampMs: lastReadTimestampMs,
                using: dependencies
            )

            // Add the 'DisappearingMessagesJob' if needed - this will update any expiring
            // messages `expiresStartedAtMs` values
            dependencies[singleton: .jobRunner].upsert(
                db,
                job: DisappearingMessagesJob.updateNextRunIfNeeded(
                    db,
                    interactionIds: interactionInfo.map { $0.id },
                    startedAtMs: Double(SnodeAPI.currentOffsetTimestampMs(using: dependencies)),
                    threadId: threadId,
                    using: dependencies
                ),
                canStartJob: true,
                using: dependencies
            )
        }
        else {
            // Update old disappearing after read messages to start
            DisappearingMessagesJob.updateNextRunIfNeeded(
                db,
                lastReadTimestampMs: lastReadTimestampMs,
                threadId: threadId,
                using: dependencies
            )
        }
        
        // Clear out any notifications for the interactions we mark as read
        dependencies[singleton: .notificationsManager].cancelNotifications(
            identifiers: interactionInfo
                .map { interactionInfo in
                    Interaction.notificationIdentifier(
                        for: interactionInfo.id,
                        threadId: threadId,
                        shouldGroupMessagesForThread: false
                    )
                }
                .appending(Interaction.notificationIdentifier(
                    for: 0,
                    threadId: threadId,
                    shouldGroupMessagesForThread: true
                ))
        )
        
        /// If we want to send read receipts and it's a contact thread then try to add the `SendReadReceiptsJob` for and unread
        /// messages that weren't outgoing
        if trySendReadReceipt && threadVariant == .contact {
            dependencies[singleton: .jobRunner].upsert(
                db,
                job: SendReadReceiptsJob.createOrUpdateIfNeeded(
                    db,
                    threadId: threadId,
                    interactionIds: interactionInfo
                        .filter { !$0.wasRead && $0.variant != .standardOutgoing }
                        .map { $0.id },
                    using: dependencies
                ),
                canStartJob: true,
                using: dependencies
            )
        }
    }
}

// MARK: - Search Queries

public extension Interaction {
    struct FullTextSearch: Decodable, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case threadId
            case body
        }
        
        let threadId: String
        let body: String
    }
    
    struct TimestampInfo: FetchableRecord, Codable {
        public let id: Int64
        public let timestampMs: Int64
        
        public init(
            id: Int64,
            timestampMs: Int64
        ) {
            self.id = id
            self.timestampMs = timestampMs
        }
    }
    
    static func idsForTermWithin(threadId: String, pattern: FTS5Pattern) -> SQLRequest<TimestampInfo> {
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        let interactionFullTextSearch: TypedTableAlias<FullTextSearch> = TypedTableAlias(name: Interaction.fullTextSearchTableName)
        
        let request: SQLRequest<TimestampInfo> = """
            SELECT
                \(interaction[.id]),
                \(interaction[.timestampMs])
            FROM \(Interaction.self)
            JOIN \(interactionFullTextSearch) ON (
                \(interactionFullTextSearch[.rowId]) = \(interaction[.rowId]) AND
                \(SQL("\(interactionFullTextSearch[.threadId]) = \(threadId)")) AND
                \(interactionFullTextSearch[.body]) MATCH \(pattern)
            )
        
            ORDER BY \(interaction[.timestampMs].desc)
        """
        
        return request
    }
}

// MARK: - Convenience

public extension Interaction {
    static let oversizeTextMessageSizeThreshold: UInt = (2 * 1024)
    
    // MARK: - Variables
    
    var isExpiringMessage: Bool {
        guard variant.shouldFollowDisappearingMessagesConfiguration else { return false }
        
        return (expiresInSeconds ?? 0 > 0)
    }
    
    var openGroupWhisper: Bool { return (openGroupWhisperMods || (openGroupWhisperTo != nil)) }
    
    var notificationIdentifiers: [String] {
        [
            notificationIdentifier(shouldGroupMessagesForThread: true),
            notificationIdentifier(shouldGroupMessagesForThread: false)
        ]
    }
    
    // MARK: - Functions
    
    func notificationIdentifier(shouldGroupMessagesForThread: Bool) -> String {
        // When the app is in the background we want the notifications to be grouped to prevent spam
        return Interaction.notificationIdentifier(
            for: (id ?? 0),
            threadId: threadId,
            shouldGroupMessagesForThread: shouldGroupMessagesForThread
        )
    }
    
    fileprivate static func notificationIdentifier(for id: Int64, threadId: String, shouldGroupMessagesForThread: Bool) -> String {
        // When the app is in the background we want the notifications to be grouped to prevent spam
        guard !shouldGroupMessagesForThread else { return threadId }
        
        return "\(threadId)-\(id)"
    }
    
    func markingAsDeleted() -> Interaction {
        return Interaction(
            id: id,
            serverHash: nil,
            messageUuid: messageUuid,
            threadId: threadId,
            authorId: authorId,
            variant: .standardIncomingDeleted,
            body: nil,
            timestampMs: timestampMs,
            receivedAtTimestampMs: receivedAtTimestampMs,
            wasRead: (wasRead || !Variant.standardIncomingDeleted.canBeUnread),
            hasMention: false,
            expiresInSeconds: expiresInSeconds,
            expiresStartedAtMs: expiresStartedAtMs,
            linkPreviewUrl: nil,
            openGroupServerMessageId: openGroupServerMessageId,
            openGroupWhisperMods: openGroupWhisperMods,
            openGroupWhisperTo: openGroupWhisperTo
        )
    }
    
    static func isUserMentioned(
        _ db: Database,
        threadId: String,
        body: String?,
        quoteAuthorId: String? = nil,
        using dependencies: Dependencies = Dependencies()
    ) -> Bool {
        var publicKeysToCheck: [String] = [
            getUserSessionId(db, using: dependencies).hexString
        ]
        
        // If the thread is an open group then add the blinded id as a key to check
        if let openGroup: OpenGroup = try? OpenGroup.fetchOne(db, id: threadId) {
            if
                let userEd25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db),
                let blinded15KeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                    .blinded15KeyPair(serverPublicKey: openGroup.publicKey, ed25519SecretKey: userEd25519KeyPair.secretKey)
                ),
                let blinded25KeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                    .blinded25KeyPair(serverPublicKey: openGroup.publicKey, ed25519SecretKey: userEd25519KeyPair.secretKey)
                )
            {
                publicKeysToCheck.append(SessionId(.blinded15, publicKey: blinded15KeyPair.publicKey).hexString)
                publicKeysToCheck.append(SessionId(.blinded25, publicKey: blinded25KeyPair.publicKey).hexString)
            }
        }
        
        return isUserMentioned(
            publicKeysToCheck: publicKeysToCheck,
            body: body,
            quoteAuthorId: quoteAuthorId
        )
    }
        
    static func isUserMentioned(
        publicKeysToCheck: [String],
        body: String?,
        quoteAuthorId: String? = nil
    ) -> Bool {
        // A user is mentioned if their public key is in the body of a message or one of their messages
        // was quoted
        return publicKeysToCheck.contains { publicKey in
            (
                body != nil &&
                (body ?? "").contains("@\(publicKey)")
            ) || (
                quoteAuthorId == publicKey
            )
        }
    }
    
    /// Use the `Interaction.previewText` method directly where possible rather than this method as it
    /// makes it's own database queries
    func previewText(_ db: Database, using dependencies: Dependencies) -> String {
        switch variant {
            case .standardIncoming, .standardOutgoing:
                return Interaction.previewText(
                    variant: self.variant,
                    body: self.body,
                    attachmentDescriptionInfo: try? attachments
                        .select(.id, .variant, .contentType, .sourceFilename)
                        .asRequest(of: Attachment.DescriptionInfo.self)
                        .fetchOne(db),
                    attachmentCount: try? attachments.fetchCount(db),
                    isOpenGroupInvitation: linkPreview
                        .filter(LinkPreview.Columns.variant == LinkPreview.Variant.openGroupInvitation)
                        .isNotEmpty(db),
                    using: dependencies
                )

            case .infoMediaSavedNotification, .infoScreenshotNotification, .infoCall:
                // Note: These should only occur in 'contact' threads so the `threadId`
                // is the contact id
                return Interaction.previewText(
                    variant: self.variant,
                    body: self.body,
                    authorDisplayName: Profile.displayName(db, id: threadId),
                    using: dependencies
                )

            default: return Interaction.previewText(
                variant: self.variant,
                body: self.body,
                using: dependencies
            )
        }
    }
    
    /// This menthod generates the preview text for a given transaction
    static func previewText(
        variant: Variant,
        body: String?,
        threadContactDisplayName: String = "",
        authorDisplayName: String = "",
        attachmentDescriptionInfo: Attachment.DescriptionInfo? = nil,
        attachmentCount: Int? = nil,
        isOpenGroupInvitation: Bool = false,
        using dependencies: Dependencies
    ) -> String {
        return attributedPreviewText(
            variant: variant,
            body: body,
            threadContactDisplayName: threadContactDisplayName,
            authorDisplayName: authorDisplayName,
            attachmentDescriptionInfo: attachmentDescriptionInfo,
            attachmentCount: attachmentCount,
            isOpenGroupInvitation: isOpenGroupInvitation,
            using: dependencies
        ).string
    }
    
    static func attributedPreviewText(
        variant: Variant,
        body: String?,
        threadContactDisplayName: String = "",
        authorDisplayName: String = "",
        attachmentDescriptionInfo: Attachment.DescriptionInfo? = nil,
        attachmentCount: Int? = nil,
        isOpenGroupInvitation: Bool = false,
        using dependencies: Dependencies
    ) -> NSAttributedString {
        switch variant {
            case .standardIncomingDeleted: return NSAttributedString(string: "")
                
            case .standardIncoming, .standardOutgoing:
                let attachmentDescription: String? = Attachment.description(
                    for: attachmentDescriptionInfo,
                    count: attachmentCount
                )
                
                if
                    let attachmentDescription: String = attachmentDescription,
                    let body: String = body,
                    !attachmentDescription.isEmpty,
                    !body.isEmpty
                {
                    if Dependencies.isRTL {
                        return NSAttributedString(string: "\(body): \(attachmentDescription)")
                    }
                    
                    return NSAttributedString(string: "\(attachmentDescription): \(body)")
                }
                
                if let body: String = body, !body.isEmpty {
                    return NSAttributedString(string: body)
                }
                
                if let attachmentDescription: String = attachmentDescription, !attachmentDescription.isEmpty {
                    return NSAttributedString(string: attachmentDescription)
                }
                
                if isOpenGroupInvitation {
                    return NSAttributedString(string: "😎 Open group invitation")
                }
                
                // TODO: We should do better here
                return NSAttributedString(string: "")
                
            case .infoMediaSavedNotification:
                // TODO: Use referencedAttachmentTimestamp to tell the user * which * media was saved
                return NSAttributedString(string: String(format: "media_saved".localized(), authorDisplayName))
                
            case .infoScreenshotNotification:
                return NSAttributedString(string: String(format: "screenshot_taken".localized(), authorDisplayName))
                
            case .infoLegacyGroupCreated:
                return NSAttributedString(string: "GROUP_CREATED".localized())
                
            case .infoLegacyGroupCurrentUserLeft:
                return NSAttributedString(string: "GROUP_YOU_LEFT".localized())
                
            case .infoGroupCurrentUserLeaving:
                return NSAttributedString(string: "group_you_leaving".localized())
                
            case .infoGroupCurrentUserErrorLeaving:
                return NSAttributedString(string: "group_unable_to_leave".localized())
                
            case .infoLegacyGroupUpdated:
                return NSAttributedString(string: (body ?? "GROUP_UPDATED".localized()))
                
            case .infoMessageRequestAccepted:
                return NSAttributedString(string: (body ?? "MESSAGE_REQUESTS_ACCEPTED".localized()))
                
            case .infoGroupInfoInvited, .infoGroupInfoUpdated, .infoGroupMembersUpdated:
                guard
                    let infoMessageData: Data = (body ?? "").data(using: .utf8),
                    let messageInfo: ClosedGroup.MessageInfo = try? JSONDecoder().decode(
                        ClosedGroup.MessageInfo.self,
                        from: infoMessageData
                    )
                else { return NSAttributedString(string: (body ?? "")) }
                
                return messageInfo.attributedPreviewText
            
            case .infoDisappearingMessagesUpdate:
                guard
                    let infoMessageData: Data = (body ?? "").data(using: .utf8),
                    let messageInfo: DisappearingMessagesConfiguration.MessageInfo = try? JSONDecoder().decode(
                        DisappearingMessagesConfiguration.MessageInfo.self,
                        from: infoMessageData
                    )
                else { return NSAttributedString(string: (body ?? "")) }
                
                return messageInfo.attributedPreviewText(using: dependencies)
                
            case .infoCall:
                guard
                    let infoMessageData: Data = (body ?? "").data(using: .utf8),
                    let messageInfo: CallMessage.MessageInfo = try? JSONDecoder().decode(
                        CallMessage.MessageInfo.self,
                        from: infoMessageData
                    )
                else { return NSAttributedString(string: (body ?? "")) }
                
                return NSAttributedString(
                    string: messageInfo.previewText(threadContactDisplayName: threadContactDisplayName)
                )
        }
    }
    
    func state(_ db: Database) throws -> RecipientState.State {
        let states: [RecipientState.State] = try RecipientState.State
            .fetchAll(
                db,
                recipientStates.select(.state)
            )
        
        return Interaction.state(for: states)
    }
    
    static func state(for states: [RecipientState.State]) -> RecipientState.State {
        // If there are no states then assume this is a new interaction which hasn't been
        // saved yet so has no states
        guard !states.isEmpty else { return .sending }
        
        var hasFailed: Bool = false
        
        for state in states {
            switch state {
                // If there are any "sending" recipients, consider this message "sending"
                case .sending: return .sending
                    
                case .failed:
                    hasFailed = true
                    break
                    
                default: break
            }
        }
        
        // If there are any "failed" recipients, consider this message "failed"
        guard !hasFailed else { return .failed }
        
        // Otherwise, consider the message "sent"
        //
        // Note: This includes messages with no recipients
        return .sent
    }
}
