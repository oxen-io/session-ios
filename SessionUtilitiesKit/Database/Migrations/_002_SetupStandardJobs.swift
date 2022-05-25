// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Curve25519Kit

/// This migration sets up the standard jobs, since we want these jobs to run before any "once-off" jobs we do this migration
/// before running the `YDBToGRDBMigration`
enum _002_SetupStandardJobs: Migration {
    static let identifier: String = "SetupStandardJobs"
    
    static func migrate(_ db: Database) throws {
        try autoreleasepool {
            // Note: This job exists in the 'Session' target but that doesn't have it's own migrations
            _ = try Job(
                variant: .syncPushTokens,
                behaviour: .recurringOnLaunch
            ).inserted(db)
        }
    }
}