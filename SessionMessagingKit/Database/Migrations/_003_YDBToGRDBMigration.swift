// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _003_YDBToGRDBMigration: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "YDBToGRDBMigration" // stringlint:disable
    static let needsConfigSync: Bool = true
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = [Identity.self]
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = []
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        guard
            !SNUtilitiesKit.isRunningTests &&
            Identity.userExists(db, using: dependencies)
        else { return Storage.update(progress: 1, for: self, in: target, using: dependencies) }
        
        Log.info("[Migration Error] Attempted to perform legacy migation", silenceForTests: true)
        throw StorageError.migrationNoLongerSupported
    }
}
