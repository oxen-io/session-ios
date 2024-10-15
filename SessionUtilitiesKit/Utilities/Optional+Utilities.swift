// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension Optional {
    public func map<U>(_ transform: (Wrapped) throws -> U?) rethrows -> U? {
        switch self {
            case .some(let value): return try transform(value)
            default: return nil
        }
    }
    
    public func asType<R>(_ type: R.Type) -> R? {
        switch self {
            case .some(let value): return (value as? R)
            default: return nil
        }
    }
    
    public func defaulting(to value: Wrapped) -> Wrapped {
        return (self ?? value)
    }
    
    public func mapOrThrow<U>(error: Error, _ transform: (Wrapped) throws -> U) throws -> U {
        switch self {
            case .none: throw error
            case .some(let value): return try transform(value)
        }
    }
    
    public mutating func setting(to value: Wrapped) -> Wrapped {
        self = value
        return value
    }
}

extension Optional where Wrapped == String {
    public func defaulting(to value: Wrapped, useDefaultIfEmpty: Bool = false) -> Wrapped {
        guard !useDefaultIfEmpty || self?.isEmpty != true else { return value }
        
        return (self ?? value)
    }
}
