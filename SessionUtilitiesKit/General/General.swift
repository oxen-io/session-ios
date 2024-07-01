// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

// MARK: - General.Cache

public enum General {
    public class Cache: GeneralCacheType {
        public var encodedPublicKey: String? = nil
        public var recentReactionTimestamps: [Int64] = []
        
        public func clearCachedUserPublicKey() {
            encodedPublicKey = nil
        }
    }
}

public extension Cache {
    static let general: CacheInfo.Config<GeneralCacheType, ImmutableGeneralCacheType> = CacheInfo.create(
        createInstance: { General.Cache() },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - GeneralError

public enum GeneralError: Error {
    case invalidSeed
    case keyGenerationFailed
    case randomGenerationFailed
}

// MARK: - Convenience

public func getUserHexEncodedPublicKey(_ db: Database? = nil, using dependencies: Dependencies = Dependencies()) -> String {
    if let cachedKey: String = dependencies.caches[.general].encodedPublicKey { return cachedKey }
    
    if let publicKey: Data = Identity.fetchUserPublicKey(db) { // Can be nil under some circumstances
        let sessionId: SessionId = SessionId(.standard, publicKey: publicKey.bytes)
        
        dependencies.caches.mutate(cache: .general) { $0.encodedPublicKey = sessionId.hexString }
        return sessionId.hexString
    }
    
    return ""
}

// MARK: - GeneralCacheType

/// This is a read-only version of the `General.Cache` designed to avoid unintentionally mutating the instance in a
/// non-thread-safe way
public protocol ImmutableGeneralCacheType: ImmutableCacheType {
    var encodedPublicKey: String? { get }
    var recentReactionTimestamps: [Int64] { get }
}

public protocol GeneralCacheType: ImmutableGeneralCacheType, MutableCacheType {
    var encodedPublicKey: String? { get set }
    var recentReactionTimestamps: [Int64] { get set }
    
    func clearCachedUserPublicKey()
}
