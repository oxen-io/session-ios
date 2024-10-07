// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB

// MARK: - Cache

public extension Cache {
    static let general: CacheConfig<GeneralCacheType, ImmutableGeneralCacheType> = Dependencies.create(
        identifier: "general",
        createInstance: { _ in General.Cache() },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - General.Cache

public enum General {
    public class Cache: GeneralCacheType {
        public var sessionId: SessionId = SessionId.invalid
        public var recentReactionTimestamps: [Int64] = []
        public var placeholderCache: NSCache<NSString, UIImage> = {
            let result = NSCache<NSString, UIImage>()
            result.countLimit = 50
            
            return result
        }()
        public var contextualActionLookupMap: [Int: [String: [Int: Any]]] = [:]
        
        // MARK: - Functions
        
        public func setCachedSessionId(sessionId: SessionId) {
            self.sessionId = sessionId
        }
    }
}

// MARK: - GeneralCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol ImmutableGeneralCacheType: ImmutableCacheType {
    var sessionId: SessionId { get }
    var recentReactionTimestamps: [Int64] { get }
    var placeholderCache: NSCache<NSString, UIImage> { get }
    var contextualActionLookupMap: [Int: [String: [Int: Any]]] { get }
}

public protocol GeneralCacheType: ImmutableGeneralCacheType, MutableCacheType {
    var sessionId: SessionId { get }
    var recentReactionTimestamps: [Int64] { get set }
    var placeholderCache: NSCache<NSString, UIImage> { get }
    var contextualActionLookupMap: [Int: [String: [Int: Any]]] { get set }
    
    func setCachedSessionId(sessionId: SessionId)
}
