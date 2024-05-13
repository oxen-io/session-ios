// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public protocol Migration {
    static var target: TargetMigrations.Identifier { get }
    static var identifier: String { get }
    static var needsConfigSync: Bool { get }
    static var minExpectedRunDuration: TimeInterval { get }
    static var requirements: [MigrationRequirement] { get }
    
    /// This includes any tables which are fetched from as part of the migration so that we can test they can still be parsed
    /// correctly within migration tests
    static var fetchedTables: [(TableRecord & FetchableRecord).Type] { get }
    
    /// This includes any tables which are created or altered as part of the migration so that we can test they can still be parsed
    /// correctly within migration tests
    static var createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] { get }
    
    /// This includes any tables which have been permanently dropped as part of this migration
    static var droppedTables: [(TableRecord & FetchableRecord).Type] { get }
    
    static func migrate(_ db: Database) throws
}

public extension Migration {
    static var requirements: [MigrationRequirement] { [] }
    
    static func loggedMigrate(
        _ storage: Storage?,
        targetIdentifier: TargetMigrations.Identifier
    ) -> ((_ db: Database) throws -> ()) {
        return { (db: Database) in
            SNLogNotTests("[Migration Info] Starting \(targetIdentifier.key(with: self))")
            storage?.willStartMigration(db, self)
            storage?.internalCurrentlyRunningMigration.mutate { $0 = (targetIdentifier, self) }
            defer { storage?.internalCurrentlyRunningMigration.mutate { $0 = nil } }
            
            try migrate(db)
            SNLogNotTests("[Migration Info] Completed \(targetIdentifier.key(with: self))")
        }
    }
}
