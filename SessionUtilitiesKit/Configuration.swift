// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit.UIFont
import GRDB

public enum SNUtilitiesKit: MigratableTarget { // Just to make the external API nice
    public static var maxFileSize: UInt = 0
    public static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil   // stringlint:ignore
    }
    fileprivate static var localizedFormatted: (LocalizationHelper, UIFont) -> NSAttributedString = { _, _ in NSAttributedString() }
    fileprivate static var localizedDeformatted: (LocalizationHelper) -> String = { _ in "" }

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

    public static func configure(
        networkMaxFileSize: UInt,
        localizedFormatted: @escaping (LocalizationHelper, UIFont) -> NSAttributedString,
        localizedDeformatted: @escaping (LocalizationHelper) -> String,
        using dependencies: Dependencies
    ) {
        self.maxFileSize = networkMaxFileSize
        self.localizedFormatted = localizedFormatted
        self.localizedDeformatted = localizedDeformatted
    }
}

// MARK: - SNUIKit Localization

public extension String {
    func localizedFormatted(baseFont: UIFont) -> NSAttributedString {
        return SNUtilitiesKit.localizedFormatted(LocalizationHelper(template: self), baseFont)
    }
    
    func localizedDeformatted() -> String {
        return SNUtilitiesKit.localizedDeformatted(LocalizationHelper(template: self))
    }
}

public extension LocalizationHelper {
    func localizedFormatted(baseFont: UIFont) -> NSAttributedString {
        return SNUtilitiesKit.localizedFormatted(self, baseFont)
    }
    
    func localizedDeformatted() -> String {
        return SNUtilitiesKit.localizedDeformatted(self)
    }
}
