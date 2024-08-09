// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public struct SnodeReceivedMessageInfo: Codable, FetchableRecord, MutablePersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "snodeReceivedMessageInfo" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case key
        case hash
        case expirationDateMs
        case wasDeletedOrInvalid
    }
    
    /// The key this message hash is associated to
    ///
    /// This will be a combination of {address}.{port}.{publicKey} for new rows and just the {publicKey} for legacy rows
    public let key: String
    
    /// The is the hash for the received message
    public let hash: String
    
    /// This is the timestamp (in milliseconds since epoch) when the message hash should expire
    ///
    /// **Note:** If no value exists this will default to 15 days from now (since the service node caches messages for
    /// 14 days)
    public let expirationDateMs: Int64
    
    /// This flag indicates whether the interaction associated with this message hash was deleted or whether this message
    /// hash is potentially invalid (if a poll results in 100% of the `SnodeReceivedMessageInfo` entries being seen as
    /// duplicates then we assume that the `lastHash` value provided when retrieving messages was invalid and mark
    /// it as such)
    ///
    /// **Note:** When retrieving the `lastNotExpired` we will ignore any entries where this flag is true
    public var wasDeletedOrInvalid: Bool?
}

// MARK: - Convenience

public extension SnodeReceivedMessageInfo {
    private static func key(for snode: LibSession.Snode, publicKey: String, namespace: SnodeAPI.Namespace) -> String {
        guard namespace != .default else {
            return "\(snode.address).\(publicKey)"
        }
        
        return "\(snode.address).\(publicKey).\(namespace.rawValue)"
    }
    
    init(
        snode: LibSession.Snode,
        publicKey: String,
        namespace: SnodeAPI.Namespace,
        hash: String,
        expirationDateMs: Int64?
    ) {
        self.key = SnodeReceivedMessageInfo.key(for: snode, publicKey: publicKey, namespace: namespace)
        self.hash = hash
        self.expirationDateMs = (expirationDateMs ?? 0)
    }
}

// MARK: - GRDB Interactions

public extension SnodeReceivedMessageInfo {
    /// This method fetches the last non-expired hash from the database for message retrieval
    static func fetchLastNotExpired(
        _ db: Database,
        for snode: LibSession.Snode,
        namespace: SnodeAPI.Namespace,
        associatedWith publicKey: String,
        using dependencies: Dependencies
    ) throws -> SnodeReceivedMessageInfo? {
        return try SnodeReceivedMessageInfo
            .filter(
                SnodeReceivedMessageInfo.Columns.wasDeletedOrInvalid == nil ||
                SnodeReceivedMessageInfo.Columns.wasDeletedOrInvalid == false
            )
            .filter(SnodeReceivedMessageInfo.Columns.key == key(for: snode, publicKey: publicKey, namespace: namespace))
            .filter(SnodeReceivedMessageInfo.Columns.expirationDateMs > SnodeAPI.currentOffsetTimestampMs())
            .order(Column.rowID.desc)
            .fetchOne(db)
    }
    
    /// There are some cases where the latest message can be removed from a swarm, if we then try to poll for that message the swarm
    /// will see it as invalid and start returning messages from the beginning which can result in a lot of wasted, duplicate downloads
    ///
    /// This method should be called when deleting a message, handling an UnsendRequest or when receiving a poll response which contains
    /// solely duplicate messages (for the specific service node - if even one message in a response is new for that service node then this shouldn't
    /// be called if if the message has already been received and processed by a separate service node)
    static func handlePotentialDeletedOrInvalidHash(
        _ db: Database,
        potentiallyInvalidHashes: [String],
        otherKnownValidHashes: [String] = []
    ) throws {
        _ = try SnodeReceivedMessageInfo
            .filter(potentiallyInvalidHashes.contains(SnodeReceivedMessageInfo.Columns.hash))
            .updateAll(
                db,
                SnodeReceivedMessageInfo.Columns.wasDeletedOrInvalid.set(to: true)
            )
        
        // If we have any server hashes which we know are valid (eg. we fetched the oldest messages) then
        // mark them all as valid to prevent the case where we just slowly work backwards from the latest
        // message, polling for one earlier each time
        guard !otherKnownValidHashes.isEmpty else { return }
        
        _ = try SnodeReceivedMessageInfo
            .filter(otherKnownValidHashes.contains(SnodeReceivedMessageInfo.Columns.hash))
            .updateAll(
                db,
                SnodeReceivedMessageInfo.Columns.wasDeletedOrInvalid.set(to: false)
            )
    }
}
