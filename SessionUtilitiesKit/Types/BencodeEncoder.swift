// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

// MARK: - BencodeEncoder

public struct BencodeEncoder {
    private let dependencies: Dependencies
    public var userInfo: [CodingUserInfoKey: Any]
    
    public init(userInfo: [CodingUserInfoKey: Any] = [:], using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.userInfo = userInfo
        self.userInfo[Dependencies.userInfoKey] = dependencies
    }

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder: _BencodeEncoder = _BencodeEncoder(userInfo: userInfo, using: dependencies)
        try value.encode(to: encoder)
        
        switch encoder.container {
            case let bencodeContainer as _BencodeEncoder.UnkeyedContainer:
                return (encoder.data + (bencodeContainer.additionalData ?? Data()))
                
            default: return encoder.data
        }
    }
}

// MARK: - AdditionalData Support

public extension UnkeyedEncodingContainer {
    mutating func encodeAdditionalData<T>(_ data: T) throws where T: Encodable, T: DataProtocol {
        let finalData: Data = try {
            switch data {
                case let value as Data: return value
                case let value as [UInt8]: return Data(value)
                default:
                    throw EncodingError.invalidValue(
                        data,
                        EncodingError.Context(
                            codingPath: codingPath,
                            debugDescription: "unable to encode additional data"
                        )
                    )
            }
        }()
        
        switch self {
            case let bencodeContainer as _BencodeEncoder.UnkeyedContainer: bencodeContainer.additionalData = finalData
            default: try self.encode(finalData)
        }
    }
}

// MARK: - _BencodeEncodingContainer

protocol _BencodeEncodingContainer: AnyObject {
    var dependencies: Dependencies { get }
    var data: Data { get }
}

// MARK: - _BencodeEncoder

final class _BencodeEncoder {
    let dependencies: Dependencies
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]
    
    fileprivate var container: _BencodeEncodingContainer?
    
    var data: Data {
        return container?.data ?? Data()
    }
    
    init(codingPath: [CodingKey] = [], userInfo: [CodingUserInfoKey: Any], using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.codingPath = codingPath
        self.userInfo = userInfo
    }
}

extension _BencodeEncoder: Encoder {
    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        let container: KeyedContainer<Key> = KeyedContainer(codingPath: codingPath, userInfo: userInfo, using: dependencies)
        self.container = container
        
        return KeyedEncodingContainer(container)
    }
    
    func unkeyedContainer() -> UnkeyedEncodingContainer {
        let container = UnkeyedContainer(codingPath: self.codingPath, userInfo: self.userInfo, using: dependencies)
        self.container = container
        
        return container
    }
    
    func singleValueContainer() -> SingleValueEncodingContainer {
        let container = SingleValueContainer(codingPath: self.codingPath, userInfo: self.userInfo, using: dependencies)
        self.container = container
        
        return container
    }
}

// MARK: - KeyedContainer

private extension _BencodeEncoder {
    class KeyedContainer<Key> where Key: CodingKey {
        private var storage: [String: (any _BencodeEncodingContainer)] = [:]
        let dependencies: Dependencies
        var codingPath: [CodingKey]
        var userInfo: [CodingUserInfoKey: Any]
        
        init(codingPath: [CodingKey], userInfo: [CodingUserInfoKey: Any], using dependencies: Dependencies) {
            self.dependencies = dependencies
            self.codingPath = codingPath
            self.userInfo = userInfo
        }
    }
}

extension _BencodeEncoder.KeyedContainer: _BencodeEncodingContainer {
    var data: Data {
        (
            Data(Bencode.Element.dictIndicator.rawValue.utf8.map { UInt8($0) }) +
            storage
                .sorted(by: { $0.key < $1.key })    // Should be in lexicographical order
                .map { key, value in
                    (
                        try! _BencodeEncoder.SingleValueContainer.encodedString(key, codingPath: codingPath) +
                        value.data
                    )
                }
                .reduce(Data(), +) +
            Data(Bencode.Element.endIndicator.rawValue.utf8.map { UInt8($0) })
        )
    }
}

extension _BencodeEncoder.KeyedContainer: KeyedEncodingContainerProtocol {
    func encodeNil(forKey key: Key) throws {}   // Just omit nil elements
    
    func encode<T>(_ value: T, forKey key: Key) throws where T: Encodable {
        var container = self.nestedSingleValueContainer(forKey: key)
        try container.encode(value)
    }
    
    private func nestedSingleValueContainer(forKey key: Key) -> SingleValueEncodingContainer {
        let container = _BencodeEncoder.SingleValueContainer(
            codingPath: codingPath + [key],
            userInfo: userInfo,
            using: dependencies
        )
        storage[key.stringValue] = container
        return container
    }
    
    func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let container = _BencodeEncoder.UnkeyedContainer(
            codingPath: codingPath + [key],
            userInfo: userInfo,
            using: dependencies
        )
        storage[key.stringValue] = container
        return container
    }
    
    func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let container = _BencodeEncoder.KeyedContainer<NestedKey>(
            codingPath: codingPath + [key],
            userInfo: userInfo,
            using: dependencies
        )
        storage[key.stringValue] = container
        return KeyedEncodingContainer(container)
    }
    
    func superEncoder() -> Encoder {
        _BencodeEncoder(
            codingPath: codingPath + [Bencode.SuperCodingKey()],
            userInfo: userInfo,
            using: dependencies
        )
    }
    func superEncoder(forKey key: Key) -> Encoder {
        _BencodeEncoder(
            codingPath: codingPath + [key],
            userInfo: userInfo,
            using: dependencies
        )
    }
}

// MARK: - UnkeyedContainer

extension _BencodeEncoder {
    final class UnkeyedContainer {
        private var storage: [any _BencodeEncodingContainer] = []
        let dependencies: Dependencies
        var codingPath: [CodingKey]
        var userInfo: [CodingUserInfoKey: Any]
        var additionalData: Data?
        
        var count: Int { return storage.count }
        
        init(codingPath: [CodingKey], userInfo: [CodingUserInfoKey: Any], using dependencies: Dependencies) {
            self.dependencies = dependencies
            self.codingPath = codingPath
            self.userInfo = userInfo
        }
    }
}

extension _BencodeEncoder.UnkeyedContainer: _BencodeEncodingContainer {
    var data: Data {
        return (
            Data(Bencode.Element.listIndicator.rawValue.utf8.map { UInt8($0) }) +
            storage.map { $0.data }.reduce(Data(), +) +
            Data(Bencode.Element.endIndicator.rawValue.utf8.map { UInt8($0) })
        )
    }
}

extension _BencodeEncoder.UnkeyedContainer: UnkeyedEncodingContainer {
    func encodeNil() throws {}   // Just omit nil elements
    
    func encode<T>(_ value: T) throws where T: Encodable {
        var container = nestedSingleValueContainer()
        try container.encode(value)
    }
    
    private func nestedSingleValueContainer() -> SingleValueEncodingContainer {
        let container = _BencodeEncoder.SingleValueContainer(
            codingPath: codingPath + [Bencode.UnkeyedCodingKey(intValue: storage.count)],
            userInfo: userInfo,
            using: dependencies
        )
        storage.append(container)
        return container
    }
    
    func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let container = _BencodeEncoder.KeyedContainer<NestedKey>(
            codingPath: codingPath + [Bencode.UnkeyedCodingKey(intValue: storage.count)],
            userInfo: userInfo,
            using: dependencies
        )
        storage.append(container)
        return KeyedEncodingContainer(container)
    }
    
    func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let container = _BencodeEncoder.UnkeyedContainer(
            codingPath: codingPath + [Bencode.UnkeyedCodingKey(intValue: storage.count)],
            userInfo: userInfo,
            using: dependencies
        )
        storage.append(container)
        return container
    }
    
    func superEncoder() -> Encoder {
        _BencodeEncoder(
            codingPath: codingPath + [Bencode.UnkeyedCodingKey(intValue: storage.count)],
            userInfo: userInfo,
            using: dependencies
        )
    }
}

// MARK: - SingleValueContainer

extension _BencodeEncoder {
    final class SingleValueContainer {
        fileprivate var storage: Data = Data()
        let dependencies: Dependencies
        var codingPath: [CodingKey]
        var userInfo: [CodingUserInfoKey: Any]
        
        init(codingPath: [CodingKey], userInfo: [CodingUserInfoKey: Any], using dependencies: Dependencies) {
            self.dependencies = dependencies
            self.codingPath = codingPath
            self.userInfo = userInfo
        }
    }
}

extension _BencodeEncoder.SingleValueContainer: _BencodeEncodingContainer {
    var data: Data { storage }
}

extension _BencodeEncoder.SingleValueContainer: SingleValueEncodingContainer {
    func encodeNil() throws {
        throw EncodingError.invalidValue(0, EncodingError.Context(
            codingPath: codingPath,
            debugDescription: "Null values are not supported"
        ))
    }
    
    func encode(_ value: Int) throws {
        let intValue: String = "\(Bencode.Element.intIndicator.rawValue)\(value)\(Bencode.Element.endIndicator.rawValue)"
        storage = Data(intValue.utf8.map { UInt8($0) })
    }
    
    func encode(_ value: String) throws {
        storage = try _BencodeEncoder.SingleValueContainer.encodedString(value, codingPath: codingPath)
    }
    
    func encode<T>(_ value: T) throws where T: Encodable {
        // Encode non-primative encodable types as dictionaries
        switch value {
            case let intValue as Int: try encode(intValue)
            case let stringValue as String: try encode(stringValue)
            case let dataValue as Data: storage = encodedData(dataValue)
            case let rawDataValue as Array<UInt8>: storage = encodedRawArray(rawDataValue)
            case let arrayValue as any _ArrayProtocol: storage = try encodedArray(arrayValue)
            case let dictValue as any _DictionaryProtocol: storage = try encodedDict(dictValue)
            default:
                let encoder = _BencodeEncoder(codingPath: codingPath, userInfo: userInfo, using: dependencies)
                try value.encode(to: encoder)
                storage = encoder.data
        }
    }
    
    // MARK: - Explicit type encoding
    
    fileprivate static func encodedString(_ value: String, codingPath: [CodingKey]) throws -> Data {
        let encodedString: Data = try value.data(using: .ascii) ?? {
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: codingPath,
                debugDescription: "Could not convert string to ASCII data"
            ))
        }()
        let prefix: String = "\(encodedString.count)\(Bencode.Element.separator.rawValue)"
        
        return (Data(prefix.utf8.map { UInt8($0) }) + encodedString)
    }
    
    private func encodedData(_ value: Data) -> Data {
        // Data should be in the same format as a String
        let prefix: String = "\(value.count)\(Bencode.Element.separator.rawValue)"
        
        return (Data(prefix.utf8.map { UInt8($0) }) + value)
    }
    
    private func encodedRawArray(_ value: [UInt8]) -> Data {
        // Bytes arrays should be in the same format as a String
        let prefix: String = "\(value.count)\(Bencode.Element.separator.rawValue)"
        
        return (Data(prefix.utf8.map { UInt8($0) }) + value)
    }
    
    private func encodedArray<T>(_ value: T) throws -> Data where T: _ArrayProtocol, T.Element: Encodable {
        let result: [Data] = try value
            .compactMap { element in
                switch element {
                    case let dataValue as Data: return encodedData(dataValue)
                    case let rawDataValue as Array<UInt8>: return encodedRawArray(rawDataValue)
                    default:
                        let elementEncoder: _BencodeEncoder = _BencodeEncoder(
                            codingPath: codingPath,
                            userInfo: userInfo,
                            using: dependencies
                        )
                        try element.encode(to: elementEncoder)
                        return elementEncoder.data
                }
            }
        
        return (
            Data(Bencode.Element.listIndicator.rawValue.utf8.map { UInt8($0) }) +
            Data(result.joined()) +
            Data(Bencode.Element.endIndicator.rawValue.utf8.map { UInt8($0) })
        )
    }
    
    private func encodedDict<T>(_ value: T) throws -> Data where T: _DictionaryProtocol, T.Key == String, T.Value: Encodable {
        let encodedData: [Data] = try value
            .sorted(by: { $0.key < $1.key })    // Should be in lexicographical order
            .map { key, item in
                let itemEncoder = _BencodeEncoder(
                    codingPath: codingPath,
                    userInfo: userInfo,
                    using: dependencies
                )
                try item.encode(to: itemEncoder)
                
                return (
                    try _BencodeEncoder.SingleValueContainer.encodedString(key, codingPath: codingPath) +
                    itemEncoder.data
                )
            }
        
        return (
            Data(Bencode.Element.dictIndicator.rawValue.utf8.map { UInt8($0) }) +
            Data(encodedData.joined()) +
            Data(Bencode.Element.endIndicator.rawValue.utf8.map { UInt8($0) })
        )
    }
}

// MARK: - Convenience Protocols

private protocol _ArrayProtocol {
    associatedtype Element: Encodable
    
    func compactMap<ElementOfResult>(_ transform: (Element) throws -> ElementOfResult?) rethrows -> [ElementOfResult]
}

private protocol _DictionaryProtocol {
    typealias Key = String
    associatedtype Value: Encodable
    
    func map<T>(_ transform: ((key: Key, value: Value)) throws -> T) rethrows -> [T]
    func sorted(by areInIncreasingOrder: ((key: Key, value: Value), (key: Key, value: Value)) throws -> Bool) rethrows -> [(key: Key, value: Value)]
}

extension Array: _ArrayProtocol where Element: Encodable {}
extension Dictionary: _DictionaryProtocol where Key == String, Value: Encodable {}
