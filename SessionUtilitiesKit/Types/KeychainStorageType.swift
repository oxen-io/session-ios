// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import KeychainSwift

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
    func string(forKey key: KeychainStorage.StringKey) throws -> String
    func set(string: String, forKey key: KeychainStorage.StringKey) throws
    func remove(key: KeychainStorage.StringKey) throws
    
    func data(forKey key: KeychainStorage.DataKey) throws -> Data
    func set(data: Data, forKey key: KeychainStorage.DataKey) throws
    func remove(key: KeychainStorage.DataKey) throws
    
    func removeAll() throws
}

// MARK: - KeychainStorage

public class KeychainStorage: KeychainStorageType {
    private let keychain: KeychainSwift = {
        let result: KeychainSwift = KeychainSwift()
        result.synchronizable = false // This is the default but better to be explicit
        
        return result
    }()
    
    public func string(forKey key: KeychainStorage.StringKey) throws -> String {
        guard let result: String = keychain.get(key.rawValue) else {
            throw KeychainStorageError.failure(
                code: Int32(keychain.lastResultCode),
                description: "[KeychainStorage] Error retrieving string, OSStatusCode: \(keychain.lastResultCode)"
            )
        }
        
        return result
    }

    public func set(string: String, forKey key: KeychainStorage.StringKey) throws {
        guard keychain.set(string, forKey: key.rawValue, withAccess: .accessibleAfterFirstUnlockThisDeviceOnly) else {
            throw KeychainStorageError.failure(
                code: Int32(keychain.lastResultCode),
                description: "[KeychainStorage] Error setting string, OSStatusCode: \(keychain.lastResultCode)"
            )
        }
    }
    
    public func remove(key: KeychainStorage.StringKey) throws {
        try remove(key: key.rawValue)
    }

    public func data(forKey key: KeychainStorage.DataKey) throws -> Data {
        guard let result: Data = keychain.getData(key.rawValue) else {
            throw KeychainStorageError.failure(
                code: Int32(keychain.lastResultCode),
                description: "[KeychainStorage] Error retrieving data, OSStatusCode: \(keychain.lastResultCode)"
            )
        }
        
        return result
    }

    public func set(data: Data, forKey key: KeychainStorage.DataKey) throws {
        guard keychain.set(data, forKey: key.rawValue, withAccess: .accessibleAfterFirstUnlockThisDeviceOnly) else {
            throw KeychainStorageError.failure(
                code: Int32(keychain.lastResultCode),
                description: "[KeychainStorage] Error setting data, OSStatusCode: \(keychain.lastResultCode)"
            )
        }
    }
    
    public func remove(key: KeychainStorage.DataKey) throws {
        try remove(key: key.rawValue)
    }
    
    private func remove(key: String) throws {
        guard keychain.delete(key) else {
            throw KeychainStorageError.failure(
                code: Int32(keychain.lastResultCode),
                description: "[KeychainStorage] Error removing data, OSStatusCode: \(keychain.lastResultCode)"
            )
        }
    }
    
    public func removeAll() throws {
        guard keychain.clear() else {
            throw KeychainStorageError.failure(
                code: Int32(keychain.lastResultCode),
                description: "[KeychainStorage] Error clearing data, OSStatusCode: \(keychain.lastResultCode)"
            )
        }
    }
}

// MARK: - Keys

public extension KeychainStorage {
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
