// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

enum _003_YDBToGRDBMigration: Migration {
    static let target: TargetMigrations.Identifier = .utilitiesKit
    static let identifier: String = "YDBToGRDBMigration" // stringlint:disable
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = [Identity.self]
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = []
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        guard
            !SNUtilitiesKit.isRunningTests &&
            Identity.userExists(db, using: dependencies)
        else { return Storage.update(progress: 1, for: self, in: target, using: dependencies) }
        
        Log.error(.migration, "Attempted to perform legacy migation")
        throw StorageError.migrationNoLongerSupported
    }
}
