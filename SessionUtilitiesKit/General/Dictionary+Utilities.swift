// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public extension Dictionary {
    
    var prettifiedDescription: String {
        return "[ " + map { key, value in
            let keyDescription = String(describing: key)
            let valueDescription = String(describing: value)
            let maxLength = 50
            let truncatedValueDescription = valueDescription.count > maxLength ? valueDescription.prefix(maxLength) + "..." : valueDescription
            return keyDescription + " : " + truncatedValueDescription
        }.joined(separator: ", ") + " ]"
    }
    
    func asArray() -> [(key: Key, value: Value)] {
        return Array(self)
    }
}

public extension Dictionary.Values {
    func asArray() -> [Value] {
        return Array(self)
    }
}

// MARK: - Functional Convenience

public extension Dictionary {
    subscript(_ key: Key?) -> Value? {
        guard let key: Key = key else { return nil }
        
        return self[key]
    }
    
    func getting(_ key: Key?) -> Value? {
        guard let key: Key = key else { return nil }
        
        return self[key]
    }
    
    func setting(_ key: Key?, _ value: Value?) -> [Key: Value] {
        guard let key: Key = key else { return self }
        
        var updatedDictionary: [Key: Value] = self
        updatedDictionary[key] = value
        
        return updatedDictionary
    }
    
    func updated(with other: [Key: Value]) -> [Key: Value] {
        var updatedDictionary: [Key: Value] = self
        
        other.forEach { key, value in
            updatedDictionary[key] = value
        }
        
        return updatedDictionary
    }
    
    func removingValue(forKey key: Key?) -> [Key: Value] {
        guard let key: Key = key else { return self }
        
        var updatedDictionary: [Key: Value] = self
        updatedDictionary.removeValue(forKey: key)
        
        return updatedDictionary
    }
    
    func nullIfEmpty() -> [Key: Value]? {
        guard !isEmpty else { return nil }
        
        return self
    }

    mutating func append<T>(_ value: T?, toArrayOn key: Key?) where Value == [T] {
        guard let key: Key = key, let value: T = value else { return }
        
        self[key] = (self[key] ?? []).appending(value)
    }
    
    func appending<T>(_ value: T?, toArrayOn key: Key?) -> [Key: Value] where Value == [T] {
        var updatedDictionary: [Key: Value] = self
        updatedDictionary.append(value, toArrayOn: key)
        
        return updatedDictionary
    }
}

public extension Dictionary where Value: Hashable {
    func groupedByValue() -> [Value: [Key]] {
        return self.reduce(into: [:]) { result, next in
            result[next.value, default: []].append(next.key)
        }
    }
}

extension Dictionary where Value == Array<() -> Void> {
    mutating func appendTo(_ key: Key?, _ value: @escaping () -> Void) {
        guard let key: Key = key else { return }
        
        self[key] = (self[key] ?? []).appending(value)
    }
}
