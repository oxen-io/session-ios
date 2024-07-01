// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUtilitiesKit

enum _001_InitialSetupMigration: Migration {
    static let target: TargetMigrations.Identifier = .snodeKit
    static let identifier: String = "initialSetup" // stringlint:disable
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = []
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = [
        LegacySnode.self, LegacySnodeSet.self, SnodeReceivedMessageInfo.self
    ]
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        try db.create(table: LegacySnode.self) { t in
            t.deprecatedColumn(name: "public_ip", .text)
            t.deprecatedColumn(name: "storage_port", .integer)
            t.column(.ed25519PublicKey, .text)
            t.deprecatedColumn(name: "pubkey_x25519", .text)
        }
        
        try db.create(table: LegacySnodeSet.self) { t in
            t.column(.key, .text)
            t.column(.nodeIndex, .integer)
            t.deprecatedColumn(name: "address", .text)
            t.deprecatedColumn(name: "port", .integer)
        }
        
        try db.create(table: SnodeReceivedMessageInfo.self) { t in
            t.deprecatedColumn(name: "id", .integer)                  // stringlint:disable
                .notNull()
                .primaryKey(autoincrement: true)
            t.column(.key, .text)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column(.hash, .text)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column(.expirationDateMs, .integer)
                .notNull()
                .indexed()                                            // Quicker querying
            
            t.uniqueKey([.key, .hash])
        }
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}

internal extension _001_InitialSetupMigration {
    struct LegacySnode: Codable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible, Hashable {
       public static var databaseTableName: String { "snode" }
       
       public typealias Columns = CodingKeys
       public enum CodingKeys: String, CodingKey, ColumnExpression {
           case ip = "public_ip"
           case lmqPort = "storage_lmq_port"
           case x25519PublicKey = "pubkey_x25519"
           case ed25519PublicKey = "pubkey_ed25519"
       }

       public let ip: String
       public let lmqPort: UInt16
       public let x25519PublicKey: String
       public let ed25519PublicKey: String
    }
    
    struct LegacySnodeSet: Codable, FetchableRecord, EncodableRecord, PersistableRecord, TableRecord, ColumnExpressible {
        public static let onionRequestPathPrefix = "OnionRequestPath-"  // stringlint:disable
        public static var databaseTableName: String { "snodeSet" }
            
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression {
            case key
            case nodeIndex
            case ip
            case lmqPort
        }
        
        public let key: String
        public let nodeIndex: Int
        public let ip: String
        public let lmqPort: UInt16
    }
}
