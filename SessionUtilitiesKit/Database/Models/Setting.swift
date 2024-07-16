// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

// MARK: - Setting

public struct Setting: Codable, Identifiable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "setting" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case key
        case value
    }
    
    public var id: String { key }
    public var rawValue: Data { value }
    
    let key: String
    let value: Data
}

extension Setting {
    // MARK: - Numeric Setting
    
    fileprivate init?<T: Numeric>(key: String, value: T?) {
        guard let value: T = value else { return nil }
        
        var targetValue: T = value
        
        self.key = key
        self.value = Data(bytes: &targetValue, count: MemoryLayout.size(ofValue: targetValue))
    }
    
    fileprivate func value<T: Numeric>(as type: T.Type) -> T? {
        // Note: The 'assumingMemoryBound' is essentially going to try to convert
        // the memory into the provided type so can result in invalid data being
        // returned if the type is incorrect. But it does seem safer than the 'load'
        // method which crashed under certain circumstances (an `Int` value of 0)
        return value.withUnsafeBytes {
            $0.baseAddress?.assumingMemoryBound(to: T.self).pointee
        }
    }
    
    // MARK: - Bool Setting
    
    fileprivate init?(key: String, value: Bool?) {
        guard let value: Bool = value else { return nil }
        
        var targetValue: Bool = value
        
        self.key = key
        self.value = Data(bytes: &targetValue, count: MemoryLayout.size(ofValue: targetValue))
    }
    
    public func unsafeValue(as type: Bool.Type) -> Bool? {
        // Note: The 'assumingMemoryBound' is essentially going to try to convert
        // the memory into the provided type so can result in invalid data being
        // returned if the type is incorrect. But it does seem safer than the 'load'
        // method which crashed under certain circumstances (an `Int` value of 0)
        return value.withUnsafeBytes {
            $0.baseAddress?.assumingMemoryBound(to: Bool.self).pointee
        }
    }
    
    // MARK: - String Setting
    
    fileprivate init?(key: String, value: String?) {
        guard
            let value: String = value,
            let valueData: Data = value.data(using: .utf8)
        else { return nil }
        
        self.key = key
        self.value = valueData
    }
    
    fileprivate func value(as type: String.Type) -> String? {
        return String(data: value, encoding: .utf8)
    }
}

// MARK: - Keys

public extension Setting {
    struct BoolKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
    
    struct DateKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
    
    struct DoubleKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
    
    struct IntKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
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
    
    struct EnumKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
}

public protocol EnumIntSetting: RawRepresentable where RawValue == Int {}
public protocol EnumStringSetting: RawRepresentable where RawValue == String {}

// MARK: - GRDB Interactions

public extension Database {
    private subscript(key: String) -> Setting? {
        get { try? Setting.filter(id: key).fetchOne(self) }
        set {
            guard let newValue: Setting = newValue else {
                _ = try? Setting.filter(id: key).deleteAll(self)
                return
            }
            
            try? newValue.upsert(self)
        }
    }
    
    subscript(key: Setting.BoolKey) -> Bool {
        get {
            // Default to false if it doesn't exist
            (self[key.rawValue]?.unsafeValue(as: Bool.self) ?? false)
        }
        set { self[key.rawValue] = Setting(key: key.rawValue, value: newValue) }
    }
    
    subscript(key: Setting.DoubleKey) -> Double? {
        get { self[key.rawValue]?.value(as: Double.self) }
        set { self[key.rawValue] = Setting(key: key.rawValue, value: newValue) }
    }
    
    subscript(key: Setting.IntKey) -> Int? {
        get { self[key.rawValue]?.value(as: Int.self) }
        set { self[key.rawValue] = Setting(key: key.rawValue, value: newValue) }
    }
    
    subscript(key: Setting.StringKey) -> String? {
        get { self[key.rawValue]?.value(as: String.self) }
        set { self[key.rawValue] = Setting(key: key.rawValue, value: newValue) }
    }
    
    subscript<T: EnumIntSetting>(key: Setting.EnumKey) -> T? {
        get {
            guard let rawValue: Int = self[key.rawValue]?.value(as: Int.self) else {
                return nil
            }
            
            return T(rawValue: rawValue)
        }
        set { self[key.rawValue] = Setting(key: key.rawValue, value: newValue?.rawValue) }
    }
    
    subscript<T: EnumStringSetting>(key: Setting.EnumKey) -> T? {
        get {
            guard let rawValue: String = self[key.rawValue]?.value(as: String.self) else {
                return nil
            }
            
            return T(rawValue: rawValue)
        }
        set { self[key.rawValue] = Setting(key: key.rawValue, value: newValue?.rawValue) }
    }
    
    /// Value will be stored as a timestamp in seconds since 1970
    subscript(key: Setting.DateKey) -> Date? {
        get {
            let timestamp: TimeInterval? = self[key.rawValue]?.value(as: TimeInterval.self)
            
            return timestamp.map { Date(timeIntervalSince1970: $0) }
        }
        set {
            self[key.rawValue] = Setting(
                key: key.rawValue,
                value: newValue.map { $0.timeIntervalSince1970 }
            )
        }
    }
    
    func setting(key: Setting.BoolKey, to newValue: Bool) -> Setting? {
        let result: Setting? = Setting(key: key.rawValue, value: newValue)
        self[key.rawValue] = result
        return result
    }
    
    func setting(key: Setting.DoubleKey, to newValue: Double?) -> Setting? {
        let result: Setting? = Setting(key: key.rawValue, value: newValue)
        self[key.rawValue] = result
        return result
    }
    
    func setting(key: Setting.IntKey, to newValue: Int?) -> Setting? {
        let result: Setting? = Setting(key: key.rawValue, value: newValue)
        self[key.rawValue] = result
        return result
    }
    
    func setting(key: Setting.StringKey, to newValue: String?) -> Setting? {
        let result: Setting? = Setting(key: key.rawValue, value: newValue)
        self[key.rawValue] = result
        return result
    }
    
    func setting<T: EnumIntSetting>(key: Setting.EnumKey, to newValue: T?) -> Setting? {
        let result: Setting? = Setting(key: key.rawValue, value: newValue?.rawValue)
        self[key.rawValue] = result
        return result
    }
    
    func setting<T: EnumStringSetting>(key: Setting.EnumKey, to newValue: T?) -> Setting? {
        let result: Setting? = Setting(key: key.rawValue, value: newValue?.rawValue)
        self[key.rawValue] = result
        return result
    }
    
    /// Value will be stored as a timestamp in seconds since 1970
    func setting(key: Setting.DateKey, to newValue: Date?) -> Setting? {
        let result: Setting? = Setting(key: key.rawValue, value: newValue.map { $0.timeIntervalSince1970 })
        self[key.rawValue] = result
        return result
    }
}
