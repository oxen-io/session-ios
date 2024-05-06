// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public enum SNUtilitiesKit: MigratableTarget { // Just to make the external API nice
    public static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil   // stringlint:disable
    }

    public static func migrations() -> TargetMigrations {
        return TargetMigrations(
            identifier: .utilitiesKit,
            migrations: [
                [
                    // Intentionally including the '_003_YDBToGRDBMigration' in the first migration
                    // set to ensure the 'Identity' data is migrated before any other migrations are
                    // run (some need access to the users publicKey)
                    _001_InitialSetupMigration.self,
                    _002_SetupStandardJobs.self,
                    _003_YDBToGRDBMigration.self
                ],  // Initial DB Creation
                [], // YDB to GRDB Migration
                [], // Legacy DB removal
                [
                    _004_AddJobPriority.self
                ],  // Add job priorities
                [], // Fix thread FTS
                [
                    _005_AddJobUniqueHash.self
                ]
            ]
        )
    }

    public static func configure(maxFileSize: UInt, using dependencies: Dependencies) {
        SNUtilitiesKitConfiguration.maxFileSize = maxFileSize
        
        // Configure the job executors
        let executors: [Job.Variant: JobExecutor.Type] = [
            .manualResultJob: ManualResultJob.self
        ]
        
        executors.forEach { variant, executor in
            dependencies[singleton: .jobRunner].setExecutor(executor, for: variant)
        }
    }
}

@objc public final class SNUtilitiesKitConfiguration: NSObject {
    @objc public static var maxFileSize: UInt = 0
    @objc public static var isRunningTests: Bool { return SNUtilitiesKit.isRunningTests }
}
