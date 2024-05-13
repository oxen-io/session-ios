// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration adds a primary key to `SnodeReceivedMessageInfo` based on the key and hash to speed up lookup
enum _005_AddSnodeReveivedMessageInfoPrimaryKey: Migration {
    static let target: TargetMigrations.Identifier = .snodeKit
    static let identifier: String = "AddSnodeReveivedMessageInfoPrimaryKey" // stringlint:disable
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.2
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = [SnodeReceivedMessageInfo.self]
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = [SnodeReceivedMessageInfo.self]
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database) throws {
        // SQLite doesn't support adding a new primary key after creation so we need to create a new table with
        // the setup we want, copy data from the old table over, drop the old table and rename the new table
        struct TmpSnodeReceivedMessageInfo: Codable, TableRecord, FetchableRecord, PersistableRecord, ColumnExpressible {
            static var databaseTableName: String { "tmpSnodeReceivedMessageInfo" }
            
            typealias Columns = CodingKeys
            enum CodingKeys: String, CodingKey, ColumnExpression {
                case key
                case hash
                case expirationDateMs
                case wasDeletedOrInvalid
            }

            let key: String
            let hash: String
            let expirationDateMs: Int64
            var wasDeletedOrInvalid: Bool?
        }
        
        try db.create(table: TmpSnodeReceivedMessageInfo.self) { t in
            t.column(.key, .text).notNull()
            t.column(.hash, .text).notNull()
            t.column(.expirationDateMs, .integer).notNull()
            t.column(.wasDeletedOrInvalid, .boolean)
            
            t.primaryKey([.key, .hash])
        }
        
        // Insert into the new table, drop the old table and rename the new table to be the old one
        let tmpInfo: TypedTableAlias<TmpSnodeReceivedMessageInfo> = TypedTableAlias()
        let info: TypedTableAlias<SnodeReceivedMessageInfo> = TypedTableAlias()
        try db.execute(literal: """
            INSERT INTO \(tmpInfo)
            SELECT \(info[.key]), \(info[.hash]), \(info[.expirationDateMs]), \(info[.wasDeletedOrInvalid])
            FROM \(info)
        """)
        
        try db.drop(table: SnodeReceivedMessageInfo.self)
        try db.rename(
            table: TmpSnodeReceivedMessageInfo.databaseTableName,
            to: SnodeReceivedMessageInfo.databaseTableName
        )
        
        // Need to create the indexes separately from creating 'TmpGroupMember' to ensure they
        // have the correct names
        try db.createIndex(on: SnodeReceivedMessageInfo.self, columns: [.key])
        try db.createIndex(on: SnodeReceivedMessageInfo.self, columns: [.hash])
        try db.createIndex(on: SnodeReceivedMessageInfo.self, columns: [.expirationDateMs])
        try db.createIndex(on: SnodeReceivedMessageInfo.self, columns: [.wasDeletedOrInvalid])
        
        Storage.update(progress: 1, for: self, in: target)
    }
}
