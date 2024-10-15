// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

class MockKeychain: Mock<KeychainStorageType>, KeychainStorageType {
    func string(forKey key: KeychainStorage.StringKey) throws -> String {
        return try mockThrowing(args: [key])
    }
    
    func set(string: String, forKey key: KeychainStorage.StringKey) throws {
        return try mockThrowing(args: [key])
    }
    
    func remove(key: KeychainStorage.StringKey) throws {
        return try mockThrowing(args: [key])
    }
    
    func data(forKey key: KeychainStorage.DataKey) throws -> Data {
        return try mockThrowing(args: [key])
    }
    
    func set(data: Data, forKey key: KeychainStorage.DataKey) throws {
        return try mockThrowing(args: [key])
    }
    
    func remove(key: KeychainStorage.DataKey) throws {
        return try mockThrowing(args: [key])
    }
    
    func removeAll() throws { try mockThrowingNoReturn() }
    
    func migrateLegacyKeyIfNeeded(legacyKey: String, legacyService: String?, toKey key: KeychainStorage.DataKey) throws {
        try mockThrowingNoReturn(args: [legacyKey, legacyService, key])
    }
}

