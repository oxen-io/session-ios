// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionUtilitiesKit

public struct ClosedGroup: Codable, Identifiable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "closedGroup" }
    internal static let threadForeignKey = ForeignKey([Columns.threadId], to: [SessionThread.Columns.id])
    public static let thread = belongsTo(SessionThread.self, using: threadForeignKey)
    internal static let keyPairs = hasMany(
        ClosedGroupKeyPair.self,
        using: ClosedGroupKeyPair.closedGroupForeignKey
    )
    public static let members = hasMany(GroupMember.self, using: GroupMember.closedGroupForeignKey)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case threadId
        case name
        case formationTimestamp
    }
    
    /// The Group public key takes up 32 bytes
    static let pubkeyByteLength: Int = 32
    
    /// The Group secret key takes up 32 bytes
    static let secretKeyByteLength: Int = 32
    
    public var id: String { threadId }  // Identifiable
    public var publicKey: String { threadId }

    /// The id for the thread this closed group belongs to
    ///
    /// **Note:** This value will always be publicKey for the closed group
    public let threadId: String
    public let name: String
    public let formationTimestamp: TimeInterval
    
    // MARK: - Relationships
    
    public var thread: QueryInterfaceRequest<SessionThread> {
        request(for: ClosedGroup.thread)
    }
    
    public var keyPairs: QueryInterfaceRequest<ClosedGroupKeyPair> {
        request(for: ClosedGroup.keyPairs)
    }
    
    public var allMembers: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
    }
    
    public var members: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.standard)
    }
    
    public var zombies: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.zombie)
    }
    
    public var moderators: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.moderator)
    }
    
    public var admins: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.admin)
    }
    
    // MARK: - Initialization
    
    public init(
        threadId: String,
        name: String,
        formationTimestamp: TimeInterval
    ) {
        self.threadId = threadId
        self.name = name
        self.formationTimestamp = formationTimestamp
    }
}

// MARK: - GRDB Interactions

public extension ClosedGroup {
    func fetchLatestKeyPair(_ db: Database) throws -> ClosedGroupKeyPair? {
        return try keyPairs
            .order(ClosedGroupKeyPair.Columns.receivedTimestamp.desc)
            .fetchOne(db)
    }
}

// MARK: - Search Queries

public extension ClosedGroup {
    struct FullTextSearch: Decodable, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case name
        }
        
        let name: String
    }
}

// MARK: - Convenience

public extension ClosedGroup {
    enum LeaveType {
        case standard
        case silent
        case forced
    }
    
    static func removeKeysAndUnsubscribe(
        _ db: Database? = nil,
        threadId: String,
        removeGroupData: Bool,
        calledFromConfigHandling: Bool
    ) throws {
        try removeKeysAndUnsubscribe(
            db,
            threadIds: [threadId],
            removeGroupData: removeGroupData,
            calledFromConfigHandling: calledFromConfigHandling
        )
    }
    
    static func removeKeysAndUnsubscribe(
        _ db: Database? = nil,
        threadIds: [String],
        removeGroupData: Bool,
        calledFromConfigHandling: Bool
    ) throws {
        guard !threadIds.isEmpty else { return }
        guard let db: Database = db else {
            Storage.shared.write { db in
                try ClosedGroup.removeKeysAndUnsubscribe(
                    db,
                    threadIds: threadIds,
                    removeGroupData: removeGroupData,
                    calledFromConfigHandling: calledFromConfigHandling
                )
            }
            return
        }
        
        // Remove the group from the database and unsubscribe from PNs
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        threadIds.forEach { threadId in
            ClosedGroupPoller.shared.stopPolling(for: threadId)
            
            PushNotificationAPI
                .unsubscribeFromLegacyGroup(
                    legacyGroupId: threadId,
                    currentUserPublicKey: userPublicKey
                )
                .sinkUntilComplete()
        }
        
        // Remove the keys for the group
        try ClosedGroupKeyPair
            .filter(threadIds.contains(ClosedGroupKeyPair.Columns.threadId))
            .deleteAll(db)
        
        struct ThreadIdVariant: Decodable, FetchableRecord {
            let id: String
            let variant: SessionThread.Variant
        }
        
        let threadVariants: [ThreadIdVariant] = try SessionThread
            .select(.id, .variant)
            .filter(ids: threadIds)
            .asRequest(of: ThreadIdVariant.self)
            .fetchAll(db)
        
        // Remove the remaining group data if desired
        if removeGroupData {
            try SessionThread   // Intentionally use `deleteAll` here as this gets triggered via `deleteOrLeave`
                .filter(ids: threadIds)
                .deleteAll(db)
            
            try ClosedGroup
                .filter(ids: threadIds)
                .deleteAll(db)
            
            try GroupMember
                .filter(threadIds.contains(GroupMember.Columns.groupId))
                .deleteAll(db)
        }
        
        // If we weren't called from config handling then we need to remove the group
        // data from the config
        if !calledFromConfigHandling {
            try LibSession.remove(
                db,
                legacyGroupIds: threadVariants
                    .filter { $0.variant == .legacyGroup }
                    .map { $0.id }
            )
            
            try LibSession.remove(
                db,
                groupIds: threadVariants
                    .filter { $0.variant == .group }
                    .map { $0.id }
            )
        }
    }
}
