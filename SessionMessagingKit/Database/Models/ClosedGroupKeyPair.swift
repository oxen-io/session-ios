// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CryptoKit
import GRDB
import SessionUtilitiesKit

public struct ClosedGroupKeyPair: Codable, Equatable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "closedGroupKeyPair" }
    internal static let closedGroupForeignKey = ForeignKey(
        [Columns.threadId],
        to: [ClosedGroup.Columns.threadId]
    )
    private static let closedGroup = belongsTo(ClosedGroup.self, using: closedGroupForeignKey)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case threadId
        case publicKey
        case secretKey
        case receivedTimestamp
        case threadKeyPairHash
    }
    
    public let threadId: String
    public let publicKey: Data
    public let secretKey: Data
    public let receivedTimestamp: TimeInterval
    public let threadKeyPairHash: String
    
    // MARK: - Relationships
    
    public var closedGroup: QueryInterfaceRequest<ClosedGroup> {
        request(for: ClosedGroupKeyPair.closedGroup)
    }
    
    // MARK: - Initialization
    
    public init(
        threadId: String,
        publicKey: Data,
        secretKey: Data,
        receivedTimestamp: TimeInterval
    ) {
        self.threadId = threadId
        self.publicKey = publicKey
        self.secretKey = secretKey
        self.receivedTimestamp = receivedTimestamp
        
        // This value has a unique constraint and is used for key de-duping so the formula
        // shouldn't be modified unless all existing keys have their values updated
        self.threadKeyPairHash = Data(Insecure.MD5
            .hash(data: threadId.bytes + publicKey.bytes + secretKey.bytes)
            .makeIterator())
            .toHexString()
    }
}

// MARK: - GRDB Interactions

public extension ClosedGroupKeyPair {
    static func fetchLatestKeyPair(_ db: Database, threadId: String) throws -> ClosedGroupKeyPair? {
        return try ClosedGroupKeyPair
            .filter(Columns.threadId == threadId)
            .order(Columns.receivedTimestamp.desc)
            .fetchOne(db)
    }
}
