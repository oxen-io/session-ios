// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration drops the current `SnodePool` and `SnodeSet` and their associated jobs as they are handled by `libSession` now
enum _006_DropSnodeCache: Migration {
    static let target: TargetMigrations.Identifier = .snodeKit
    static let identifier: String = "DropSnodeCache"
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = []
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = []
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = [
        _001_InitialSetupMigration.LegacySnode.self, _001_InitialSetupMigration.LegacySnodeSet.self
    ]
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        try db.drop(table: _001_InitialSetupMigration.LegacySnode.self)
        try db.drop(table: _001_InitialSetupMigration.LegacySnodeSet.self)
        
        // Drop the old snode cache jobs as well
        let variants: [Job.Variant] = [._legacy_getSnodePool, ._legacy_buildPaths, ._legacy_getSwarm]
        try Job.filter(variants.contains(Job.Columns.variant)).deleteAll(db)
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
