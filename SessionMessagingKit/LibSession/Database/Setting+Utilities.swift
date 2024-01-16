// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public extension Database {
    func setAndUpdateConfig(
        _ key: Setting.BoolKey,
        to newValue: Bool,
        using dependencies: Dependencies
    ) throws {
        try updateConfigIfNeeded(
            self,
            key: key.rawValue,
            updatedSetting: self.setting(key: key, to: newValue),
            using: dependencies
        )
    }

    func setAndUpdateConfig(
        _ key: Setting.DoubleKey,
        to newValue: Double?,
        using dependencies: Dependencies
    ) throws {
        try updateConfigIfNeeded(
            self,
            key: key.rawValue,
            updatedSetting: self.setting(key: key, to: newValue),
            using: dependencies
        )
    }

    func setAndUpdateConfig(
        _ key: Setting.IntKey,
        to newValue: Int?,
        using dependencies: Dependencies
    ) throws {
        try updateConfigIfNeeded(
            self,
            key: key.rawValue,
            updatedSetting: self.setting(key: key, to: newValue),
            using: dependencies
        )
    }

    func setAndUpdateConfig(
        _ key: Setting.StringKey,
        to newValue: String?,
        using dependencies: Dependencies
    ) throws {
        try updateConfigIfNeeded(
            self,
            key: key.rawValue,
            updatedSetting: self.setting(key: key, to: newValue),
            using: dependencies
        )
    }

    func setAndUpdateConfig<T: EnumIntSetting>(
        _ key: Setting.EnumKey,
        to newValue: T?,
        using dependencies: Dependencies
    ) throws {
        try updateConfigIfNeeded(
            self,
            key: key.rawValue,
            updatedSetting: self.setting(key: key, to: newValue),
            using: dependencies
        )
    }

    func setAndUpdateConfig<T: EnumStringSetting>(
        _ key: Setting.EnumKey,
        to newValue: T?,
        using dependencies: Dependencies
    ) throws {
        try updateConfigIfNeeded(
            self,
            key: key.rawValue,
            updatedSetting: self.setting(key: key, to: newValue),
            using: dependencies
        )
    }

    /// Value will be stored as a timestamp in seconds since 1970
    func setAndUpdateConfig(
        _ key: Setting.DateKey,
        to newValue: Date?,
        using dependencies: Dependencies
    ) throws {
        try updateConfigIfNeeded(
            self,
            key: key.rawValue,
            updatedSetting: self.setting(key: key, to: newValue),
            using: dependencies
        )
    }
    
    private func updateConfigIfNeeded(
        _ db: Database,
        key: String,
        updatedSetting: Setting?,
        using dependencies: Dependencies
    ) throws {
        // Before we do anything custom make sure the setting should trigger a change
        guard LibSession.syncedSettings.contains(key) else { return }
        
        defer {
            // If we changed a column that requires a config update then we may as well automatically
            // enqueue a new config sync job once the transaction completes (but only enqueue it once
            // per transaction - doing it more than once is pointless)
            let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
            
            db.afterNextTransactionNestedOnce(dedupeId: LibSession.syncDedupeId(userSessionId.hexString)) { db in
                ConfigurationSyncJob.enqueue(db, sessionIdHexString: userSessionId.hexString)
            }
        }
        
        try LibSession.updatingSetting(db, updatedSetting, using: dependencies)
    }
}
