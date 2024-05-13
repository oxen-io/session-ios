// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public extension Database {
    func setAndUpdateConfig(_ key: Setting.BoolKey, to newValue: Bool) throws {
        try updateConfigIfNeeded(self, key: key.rawValue, updatedSetting: self.setting(key: key, to: newValue))
    }

    func setAndUpdateConfig(_ key: Setting.DoubleKey, to newValue: Double?) throws {
        try updateConfigIfNeeded(self, key: key.rawValue, updatedSetting: self.setting(key: key, to: newValue))
    }

    func setAndUpdateConfig(_ key: Setting.IntKey, to newValue: Int?) throws {
        try updateConfigIfNeeded(self, key: key.rawValue, updatedSetting: self.setting(key: key, to: newValue))
    }

    func setAndUpdateConfig(_ key: Setting.StringKey, to newValue: String?) throws {
        try updateConfigIfNeeded(self, key: key.rawValue, updatedSetting: self.setting(key: key, to: newValue))
    }

    func setAndUpdateConfig<T: EnumIntSetting>(_ key: Setting.EnumKey, to newValue: T?) throws {
        try updateConfigIfNeeded(self, key: key.rawValue, updatedSetting: self.setting(key: key, to: newValue))
    }

    func setAndUpdateConfig<T: EnumStringSetting>(_ key: Setting.EnumKey, to newValue: T?) throws {
        try updateConfigIfNeeded(self, key: key.rawValue, updatedSetting: self.setting(key: key, to: newValue))
    }

    /// Value will be stored as a timestamp in seconds since 1970
    func setAndUpdateConfig(_ key: Setting.DateKey, to newValue: Date?) throws {
        try updateConfigIfNeeded(self, key: key.rawValue, updatedSetting: self.setting(key: key, to: newValue))
    }
    
    private func updateConfigIfNeeded(
        _ db: Database,
        key: String,
        updatedSetting: Setting?
    ) throws {
        // Before we do anything custom make sure the setting should trigger a change
        guard LibSession.syncedSettings.contains(key) else { return }
        
        defer {
            // If we changed a column that requires a config update then we may as well automatically
            // enqueue a new config sync job once the transaction completes (but only enqueue it once
            // per transaction - doing it more than once is pointless)
            let userPublicKey: String = getUserHexEncodedPublicKey(db)
            
            db.afterNextTransactionNestedOnce(dedupeId: LibSession.syncDedupeId(userPublicKey)) { db in
                ConfigurationSyncJob.enqueue(db, publicKey: userPublicKey)
            }
        }
        
        try LibSession.updatingSetting(db, updatedSetting)
    }
}
