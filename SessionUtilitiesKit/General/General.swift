// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

// MARK: - General.Cache

public enum General {
    public class Cache: GeneralCacheType {
        public var sessionId: SessionId? = nil
        public var recentReactionTimestamps: [Int64] = []
    }
}

public extension Cache {
    static let general: CacheConfig<GeneralCacheType, ImmutableGeneralCacheType> = Dependencies.create(
        identifier: "general",
        createInstance: { _ in General.Cache() },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - Convenience

public func getUserSessionId(_ db: Database? = nil, using dependencies: Dependencies = Dependencies()) -> SessionId {
    if let cachedSessionId: SessionId = dependencies[cache: .general].sessionId { return cachedSessionId }
    
    // Can be nil under some circumstances
    if let keyPair: KeyPair = Identity.fetchUserKeyPair(db, using: dependencies) {
        let sessionId: SessionId = SessionId(.standard, publicKey: keyPair.publicKey)
        
        dependencies.mutate(cache: .general) { $0.sessionId = sessionId }
        return sessionId
    }
    
    return SessionId.invalid
}

// MARK: - GeneralCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol ImmutableGeneralCacheType: ImmutableCacheType {
    var sessionId: SessionId? { get }
    var recentReactionTimestamps: [Int64] { get }
}

public protocol GeneralCacheType: ImmutableGeneralCacheType, MutableCacheType {
    var sessionId: SessionId? { get set }
    var recentReactionTimestamps: [Int64] { get set }
}
