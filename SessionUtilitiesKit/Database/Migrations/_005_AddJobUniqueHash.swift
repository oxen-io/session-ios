// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

enum _005_AddJobUniqueHash: Migration {
    static let target: TargetMigrations.Identifier = .utilitiesKit
    static let identifier: String = "AddJobUniqueHash" // stringlint:disable
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = []
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = [Job.self]
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        // Add `uniqueHashValue` to the job table
        try db.alter(table: Job.self) { t in
            t.add(.uniqueHashValue, .integer)
        }
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
