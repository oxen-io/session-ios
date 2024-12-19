// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

public extension LibSession {
    struct ValueAccessor {
        private let dependencies: Dependencies
        private let config: Config?
        
        init(_ config: Config? = nil, using dependencies: Dependencies) {
            self.dependencies = dependencies
            self.config = config
        }
    }
}

extension Optional<LibSession.Config> {
    func using(_ dependencies: Dependencies) -> LibSession.ValueAccessor {
        return LibSession.ValueAccessor(self, using: dependencies)
    }
}

extension LibSession.ValueAccessor: LibSessionValueAccessor {
    public func pinnedPriority(
        _ db: Database,
        threadId id: String,
        threadVariant variant: SessionThread.Variant
    ) -> Int32? {
        switch config {
            case .viaCache(let cache, _): return cache.pinnedPriority(db, threadId: id, threadVariant: variant)
            case .some(let config): return config.pinnedPriority(db, threadId: id, threadVariant: variant)
            case .none:
                return dependencies.mutate(cache: .libSession) { cache in
                    cache.pinnedPriority(db, threadId: id, threadVariant: variant)
                }
        }
    }
    
    public func disappearingMessagesConfig(
        threadId id: String,
        threadVariant variant: SessionThread.Variant
    ) -> DisappearingMessagesConfiguration? {
        switch config {
            case .viaCache(let cache, _): return cache.disappearingMessagesConfig(threadId: id, threadVariant: variant)
            case .some(let config): return config.disappearingMessagesConfig(threadId: id, threadVariant: variant)
            case .none:
                return dependencies.mutate(cache: .libSession) { cache in
                    cache.disappearingMessagesConfig(threadId: id, threadVariant: variant)
                }
        }
    }
    
    public func isAdmin(groupSessionId: SessionId) -> Bool {
        switch config {
            case .viaCache(let cache, _): return cache.isAdmin(groupSessionId: groupSessionId)
            case .some(let config): return config.isAdmin(groupSessionId: groupSessionId)
            case .none:
                return dependencies.mutate(cache: .libSession) { cache in
                    cache.isAdmin(groupSessionId: groupSessionId)
                }
        }
    }
}


public protocol LibSessionValueAccessor {
    func pinnedPriority(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> Int32?
    func disappearingMessagesConfig(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> DisappearingMessagesConfiguration?
    func isAdmin(groupSessionId: SessionId) -> Bool
}
