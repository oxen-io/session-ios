// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public enum SNUIKit: MigratableTarget {
    internal static let mainWindow: Atomic<UIWindow?> = Atomic(nil)
    
    public static func migrations() -> TargetMigrations {
        return TargetMigrations(
            identifier: .uiKit,
            migrations: [
                // Want to ensure the initial DB stuff has been completed before doing any
                // SNUIKit migrations
                [], // Initial DB Creation
                [], // YDB to GRDB Migration
                [], // Legacy DB removal
                [
                    _001_ThemePreferences.self
                ],  // Add job priorities
                [], // Fix thread FTS
                []
            ]
        )
    }
    
    public static func configure() {
    }
    
    public static func setMainWindow(_ mainWindow: UIWindow) {
        SNUIKit.mainWindow.mutate { $0 = mainWindow }
    }
}
