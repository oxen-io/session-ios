// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

class MockKeychain: Mock<KeychainStorageType>, KeychainStorageType {
    func string(forService service: KeychainStorage.ServiceKey, key: KeychainStorage.StringKey) throws -> String {
        return try mockThrowing(args: [service, key])
    }
    
    func set(string: String, service: KeychainStorage.ServiceKey, key: KeychainStorage.StringKey) throws {
        return try mockThrowing(args: [service, key])
    }
    
    func remove(service: KeychainStorage.ServiceKey, key: KeychainStorage.StringKey) throws {
        return try mockThrowing(args: [service, key])
    }
    
    func data(forService service: KeychainStorage.ServiceKey, key: KeychainStorage.DataKey) throws -> Data {
        return try mockThrowing(args: [service, key])
    }
    
    func set(data: Data, service: KeychainStorage.ServiceKey, key: KeychainStorage.DataKey) throws {
        return try mockThrowing(args: [service, key])
    }
    
    func remove(service: KeychainStorage.ServiceKey, key: KeychainStorage.DataKey) throws {
        return try mockThrowing(args: [service, key])
    }
    
    func removeAll() { mockNoReturn() }
}

