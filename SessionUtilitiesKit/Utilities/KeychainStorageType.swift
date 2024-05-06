// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SAMKeychain

// MARK: - Singleton

public extension Singleton {
    static let keychain: SingletonConfig<KeychainStorageType> = Dependencies.create(
        identifier: "keychain",
        createInstance: { _ in KeychainStorage() }
    )
}

public enum KeychainStorageError: Error {
    case failure(code: Int32?, description: String)
    
    public var code: Int32? {
        switch self {
            case .failure(let code, _): return code
        }
    }
}

// MARK: - KeychainStorageType

public protocol KeychainStorageType {
    func string(forService service: KeychainStorage.ServiceKey, key: KeychainStorage.StringKey) throws -> String
    func set(string: String, service: KeychainStorage.ServiceKey, key: KeychainStorage.StringKey) throws
    func remove(service: KeychainStorage.ServiceKey, key: KeychainStorage.StringKey) throws
    
    func data(forService service: KeychainStorage.ServiceKey, key: KeychainStorage.DataKey) throws -> Data
    func set(data: Data, service: KeychainStorage.ServiceKey, key: KeychainStorage.DataKey) throws
    func remove(service: KeychainStorage.ServiceKey, key: KeychainStorage.DataKey) throws
    
    func removeAll()
}

// MARK: - KeychainStorage

public class KeychainStorage: KeychainStorageType {
    public func string(forService service: KeychainStorage.ServiceKey, key: KeychainStorage.StringKey) throws -> String {
        var error: NSError?
        let result: String? = SAMKeychain.password(forService: service.rawValue, account: key.rawValue, error: &error)
        
        switch (error, result) {
            case (.some(let error), _):
                throw KeychainStorageError.failure(
                    code: Int32(error.code),
                    description: "[KeychainStorage] Error retrieving string: \(error)"
                )
                
            case (_, .none):
                throw KeychainStorageError.failure(code: nil, description: "[KeychainStorage] Could not retrieve string")
                
            case (_, .some(let string)): return string
        }
    }

    public func set(string: String, service: KeychainStorage.ServiceKey, key: KeychainStorage.StringKey) throws {
        SAMKeychain.setAccessibilityType(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)

        var error: NSError?
        let result: Bool = SAMKeychain.setPassword(string, forService: service.rawValue, account: key.rawValue, error: &error)
        
        switch (error, result) {
            case (.some(let error), _):
                throw KeychainStorageError.failure(
                    code: Int32(error.code),
                    description: "[KeychainStorage] Error setting string: \(error)"
                )
                
            case (_, false):
                throw KeychainStorageError.failure(code: nil, description: "[KeychainStorage] Could not set string")
                
            case (_, true): break
        }
    }
    
    public func remove(service: KeychainStorage.ServiceKey, key: KeychainStorage.StringKey) throws {
        try remove(service: service.rawValue, key: key.rawValue)
    }

    public func data(forService service: KeychainStorage.ServiceKey, key: KeychainStorage.DataKey) throws -> Data {
        var error: NSError?
        let result: Data? = SAMKeychain.passwordData(forService: service.rawValue, account: key.rawValue, error: &error)
        
        switch (error, result) {
            case (.some(let error), _):
                throw KeychainStorageError.failure(
                    code: Int32(error.code),
                    description: "[KeychainStorage] Error retrieving data: \(error)"
                )
                
            case (_, .none):
                throw KeychainStorageError.failure(code: nil, description: "[KeychainStorage] Could not retrieve data")
                
            case (_, .some(let data)): return data
        }
    }

    public func set(data: Data, service: KeychainStorage.ServiceKey, key: KeychainStorage.DataKey) throws {
        SAMKeychain.setAccessibilityType(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)

        var error: NSError?
        let result: Bool = SAMKeychain.setPasswordData(data, forService: service.rawValue, account: key.rawValue, error: &error)
        
        switch (error, result) {
            case (.some(let error), _):
                throw KeychainStorageError.failure(
                    code: Int32(error.code),
                    description: "[KeychainStorage] Error setting data: \(error)"
                )
                
            case (_, false):
                throw KeychainStorageError.failure(code: nil, description: "[KeychainStorage] Could not set data")
                
            case (_, true): break
        }
    }
    
    public func remove(service: KeychainStorage.ServiceKey, key: KeychainStorage.DataKey) throws {
        try remove(service: service.rawValue, key: key.rawValue)
    }
    
    private func remove(service: String, key: String) throws {
        var error: NSError?
        let result: Bool = SAMKeychain.deletePassword(forService: service, account: key, error: &error)
        
        switch (error, result) {
            case (.some(let error), _):
                /// If deletion failed because the specified item could not be found in the keychain, consider it success
                guard error.code != errSecItemNotFound else { return }
                
                throw KeychainStorageError.failure(
                    code: Int32(error.code),
                    description: "[KeychainStorage] Error removing data: \(error)"
                )
                
            case (_, false):
                throw KeychainStorageError.failure(code: nil, description: "[KeychainStorage] Could not remove data")
                
            case (_, true): break
        }
    }
    
    public func removeAll() {
        let allData: [[String: Any]] = SAMKeychain.allAccounts().defaulting(to: [])
        
        allData.forEach { keychainEntry in
            guard
                let service: String = keychainEntry[kSAMKeychainWhereKey] as? String,
                let key: String = keychainEntry[kSAMKeychainAccountKey] as? String
            else { return }
            
            try? remove(service: service, key: key)
        }
    }
}

// MARK: - Keys

public extension KeychainStorage {
    struct ServiceKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
    
    struct DataKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
    
    struct StringKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
}
