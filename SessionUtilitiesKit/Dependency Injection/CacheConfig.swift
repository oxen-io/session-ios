// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - Cache

public class Cache {}

// MARK: - Cache Types

public protocol MutableCacheType {}
public protocol ImmutableCacheType {}

// MARK: - CacheInfo

public class CacheConfig<M, I>: Cache {
    public let identifier: String
    public let createInstance: (Dependencies) -> M
    public let mutableInstance: (M) -> MutableCacheType
    public let immutableInstance: (M) -> I
    
    fileprivate init(
        identifier: String,
        createInstance: @escaping (Dependencies) -> M,
        mutableInstance: @escaping (M) -> MutableCacheType,
        immutableInstance: @escaping (M) -> I
    ) {
        self.identifier = identifier
        self.createInstance = createInstance
        self.mutableInstance = mutableInstance
        self.immutableInstance = immutableInstance
    }
}

// MARK: - Creation

public extension Dependencies {
    static func create<M, I>(
        identifier: String,
        createInstance: @escaping (Dependencies) -> M,
        mutableInstance: @escaping (M) -> MutableCacheType,
        immutableInstance: @escaping (M) -> I
    ) -> CacheConfig<M, I> {
        return CacheConfig(
            identifier: identifier,
            createInstance: createInstance,
            mutableInstance: mutableInstance,
            immutableInstance: immutableInstance
        )
    }
}
