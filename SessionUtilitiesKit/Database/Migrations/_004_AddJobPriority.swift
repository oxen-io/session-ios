// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

enum _004_AddJobPriority: Migration {
    static let target: TargetMigrations.Identifier = .utilitiesKit
    static let identifier: String = "AddJobPriority" // stringlint:disable
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = []
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = [Job.self]
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database) throws {
        // Add `priority` to the job table
        try db.alter(table: Job.self) { t in
            t.add(.priority, .integer).defaults(to: 0)
        }
        
        // Update the priorities for the below job types (want to ensure they run in the order
        // specified to avoid weird bugs)
        let variantPriorities: [Int: [Job.Variant]] = [
            7: [Job.Variant.disappearingMessages],
            6: [Job.Variant.failedMessageSends, Job.Variant.failedAttachmentDownloads],
            5: [Job.Variant._legacy_getSnodePool],
            4: [Job.Variant.syncPushTokens],
            3: [Job.Variant.retrieveDefaultOpenGroupRooms],
            2: [Job.Variant.updateProfilePicture],
            1: [Job.Variant.garbageCollection]
        ]
        
        try variantPriorities.forEach { priority, variants in
            try Job
                .filter(variants.contains(Job.Columns.variant))
                .updateAll(
                    db,
                    Job.Columns.priority.set(to: priority)
                )
        }
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}
