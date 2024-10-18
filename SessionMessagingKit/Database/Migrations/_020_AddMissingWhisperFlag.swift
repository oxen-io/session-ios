// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _020_AddMissingWhisperFlag: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "AddMissingWhisperFlag"
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var requirements: [MigrationRequirement] = []
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = []
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = [Interaction.self]
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        /// We should have had this column from the very beginning but it was missed, so add it in now for when we eventually
        /// support whispers in Community conversations
        try db.alter(table: Interaction.self) { t in
            t.add(.openGroupWhisper, .boolean)
                .notNull()
                .defaults(to: false)
        }
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}
