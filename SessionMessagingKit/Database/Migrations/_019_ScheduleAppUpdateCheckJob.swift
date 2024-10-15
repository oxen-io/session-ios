// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _019_ScheduleAppUpdateCheckJob: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "ScheduleAppUpdateCheckJob" // stringlint:disable
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var requirements: [MigrationRequirement] = [.libSessionStateLoaded]
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = []
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = []
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        _ = try Job(
            variant: .checkForAppUpdates,
            behaviour: .recurring
        ).migrationSafeInserted(db)
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
