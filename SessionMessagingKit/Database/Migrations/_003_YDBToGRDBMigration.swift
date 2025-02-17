// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _003_YDBToGRDBMigration: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "YDBToGRDBMigration"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = [Identity.self]
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = []
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        guard
            !SNUtilitiesKit.isRunningTests,
            let numEdSecretKeys: Int = try? Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM identity WHERE variant == ?",
                arguments: [
                    Identity.Variant.ed25519SecretKey.rawValue
                ]
            ),
            numEdSecretKeys > 0
        else { return Storage.update(progress: 1, for: self, in: target, using: dependencies) }
        
        Log.error(.migration, "Attempted to perform legacy migation")
        throw StorageError.migrationNoLongerSupported
    }
}
