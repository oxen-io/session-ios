// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

internal extension LibSession {
    static let columnsRelatedToConvoInfoVolatile: [ColumnExpression] = [
        // Note: We intentionally exclude 'Interaction.Columns.wasRead' from here as we want to
        // manually manage triggering config updates from marking as read
        SessionThread.Columns.markedAsUnread
    ]
    
    // MARK: - Incoming Changes
    
    static func handleConvoInfoVolatileUpdate(
        _ db: Database,
        in conf: UnsafeMutablePointer<config_object>?,
        mergeNeedsDump: Bool
    ) throws {
        guard mergeNeedsDump else { return }
        guard conf != nil else { throw LibSessionError.nilConfigObject }
        
        // Get the volatile thread info from the conf and local conversations
        let volatileThreadInfo: [VolatileThreadInfo] = try extractConvoVolatileInfo(from: conf)
        let localVolatileThreadInfo: [String: VolatileThreadInfo] = VolatileThreadInfo.fetchAll(db)
            .reduce(into: [:]) { result, next in result[next.threadId] = next }
        
        // Map the volatileThreadInfo, upserting any changes and returning a list of local changes
        // which should override any synced changes (eg. 'lastReadTimestampMs')
        let newerLocalChanges: [VolatileThreadInfo] = try volatileThreadInfo
            .compactMap { threadInfo -> VolatileThreadInfo? in
                // Note: A normal 'openGroupId' isn't lowercased but the volatile conversation
                // info will always be lowercase so we need to fetch the "proper" threadId (in
                // order to be able to update the corrent database entries)
                guard
                    let threadId: String = try? SessionThread
                        .select(.id)
                        .filter(SessionThread.Columns.id.lowercased == threadInfo.threadId)
                        .asRequest(of: String.self)
                        .fetchOne(db)
                else { return nil }
                
                
                // Get the existing local state for the thread
                let localThreadInfo: VolatileThreadInfo? = localVolatileThreadInfo[threadId]
                
                // Update the thread 'markedAsUnread' state
                if
                    let markedAsUnread: Bool = threadInfo.changes.markedAsUnread,
                    markedAsUnread != (localThreadInfo?.changes.markedAsUnread ?? false)
                {
                    try SessionThread
                        .filter(id: threadId)
                        .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                            db,
                            SessionThread.Columns.markedAsUnread.set(to: markedAsUnread)
                        )
                }
                
                // If the device has a more recent read interaction then return the info so we can
                // update the cached config state accordingly
                guard
                    let lastReadTimestampMs: Int64 = threadInfo.changes.lastReadTimestampMs,
                    lastReadTimestampMs >= (localThreadInfo?.changes.lastReadTimestampMs ?? 0)
                else {
                    // We only want to return the 'lastReadTimestampMs' change, since the local state
                    // should win in that case, so ignore all others
                    return localThreadInfo?
                        .filterChanges { change in
                            switch change {
                                case .lastReadTimestampMs: return true
                                default: return false
                            }
                        }
                }
                
                // Mark all older interactions as read
                let interactionQuery = Interaction
                    .filter(Interaction.Columns.threadId == threadId)
                    .filter(Interaction.Columns.timestampMs <= lastReadTimestampMs)
                    .filter(Interaction.Columns.wasRead == false)
                let interactionInfoToMarkAsRead: [Interaction.ReadInfo] = try interactionQuery
                    .select(.id, .variant, .timestampMs, .wasRead)
                    .asRequest(of: Interaction.ReadInfo.self)
                    .fetchAll(db)
                try interactionQuery
                    .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                        db,
                        Interaction.Columns.wasRead.set(to: true)
                    )
                try Interaction.scheduleReadJobs(
                    db,
                    threadId: threadId,
                    threadVariant: threadInfo.variant,
                    interactionInfo: interactionInfoToMarkAsRead,
                    lastReadTimestampMs: lastReadTimestampMs,
                    trySendReadReceipt: false,  // Interactions already read, no need to send
                    calledFromConfigHandling: true
                )
                return nil
            }
        
        // If there are no newer local last read timestamps then just return the mergeResult
        guard !newerLocalChanges.isEmpty else { return }
        
        try upsert(
            convoInfoVolatileChanges: newerLocalChanges,
            in: conf
        )
    }
    
    static func upsert(
        convoInfoVolatileChanges: [VolatileThreadInfo],
        in conf: UnsafeMutablePointer<config_object>?
    ) throws {
        guard conf != nil else { throw LibSessionError.nilConfigObject }
        
        // Exclude any invalid thread info
        let validChanges: [VolatileThreadInfo] = convoInfoVolatileChanges
            .filter { info in
                switch info.variant {
                    case .contact:
                        // FIXME: libSession V1 doesn't sync volatileThreadInfo for blinded message requests
                        guard (try? SessionId(from: info.threadId))?.prefix == .standard else { return false }
                        
                        return true
                        
                    default: return true
                }
            }
        
        try validChanges.forEach { threadInfo in
            guard var cThreadId: [CChar] = threadInfo.threadId.cString(using: .utf8) else {
                SNLog("Unable to upsert contact volatile info to LibSession: \(LibSessionError.invalidCConversion)")
                throw LibSessionError.invalidCConversion
            }
            
            switch threadInfo.variant {
                case .contact:
                    var oneToOne: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                    
                    guard convo_info_volatile_get_or_construct_1to1(conf, &oneToOne, &cThreadId) else {
                        /// It looks like there are some situations where this object might not get created correctly (and
                        /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
                        throw LibSessionError(
                            conf,
                            fallbackError: .getOrConstructFailedUnexpectedly,
                            logMessage: "Unable to upsert contact volatile info to LibSession"
                        )
                    }
                    
                    threadInfo.changes.forEach { change in
                        switch change {
                            case .lastReadTimestampMs(let lastReadMs):
                                oneToOne.last_read = max(oneToOne.last_read, lastReadMs)
                                
                            case .markedAsUnread(let unread):
                                oneToOne.unread = unread
                        }
                    }
                    convo_info_volatile_set_1to1(conf, &oneToOne)
                    
                case .legacyGroup:
                    var legacyGroup: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                    
                    guard convo_info_volatile_get_or_construct_legacy_group(conf, &legacyGroup, &cThreadId) else {
                        /// It looks like there are some situations where this object might not get created correctly (and
                        /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
                        throw LibSessionError(
                            conf,
                            fallbackError: .getOrConstructFailedUnexpectedly,
                            logMessage: "Unable to upsert legacy group volatile info to LibSession"
                        )
                    }
                    
                    threadInfo.changes.forEach { change in
                        switch change {
                            case .lastReadTimestampMs(let lastReadMs):
                                legacyGroup.last_read = max(legacyGroup.last_read, lastReadMs)
                                
                            case .markedAsUnread(let unread):
                                legacyGroup.unread = unread
                        }
                    }
                    convo_info_volatile_set_legacy_group(conf, &legacyGroup)
                    
                case .community:
                    guard
                        var cBaseUrl: [CChar] = threadInfo.openGroupUrlInfo?.server.cString(using: .utf8),
                        var cRoomToken: [CChar] = threadInfo.openGroupUrlInfo?.roomToken.cString(using: .utf8),
                        var cPubkey: [UInt8] = threadInfo.openGroupUrlInfo.map({ Array(Data(hex: $0.publicKey)) })
                    else {
                        SNLog("Unable to create community conversation when updating last read timestamp due to missing URL info")
                        return
                    }
                    
                    var community: convo_info_volatile_community = convo_info_volatile_community()
                    
                    guard convo_info_volatile_get_or_construct_community(conf, &community, &cBaseUrl, &cRoomToken, &cPubkey) else {
                        /// It looks like there are some situations where this object might not get created correctly (and
                        /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
                        throw LibSessionError(
                            conf,
                            fallbackError: .getOrConstructFailedUnexpectedly,
                            logMessage: "Unable to upsert community volatile info to LibSession"
                        )
                    }
                    
                    threadInfo.changes.forEach { change in
                        switch change {
                            case .lastReadTimestampMs(let lastReadMs):
                                community.last_read = max(community.last_read, lastReadMs)
                                
                            case .markedAsUnread(let unread):
                                community.unread = unread
                        }
                    }
                    convo_info_volatile_set_community(conf, &community)
                    
                case .group: return
            }
        }
    }
    
    static func updateMarkedAsUnreadState(
        _ db: Database,
        threads: [SessionThread]
    ) throws {
        // If we have no updated threads then no need to continue
        guard !threads.isEmpty else { return }

        let changes: [VolatileThreadInfo] = try threads.map { thread in
            VolatileThreadInfo(
                threadId: thread.id,
                variant: thread.variant,
                openGroupUrlInfo: (thread.variant != .community ? nil :
                    try OpenGroupUrlInfo.fetchOne(db, id: thread.id)
                ),
                changes: [.markedAsUnread(thread.markedAsUnread ?? false)]
            )
        }

        try LibSession.performAndPushChange(
            db,
            for: .convoInfoVolatile,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            try upsert(
                convoInfoVolatileChanges: changes,
                in: conf
            )
        }
    }
    
    static func remove(_ db: Database, volatileContactIds: [String]) throws {
        try LibSession.performAndPushChange(
            db,
            for: .convoInfoVolatile,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            try volatileContactIds.forEach { contactId in
                var cSessionId: [CChar] = try contactId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                
                // Don't care if the data doesn't exist
                convo_info_volatile_erase_1to1(conf, &cSessionId)
            }
        }
    }
    
    static func remove(_ db: Database, volatileLegacyGroupIds: [String]) throws {
        try LibSession.performAndPushChange(
            db,
            for: .convoInfoVolatile,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            try volatileLegacyGroupIds.forEach { legacyGroupId in
                var cLegacyGroupId: [CChar] = try legacyGroupId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                
                // Don't care if the data doesn't exist
                convo_info_volatile_erase_legacy_group(conf, &cLegacyGroupId)
            }
        }
    }
    
    static func remove(_ db: Database, volatileCommunityInfo: [OpenGroupUrlInfo]) throws {
        try LibSession.performAndPushChange(
            db,
            for: .convoInfoVolatile,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            try volatileCommunityInfo.forEach { urlInfo in
                var cBaseUrl: [CChar] = try urlInfo.server.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                var cRoom: [CChar] = try urlInfo.roomToken.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                
                // Don't care if the data doesn't exist
                convo_info_volatile_erase_community(conf, &cBaseUrl, &cRoom)
            }
        }
    }
}

// MARK: - External Outgoing Changes

public extension LibSession {
    static func syncThreadLastReadIfNeeded(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        lastReadTimestampMs: Int64
    ) throws {
        try LibSession.performAndPushChange(
            db,
            for: .convoInfoVolatile,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            try upsert(
                convoInfoVolatileChanges: [
                    VolatileThreadInfo(
                        threadId: threadId,
                        variant: threadVariant,
                        openGroupUrlInfo: (threadVariant != .community ? nil :
                            try OpenGroupUrlInfo.fetchOne(db, id: threadId)
                        ),
                        changes: [.lastReadTimestampMs(lastReadTimestampMs)]
                    )
                ],
                in: conf
            )
        }
    }
    
    static func timestampAlreadyRead(
        threadId: String,
        threadVariant: SessionThread.Variant,
        timestampMs: Int64,
        userPublicKey: String,
        openGroup: OpenGroup?
    ) -> Bool {
        return LibSession
            .config(for: .convoInfoVolatile, publicKey: userPublicKey)
            .wrappedValue
            .map { conf in
                switch threadVariant {
                    case .contact:
                        var oneToOne: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                        guard
                            var cThreadId: [CChar] = threadId.cString(using: .utf8),
                            convo_info_volatile_get_1to1(conf, &oneToOne, &cThreadId)
                        else {
                            LibSessionError.clear(conf)
                            return false
                        }
                        
                        return (oneToOne.last_read >= timestampMs)
                        
                    case .legacyGroup:
                        var legacyGroup: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                        
                        guard
                            var cThreadId: [CChar] = threadId.cString(using: .utf8),
                            convo_info_volatile_get_legacy_group(conf, &legacyGroup, &cThreadId)
                        else {
                            LibSessionError.clear(conf)
                            return false
                        }
                        
                        return (legacyGroup.last_read >= timestampMs)
                        
                    case .community:
                        guard let openGroup: OpenGroup = openGroup else { return false }
                        
                        var convoCommunity: convo_info_volatile_community = convo_info_volatile_community()
                        
                        guard
                            var cBaseUrl: [CChar] = openGroup.server.cString(using: .utf8),
                            var cRoomToken: [CChar] = openGroup.roomToken.cString(using: .utf8),
                            convo_info_volatile_get_community(conf, &convoCommunity, &cBaseUrl, &cRoomToken)
                        else {
                            LibSessionError.clear(conf)
                            return false
                        }
                        
                        return (convoCommunity.last_read >= timestampMs)
                        
                    case .group: return false
                }
            }
            .defaulting(to: false) // If we don't have a config then just assume it's unread
    }
}

// MARK: - VolatileThreadInfo

public extension LibSession {
    internal struct OpenGroupUrlInfo: FetchableRecord, Codable, Hashable {
        let threadId: String
        let server: String
        let roomToken: String
        let publicKey: String
        
        static func fetchOne(_ db: Database, id: String) throws -> OpenGroupUrlInfo? {
            return try OpenGroup
                .filter(id: id)
                .select(.threadId, .server, .roomToken, .publicKey)
                .asRequest(of: OpenGroupUrlInfo.self)
                .fetchOne(db)
        }
        
        static func fetchAll(_ db: Database, ids: [String]) throws -> [OpenGroupUrlInfo] {
            return try OpenGroup
                .filter(ids: ids)
                .select(.threadId, .server, .roomToken, .publicKey)
                .asRequest(of: OpenGroupUrlInfo.self)
                .fetchAll(db)
        }
        
        static func fetchAll(_ db: Database) throws -> [OpenGroupUrlInfo] {
            return try OpenGroup
                .select(.threadId, .server, .roomToken, .publicKey)
                .asRequest(of: OpenGroupUrlInfo.self)
                .fetchAll(db)
        }
    }
    
    struct VolatileThreadInfo {
        enum Change {
            case markedAsUnread(Bool)
            case lastReadTimestampMs(Int64)
        }
        
        let threadId: String
        let variant: SessionThread.Variant
        fileprivate let openGroupUrlInfo: OpenGroupUrlInfo?
        let changes: [Change]
        
        fileprivate init(
            threadId: String,
            variant: SessionThread.Variant,
            openGroupUrlInfo: OpenGroupUrlInfo? = nil,
            changes: [Change]
        ) {
            self.threadId = threadId
            self.variant = variant
            self.openGroupUrlInfo = openGroupUrlInfo
            self.changes = changes
        }
        
        // MARK: - Convenience
        
        func filterChanges(isIncluded: (Change) -> Bool) -> VolatileThreadInfo {
            return VolatileThreadInfo(
                threadId: threadId,
                variant: variant,
                openGroupUrlInfo: openGroupUrlInfo,
                changes: changes.filter(isIncluded)
            )
        }
        
        static func fetchAll(_ db: Database? = nil, ids: [String]? = nil) -> [VolatileThreadInfo] {
            guard let db: Database = db else {
                return Storage.shared
                    .read { db in fetchAll(db, ids: ids) }
                    .defaulting(to: [])
            }
            
            struct FetchedInfo: FetchableRecord, Codable, Hashable {
                let id: String
                let variant: SessionThread.Variant
                let markedAsUnread: Bool?
                let timestampMs: Int64?
                let server: String?
                let roomToken: String?
                let publicKey: String?
            }
            
            let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
            let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
            let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
            let timestampMsLiteral: SQL = SQL(stringLiteral: Interaction.Columns.timestampMs.name)
            let request: SQLRequest<FetchedInfo> = """
                SELECT
                    \(thread[.id]),
                    \(thread[.variant]),
                    \(thread[.markedAsUnread]),
                    \(interaction[.timestampMs]),
                    \(openGroup[.server]),
                    \(openGroup[.roomToken]),
                    \(openGroup[.publicKey])
                
                FROM \(SessionThread.self)
                LEFT JOIN (
                    SELECT
                        \(interaction[.threadId]),
                        MAX(\(interaction[.timestampMs])) AS \(timestampMsLiteral)
                    FROM \(Interaction.self)
                    WHERE (
                        \(interaction[.wasRead]) = true AND
                        -- Note: Due to the complexity of how call messages are handled and the short
                        -- duration they exist in the swarm, we have decided to exclude trying to
                        -- include them when syncing the read status of conversations (they are also
                        -- implemented differently between platforms so including them could be a
                        -- significant amount of work)
                        \(SQL("\(interaction[.variant]) IN \(Interaction.Variant.variantsToIncrementUnreadCount.filter { $0 != .infoCall })"))
                    )
                    GROUP BY \(interaction[.threadId])
                ) AS \(Interaction.self) ON \(interaction[.threadId]) = \(thread[.id])
                LEFT JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(thread[.id])
                \(ids == nil ? SQL("") :
                "WHERE \(SQL("\(thread[.id]) IN \(ids ?? [])"))"
                )
                GROUP BY \(thread[.id])
            """
            
            return ((try? request.fetchAll(db)) ?? [])
                .map { threadInfo in
                    VolatileThreadInfo(
                        threadId: threadInfo.id,
                        variant: threadInfo.variant,
                        openGroupUrlInfo: {
                            guard
                                let server: String = threadInfo.server,
                                let roomToken: String = threadInfo.roomToken,
                                let publicKey: String = threadInfo.publicKey
                            else { return nil }
                            
                            return OpenGroupUrlInfo(
                                threadId: threadInfo.id,
                                server: server,
                                roomToken: roomToken,
                                publicKey: publicKey
                            )
                        }(),
                        changes: [
                            .markedAsUnread(threadInfo.markedAsUnread ?? false),
                            .lastReadTimestampMs(threadInfo.timestampMs ?? 0)
                        ]
                    )
                }
        }
    }
    
    internal static func extractConvoVolatileInfo(
        from conf: UnsafeMutablePointer<config_object>?
    ) throws -> [VolatileThreadInfo] {
        var infiniteLoopGuard: Int = 0
        var result: [VolatileThreadInfo] = []
        var oneToOne: convo_info_volatile_1to1 = convo_info_volatile_1to1()
        var community: convo_info_volatile_community = convo_info_volatile_community()
        var legacyGroup: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
        let convoIterator: OpaquePointer = convo_info_volatile_iterator_new(conf)

        while !convo_info_volatile_iterator_done(convoIterator) {
            try LibSession.checkLoopLimitReached(&infiniteLoopGuard, for: .convoInfoVolatile)
            
            if convo_info_volatile_it_is_1to1(convoIterator, &oneToOne) {
                result.append(
                    VolatileThreadInfo(
                        threadId: String(libSessionVal: oneToOne.session_id),
                        variant: .contact,
                        changes: [
                            .markedAsUnread(oneToOne.unread),
                            .lastReadTimestampMs(oneToOne.last_read)
                        ]
                    )
                )
            }
            else if convo_info_volatile_it_is_community(convoIterator, &community) {
                let server: String = String(libSessionVal: community.base_url)
                let roomToken: String = String(libSessionVal: community.room)
                let publicKey: String = Data(
                    libSessionVal: community.pubkey,
                    count: OpenGroup.pubkeyByteLength
                ).toHexString()
                
                result.append(
                    VolatileThreadInfo(
                        threadId: OpenGroup.idFor(roomToken: roomToken, server: server),
                        variant: .community,
                        openGroupUrlInfo: OpenGroupUrlInfo(
                            threadId: OpenGroup.idFor(roomToken: roomToken, server: server),
                            server: server,
                            roomToken: roomToken,
                            publicKey: publicKey
                        ),
                        changes: [
                            .markedAsUnread(community.unread),
                            .lastReadTimestampMs(community.last_read)
                        ]
                    )
                )
            }
            else if convo_info_volatile_it_is_legacy_group(convoIterator, &legacyGroup) {
                result.append(
                    VolatileThreadInfo(
                        threadId: String(libSessionVal: legacyGroup.group_id),
                        variant: .legacyGroup,
                        changes: [
                            .markedAsUnread(legacyGroup.unread),
                            .lastReadTimestampMs(legacyGroup.last_read)
                        ]
                    )
                )
            }
            else {
                SNLog("Ignoring unknown conversation type when iterating through volatile conversation info update")
            }
            
            convo_info_volatile_iterator_advance(convoIterator)
        }
        convo_info_volatile_iterator_free(convoIterator) // Need to free the iterator
        
        return result
    }
}

fileprivate extension [LibSession.VolatileThreadInfo.Change] {
    var markedAsUnread: Bool? {
        for change in self {
            switch change {
                case .markedAsUnread(let value): return value
                default: continue
            }
        }
        
        return nil
    }
    
    var lastReadTimestampMs: Int64? {
        for change in self {
            switch change {
                case .lastReadTimestampMs(let value): return value
                default: continue
            }
        }
        
        return nil
    }
}

