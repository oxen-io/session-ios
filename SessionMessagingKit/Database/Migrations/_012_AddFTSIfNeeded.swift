// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration adds the FTS table back for internal test users whose FTS table was removed unintentionally
enum _012_AddFTSIfNeeded: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "AddFTSIfNeeded" // stringlint:disable
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.01
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = []
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = []
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database) throws {
        // Fix an issue that the fullTextSearchTable was dropped unintentionally and global search won't work.
        // This issue only happens to internal test users.
        if try db.tableExists(Interaction.fullTextSearchTableName) == false {
            try db.create(virtualTable: Interaction.fullTextSearchTableName, using: FTS5()) { t in
                t.synchronize(withTable: Interaction.databaseTableName)
                t.tokenizer = _001_InitialSetupMigration.fullTextSearchTokenizer
                
                t.column(Interaction.Columns.body.name)
                t.column(Interaction.Columns.threadId.name)
            }
        }
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}
