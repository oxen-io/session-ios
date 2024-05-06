// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

/// This migration used to remove the legacy YapDatabase files (the old logic has been removed and is no longer supported so it now does nothing)
enum _004_RemoveLegacyYDB: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "RemoveLegacyYDB" // stringlint:disable
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = []
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = []

    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
