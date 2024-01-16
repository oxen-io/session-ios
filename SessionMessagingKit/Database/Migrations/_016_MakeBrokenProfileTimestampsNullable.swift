// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration updates the tiemstamps added to the `Profile` in earlier migrations to be nullable (having it not null
/// results in migration issues when a user jumps between multiple versions)
enum _016_MakeBrokenProfileTimestampsNullable: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "MakeBrokenProfileTimestampsNullable" // stringlint:disable
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var requirements: [MigrationRequirement] = [.libSessionStateLoaded]
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = []
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = [Profile.self]
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        /// SQLite doesn't support altering columns after creation so we need to create a new table with the setup we
        /// want, copy data from the old table over, drop the old table and rename the new table
        struct TmpProfile: Codable, TableRecord, FetchableRecord, PersistableRecord, ColumnExpressible {
            static var databaseTableName: String { "tmpProfile" } // stringlint:disable
            
            public typealias Columns = CodingKeys
            public enum CodingKeys: String, CodingKey, ColumnExpression {
                case id
                
                case name
                case lastNameUpdate
                case nickname
                
                case profilePictureUrl
                case profilePictureFileName
                case profileEncryptionKey
                case lastProfilePictureUpdate
                
                case blocksCommunityMessageRequests
                case lastBlocksCommunityMessageRequests
            }

            public let id: String
            public let name: String
            public let lastNameUpdate: TimeInterval?
            public let nickname: String?
            public let profilePictureUrl: String?
            public let profilePictureFileName: String?
            public let profileEncryptionKey: Data?
            public let lastProfilePictureUpdate: TimeInterval?
            public let blocksCommunityMessageRequests: Bool?
            public let lastBlocksCommunityMessageRequests: TimeInterval?
        }
        
        try db.create(table: TmpProfile.self) { t in
            t.column(.id, .text)
                .notNull()
                .primaryKey()
            t.column(.name, .text).notNull()
            t.column(.nickname, .text)
            t.column(.profilePictureUrl, .text)
            t.column(.profilePictureFileName, .text)
            t.column(.profileEncryptionKey, .blob)
            t.column(.lastNameUpdate, .integer).defaults(to: 0)
            t.column(.lastProfilePictureUpdate, .integer).defaults(to: 0)
            t.column(.blocksCommunityMessageRequests, .boolean)
            t.column(.lastBlocksCommunityMessageRequests, .integer).defaults(to: 0)
        }
        
        // Insert into the new table, drop the old table and rename the new table to be the old one
        try db.execute(sql: """
            INSERT INTO \(TmpProfile.databaseTableName)
            SELECT \(Profile.databaseTableName).*
            FROM \(Profile.databaseTableName)
        """)
        
        try db.drop(table: Profile.self)
        try db.rename(table: TmpProfile.databaseTableName, to: Profile.databaseTableName)
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
