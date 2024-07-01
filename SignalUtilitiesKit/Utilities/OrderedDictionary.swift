//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.

import Foundation
import SessionUtilitiesKit

public class OrderedDictionary<KeyType: Hashable, ValueType> {

    private var keyValueMap = [KeyType: ValueType]()

    public var orderedKeys = [KeyType]()

    public init() { }

    // Used to clone copies of instances of this class.
    public init(keyValueMap: [KeyType: ValueType],
                orderedKeys: [KeyType]) {

        self.keyValueMap = keyValueMap
        self.orderedKeys = orderedKeys
    }

    // Since the contents are immutable, we only modify copies
    // made with this method.
    public func clone() -> OrderedDictionary<KeyType, ValueType> {
        return OrderedDictionary(keyValueMap: keyValueMap, orderedKeys: orderedKeys)
    }

    public func value(forKey key: KeyType) -> ValueType? {
        return keyValueMap[key]
    }

    public func hasValue(forKey key: KeyType) -> Bool {
        return keyValueMap[key] != nil
    }

    public func append(key: KeyType, value: ValueType) {
        if keyValueMap[key] != nil {
            Log.error("[OrderedDictionary] Unexpected duplicate key in key map: \(key)")
        }
        keyValueMap[key] = value

        if orderedKeys.contains(key) {
            Log.error("[OrderedDictionary] Unexpected duplicate key in key list: \(key)")
        } else {
            orderedKeys.append(key)
        }

        if orderedKeys.count != keyValueMap.count {
            Log.error("[OrderedDictionary] Invalid contents.")
        }
    }

    public func replace(key: KeyType, value: ValueType) {
        if keyValueMap[key] == nil {
            Log.error("[OrderedDictionary] Missing key in key map: \(key)")
        }
        keyValueMap[key] = value

        if !orderedKeys.contains(key) {
            Log.error("[OrderedDictionary] Missing key in key list: \(key)")
        }

        if orderedKeys.count != keyValueMap.count {
            Log.error("[OrderedDictionary] Invalid contents.")
        }
    }

    public func remove(key: KeyType) {
        if keyValueMap[key] == nil {
            Log.error("[OrderedDictionary] Missing key in key map: \(key)")
        } else {
            keyValueMap.removeValue(forKey: key)
        }

        if !orderedKeys.contains(key) {
            Log.error("[OrderedDictionary] Missing key in key list: \(key)")
        } else {
            orderedKeys = orderedKeys.filter { $0 != key }
        }

        if orderedKeys.count != keyValueMap.count {
            Log.error("[OrderedDictionary] Invalid contents.")
        }
    }

    public var count: Int {
        if orderedKeys.count != keyValueMap.count {
            Log.error("[OrderedDictionary] Invalid contents.")
        }
        return orderedKeys.count
    }

    public var orderedValues: [ValueType] {
        var values = [ValueType]()
        for key in orderedKeys {
            guard let value = self.keyValueMap[key] else {
                Log.error("[OrderedDictionary] Missing value")
                continue
            }
            values.append(value)
        }
        return values
    }
    
    public var orderedItems: [(KeyType, ValueType)] {
        var items = [(KeyType, ValueType)]()
        for key in orderedKeys {
            guard let value = self.keyValueMap[key] else {
                Log.error("[OrderedDictionary] Missing value")
                continue
            }
            items.append((key, value))
        }
        return items
    }
}
