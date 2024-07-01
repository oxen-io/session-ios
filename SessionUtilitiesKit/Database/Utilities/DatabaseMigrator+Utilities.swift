// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public extension DatabaseMigrator {
    mutating func registerMigration(
        _ storage: Storage?,
        targetIdentifier: TargetMigrations.Identifier,
        migration: Migration.Type,
        foreignKeyChecks: ForeignKeyChecks = .deferred,
        using dependencies: Dependencies
    ) {
        self.registerMigration(
            targetIdentifier.key(with: migration),
            migrate: migration.loggedMigrate(storage, targetIdentifier: targetIdentifier, using: dependencies)
        )
    }
}
