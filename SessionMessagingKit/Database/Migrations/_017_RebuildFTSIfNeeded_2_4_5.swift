// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration adds the FTS table back if either the tables or any of the triggers no longer exist
enum _017_RebuildFTSIfNeeded_2_4_5: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "RebuildFTSIfNeeded_2_4_5" // stringlint:disable
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.01
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = []
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        func ftsIsValid(_ db: Database, _ tableName: String) -> Bool {
            return (
                ((try? db.tableExists(tableName)) == true) &&            // Table itself
                ((try? db.triggerExists("__\(tableName)_ai")) == true) &&  // Insert trigger
                ((try? db.triggerExists("__\(tableName)_au")) == true) &&  // Update trigger
                ((try? db.triggerExists("__\(tableName)_ad")) == true)     // Delete trigger
            )
        }

        // Recreate the interaction FTS if needed
        if !ftsIsValid(db, Interaction.fullTextSearchTableName) {
            try db.execute(sql: "DROP TABLE IF EXISTS \(Interaction.fullTextSearchTableName.quotedDatabaseIdentifier)")
            try db.dropFTS5SynchronizationTriggers(forTable: Interaction.fullTextSearchTableName)
            
            try db.create(virtualTable: Interaction.fullTextSearchTableName, using: FTS5()) { t in
                t.synchronize(withTable: Interaction.databaseTableName)
                t.tokenizer = _001_InitialSetupMigration.fullTextSearchTokenizer
                
                t.column(Interaction.Columns.body.name)
                t.column(Interaction.Columns.threadId.name)
            }
        }
        
        // Recreate the profile FTS if needed
        if !ftsIsValid(db, Profile.fullTextSearchTableName) {
            try db.execute(sql: "DROP TABLE IF EXISTS \(Profile.fullTextSearchTableName.quotedDatabaseIdentifier)")
            try db.dropFTS5SynchronizationTriggers(forTable: Profile.fullTextSearchTableName)
            
            try db.create(virtualTable: Profile.fullTextSearchTableName, using: FTS5()) { t in
                t.synchronize(withTable: Profile.databaseTableName)
                t.tokenizer = _001_InitialSetupMigration.fullTextSearchTokenizer
                
                t.column(Profile.Columns.nickname.name)
                t.column(Profile.Columns.name.name)
            }
        }
        
        // Recreate the closedGroup FTS if needed
        if !ftsIsValid(db, ClosedGroup.fullTextSearchTableName) {
            try db.execute(sql: "DROP TABLE IF EXISTS \(ClosedGroup.fullTextSearchTableName.quotedDatabaseIdentifier)")
            try db.dropFTS5SynchronizationTriggers(forTable: ClosedGroup.fullTextSearchTableName)
            
            try db.create(virtualTable: ClosedGroup.fullTextSearchTableName, using: FTS5()) { t in
                t.synchronize(withTable: ClosedGroup.databaseTableName)
                t.tokenizer = _001_InitialSetupMigration.fullTextSearchTokenizer
                
                t.column(ClosedGroup.Columns.name.name)
            }
        }
        
        // Recreate the openGroup FTS if needed
        if !ftsIsValid(db, OpenGroup.fullTextSearchTableName) {
            try db.execute(sql: "DROP TABLE IF EXISTS \(OpenGroup.fullTextSearchTableName.quotedDatabaseIdentifier)")
            try db.dropFTS5SynchronizationTriggers(forTable: OpenGroup.fullTextSearchTableName)
            
            try db.create(virtualTable: OpenGroup.fullTextSearchTableName, using: FTS5()) { t in
                t.synchronize(withTable: OpenGroup.databaseTableName)
                t.tokenizer = _001_InitialSetupMigration.fullTextSearchTokenizer
                
                t.column(OpenGroup.Columns.name.name)
            }
        }
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
