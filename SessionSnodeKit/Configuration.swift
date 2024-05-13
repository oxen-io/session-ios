// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public enum SNSnodeKit: MigratableTarget { // Just to make the external API nice
    public static func migrations() -> TargetMigrations {
        return TargetMigrations(
            identifier: .snodeKit,
            migrations: [
                [
                    _001_InitialSetupMigration.self,
                    _002_SetupStandardJobs.self
                ],  // Initial DB Creation
                [
                    _003_YDBToGRDBMigration.self
                ],  // YDB to GRDB Migration
                [
                    _004_FlagMessageHashAsDeletedOrInvalid.self
                ],  // Legacy DB removal
                [], // Add job priorities
                [], // Fix thread FTS
                [
                    _005_AddSnodeReveivedMessageInfoPrimaryKey.self,
                    _006_DropSnodeCache.self
                ]
            ]
        )
    }
}
