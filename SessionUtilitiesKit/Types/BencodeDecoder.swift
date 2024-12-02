// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

// MARK: - BencodeDecoder

public struct BencodeDecoder {
    private let dependencies: Dependencies
    public var userInfo: [CodingUserInfoKey: Any]
    
    public init(userInfo: [CodingUserInfoKey: Any] = [:], using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.userInfo = userInfo
        self.userInfo[Dependencies.userInfoKey] = dependencies
    }
    
    public func decode<T>(_ type: T.Type, from data: Data) throws -> T where T: Decodable {
        let decoder: _BencodeDecoder = _BencodeDecoder(data: data, userInfo: userInfo, using: dependencies)
        return try T(from: decoder)
    }
}

// MARK: - AdditionalData Support

public extension UnkeyedDecodingContainer {
    mutating func decodeAdditionalData<T>(_ type: T.Type) throws -> T where T: Decodable, T: DataProtocol {
        let error: DecodingError = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: codingPath, debugDescription: "unable to decode additional data")
        )
        
        switch (self) {
            case let bencodeUnkeyedContainer as _BencodeDecoder.UnkeyedContainer:
                guard let remainingData: Data = bencodeUnkeyedContainer.remainingData else { throw error }
                
                switch type {
                    case is Data.Type: return try remainingData as? T ?? { throw error }()
                    case is [UInt8].Type: return try Array(remainingData) as? T ?? { throw error }()
                    default: throw error
                }
                
            default:
                switch type {
                    case is Data.Type: return try self.decode(type)
                    case is [UInt8].Type: return try Array(self.decode(Data.self)) as? T ?? { throw error }()
                    default: throw error
                }
        }
    }
}

// MARK: - _BencodeDecodingContainer

protocol _BencodeDecodingContainer: AnyObject {
    var dependencies: Dependencies { get }
    var codingPath: [CodingKey] { get set }
    
    var data: Data { get }
    var remainingData: Data? { get }
}

// MARK: - _BencodeDecoder

final class _BencodeDecoder {
    let dependencies: Dependencies
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]
    
    fileprivate var container: _BencodeDecodingContainer?
    fileprivate let data: Data
    
    public var remainingData: Data? { container?.remainingData }
    
    init(data: Data, codingPath: [CodingKey] = [], userInfo: [CodingUserInfoKey: Any], using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.data = data
        self.codingPath = codingPath
        self.userInfo = userInfo
    }
}

extension _BencodeDecoder: Decoder {
    func container<Key>(keyedBy type: Key.Type) -> KeyedDecodingContainer<Key> where Key: CodingKey {
        let container = KeyedContainer<Key>(data: data, codingPath: codingPath, userInfo: userInfo, using: dependencies)
        self.container = container

        return KeyedDecodingContainer(container)
    }

    func unkeyedContainer() -> UnkeyedDecodingContainer {
        let container = UnkeyedContainer(data: data, codingPath: codingPath, userInfo: userInfo, using: dependencies)
        self.container = container

        return container
    }

    func singleValueContainer() -> SingleValueDecodingContainer {
        let container = SingleValueContainer(data: data, codingPath: codingPath, userInfo: userInfo, using: dependencies)
        self.container = container

        return container
    }
}

// MARK: - Decoding Logic

extension _BencodeDecoder {
    private struct BencodeString {
        let value: String?
        let rawValue: Data
    }
    
    /// Extract the data for the next element (including the `Bencode.Element` info)
    private static func elementData(_ codingPath: [CodingKey], _ data: Data) throws -> Data {
        guard
            let separatorData: Data = "\(Bencode.Element.separator.rawValue)".data(using: .utf8),
            let endIndicatorData: Data = "\(Bencode.Element.endIndicator.rawValue)".data(using: .utf8)
        else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "could not convert bencode element prefixes to data"
            ))
        }
        
        var mutableData: Data = data
        
        switch Bencode.Element(data.first) {
            case .number0, .number1, .number2, .number3, .number4,
                .number5, .number6, .number7, .number8, .number9:
                var lengthData: [UInt8] = []
                
                // Remove bytes until we hit the separator (separator will be dropped)
                while let next: UInt8 = mutableData.popFirst(), Bencode.Element(next) != .separator {
                    lengthData.append(next)
                }
                
                guard
                    let lengthString: String = String(data: Data(lengthData), encoding: .ascii),
                    let length: Int = Int(lengthString, radix: 10),
                    mutableData.count >= length
                else {
                    throw DecodingError.dataCorrupted(DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "unable to extract length value"
                    ))
                }
                
                // Need to reset the index of the data (it maintains the index after popping/slicing)
                // See https://forums.swift.org/t/data-subscript/57195 for more info
                mutableData = Data(mutableData)
                mutableData = (lengthData + separatorData + mutableData[0..<length])    // overwrite with content
                
            case .intIndicator:
                var intData: [UInt8] = (mutableData.popFirst().map { [$0] } ?? [])      // drop `i`
                
                // Remove bytes until we hit the end (endIndicator will be dropped)
                while let next: UInt8 = mutableData.popFirst(), Bencode.Element(next) != .endIndicator {
                    intData.append(next)
                }
                
                intData.append(contentsOf: endIndicatorData)                            // append `e`
                mutableData = Data(intData)                                             // overwrite with content
                
            case .listIndicator:
                var listData: [UInt8] = (mutableData.popFirst().map { [$0] } ?? [])     // drop `l`
                
                // Extract the elements
                while let next: UInt8 = mutableData.first, Bencode.Element(next) != .endIndicator {
                    let elementData: Data = try elementData(codingPath, mutableData)
                    listData.append(contentsOf: elementData)                            // append the element
                    mutableData = mutableData.dropFirst(elementData.count)              // drop the element
                }
                
                listData.append(contentsOf: mutableData.popFirst().map { [$0] } ?? [])  // drop `e`
                mutableData = Data(listData)                                            // overwrite with content
                
            case .dictIndicator:
                var dictData: [UInt8] = (mutableData.popFirst().map { [$0] } ?? [])     // drop `d`
                
                // Extract the elements
                while let next: UInt8 = mutableData.first, Bencode.Element(next) != .endIndicator {
                    let keyData: Data = try elementData(codingPath, mutableData)
                    dictData.append(contentsOf: keyData)                                // append the key
                    mutableData = mutableData.dropFirst(keyData.count)                  // drop the key
                    
                    let valueData: Data = try elementData(codingPath, mutableData)
                    dictData.append(contentsOf: valueData)                              // append the value
                    mutableData = mutableData.dropFirst(valueData.count)                // drop the value
                }
                
                dictData.append(contentsOf: mutableData.popFirst().map { [$0] } ?? [])  // drop `e`
                mutableData = Data(dictData)                                            // overwrite with content
                
            default:
                let actualValue: String = (data.first.map { String(data: Data([$0]), encoding: .ascii) } ?? "null")
                
                throw DecodingError.typeMismatch(
                    Bencode.Element.self,
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "invalid element prefix: \(actualValue)"
                    )
                )
        }
        
        return Data(mutableData)
    }
    
    /// Decode a string element from iterator assumed to have structure `{length}:{data}`
    private static func decodeString(_ data: Data) -> (value: BencodeString, remainingData: Data)? {
        var mutableData: Data = data
        var lengthData: [UInt8] = []
        
        // Remove bytes until we hit the separator
        while let next: UInt8 = mutableData.popFirst(), Bencode.Element(next) != .separator {
            lengthData.append(next)
        }
        
        // Need to reset the index of the data (it maintains the index after popping/slicing)
        // See https://forums.swift.org/t/data-subscript/57195 for more info
        mutableData = Data(mutableData)
        
        guard
            let lengthString: String = String(data: Data(lengthData), encoding: .ascii),
            let length: Int = Int(lengthString, radix: 10),
            mutableData.count >= length
        else { return nil }
        
        // Need to reset the index of the data (it maintains the index after popping/slicing)
        // See https://forums.swift.org/t/data-subscript/57195 for more info
        return (
            BencodeString(
                value: String(data: mutableData[0..<length], encoding: .ascii),
                rawValue: mutableData[0..<length]
            ),
            Data(mutableData.dropFirst(length))
        )
    }
}

// MARK: - KeyedContainer

extension _BencodeDecoder {
    final class KeyedContainer<Key> where Key: CodingKey {
        let dependencies: Dependencies
        var codingPath: [CodingKey]
        var userInfo: [CodingUserInfoKey: Any]
        var data: Data
        var remainingData: Data?
        
        lazy var nestedContainers: [String: _BencodeDecodingContainer] = {
            guard Bencode.Element(self.data.first) == .dictIndicator else { return [:] }
            
            var mutableData: Data = self.data
            var nestedContainers: [String: _BencodeDecodingContainer] = [:]
            _ = mutableData.popFirst()                                                  // drop `d`
            
            while !mutableData.isEmpty, let next: UInt8 = mutableData.first, Bencode.Element(next) != .endIndicator {
                guard
                    let keyResult = _BencodeDecoder.decodeString(mutableData),
                    let key: String = keyResult.value.value
                else { return [:] }
                
                mutableData = keyResult.remainingData                                   // drop key data
                let container: _BencodeDecoder.SingleValueContainer = _BencodeDecoder.SingleValueContainer(
                    data: mutableData,
                    codingPath: self.codingPath,
                    userInfo: self.userInfo,
                    using: dependencies
                )
                nestedContainers[key] = container
                mutableData = (container.remainingData ?? Data())
            }

            return nestedContainers
        }()
        
        init(data: Data, codingPath: [CodingKey], userInfo: [CodingUserInfoKey: Any], using dependencies: Dependencies) {
            self.dependencies = dependencies
            self.codingPath = codingPath
            self.userInfo = userInfo
            
            let elementData: Data = ((try? _BencodeDecoder.elementData(codingPath, data)) ?? Data())
            self.data = elementData
            self.remainingData = data.dropFirst(elementData.count)
        }
        
        func nestedCodingPath(forKey key: CodingKey) -> [CodingKey] {
            return codingPath + [key]
        }
        
        func checkCanDecodeValue(forKey key: Key) throws {
            guard contains(key) else {
                throw DecodingError.keyNotFound(
                    key,
                    DecodingError.Context(codingPath: codingPath, debugDescription: "key not found: \(key.stringValue)")
                )
            }
        }
    }
}

extension _BencodeDecoder.KeyedContainer: _BencodeDecodingContainer {}

extension _BencodeDecoder.KeyedContainer: KeyedDecodingContainerProtocol {
    var allKeys: [Key] { nestedContainers.keys.compactMap { Key(stringValue: $0) } }
    
    func contains(_ key: Key) -> Bool { nestedContainers.keys.contains(key.stringValue) }

    func decodeNil(forKey key: Key) throws -> Bool {
        throw DecodingError.typeMismatch(
            Any?.self,
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "cannot decode nil for key: \(key) (Null values are not supported)"
            )
        )
    }

    func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T: Decodable {
        try checkCanDecodeValue(forKey: key)
        
        guard let container: _BencodeDecodingContainer = nestedContainers[key.stringValue] else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(codingPath: codingPath, debugDescription: "key not found: \(key.stringValue)")
            )
        }

        let decoder: BencodeDecoder = BencodeDecoder(userInfo: userInfo, using: container.dependencies)
        
        return try decoder.decode(T.self, from: container.data)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        try checkCanDecodeValue(forKey: key)

        guard let unkeyedContainer = nestedContainers[key.stringValue] as? _BencodeDecoder.UnkeyedContainer else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "cannot decode nested container for key: \(key)"
            )
        }

        return unkeyedContainer
    }

    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        try checkCanDecodeValue(forKey: key)

        guard let keyedContainer = nestedContainers[key.stringValue] as? _BencodeDecoder.KeyedContainer<NestedKey> else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "cannot decode nested container for key: \(key)"
            )
        }

        return KeyedDecodingContainer(keyedContainer)
    }

    func superDecoder() throws -> Decoder {
        return _BencodeDecoder(data: data, userInfo: userInfo, using: dependencies)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        let decoder = _BencodeDecoder(data: data, userInfo: userInfo, using: dependencies)
        decoder.codingPath = [key]

        return decoder
    }
}

// MARK: - UnkeyedContainer

extension _BencodeDecoder {
    final class UnkeyedContainer {
        let dependencies: Dependencies
        var codingPath: [CodingKey]
        var userInfo: [CodingUserInfoKey: Any]
        var nestedCodingPath: [CodingKey] { codingPath + [Bencode.UnkeyedCodingKey(intValue: count ?? 0)] }
        
        var data: Data
        var remainingData: Data?
        
        lazy var nestedContainers: [_BencodeDecodingContainer] = {
            /// If the first element isn't a `listIndicator` then the content is likely a single element which is represented under the hood
            /// by an array (eg. `String` or `Data`), or is a single Bencoded element followed by additional bytes
            guard Bencode.Element(data.first) == .listIndicator else {
                return [
                    _BencodeDecoder.SingleValueContainer(
                        data: data,
                        codingPath: codingPath,
                        userInfo: userInfo,
                        using: dependencies
                    )
                ]
            }
            
            var mutableData: Data = data
            var nestedContainers: [_BencodeDecodingContainer] = []
            _ = mutableData.popFirst()                                                  // drop `l`
            
            while !mutableData.isEmpty, let next: UInt8 = mutableData.first, Bencode.Element(next) != .endIndicator {
                let container: _BencodeDecoder.SingleValueContainer = _BencodeDecoder.SingleValueContainer(
                    data: mutableData,
                    codingPath: codingPath,
                    userInfo: userInfo,
                    using: dependencies
                )
                nestedContainers.append(container)
                mutableData = (container.remainingData ?? Data())
            }
            
            return nestedContainers
        }()
        
        lazy var count: Int? = { nestedContainers.count }()
        var isAtEnd: Bool { currentIndex >= (count ?? 0) }
        var currentIndex: Int = 0
        
        init(data: Data, codingPath: [CodingKey], userInfo: [CodingUserInfoKey: Any], using dependencies: Dependencies) {
            self.dependencies = dependencies
            self.codingPath = codingPath
            self.userInfo = userInfo
            
            let elementData: Data = ((try? _BencodeDecoder.elementData(codingPath, data)) ?? Data())
            self.data = elementData
            self.remainingData = data.dropFirst(elementData.count)
        }
        
        func checkCanDecodeValue() throws {
            guard !isAtEnd else {
                throw DecodingError.dataCorruptedError(in: self, debugDescription: "Unexpected end of data")
            }
        }
    }
}

extension _BencodeDecoder.UnkeyedContainer: _BencodeDecodingContainer {}

extension _BencodeDecoder.UnkeyedContainer: UnkeyedDecodingContainer {
    func decodeNil() throws -> Bool {
        throw DecodingError.typeMismatch(
            Any?.self,
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "cannot decode nil for index: \(currentIndex) (Null values are not supported)"
            )
        )
    }
    
    func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        try checkCanDecodeValue()
        defer { self.currentIndex += 1 }
        
        let container: _BencodeDecodingContainer = self.nestedContainers[self.currentIndex]
        let error: DecodingError = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: codingPath, debugDescription: "unable to decode \(type)")
        )
        
        switch type {
            case is Data.Type:  // Custom handle data as iOS sees it as an array
                let result = try _BencodeDecoder.decodeString(container.data) ?? { throw error }()
                
                return try result.value.rawValue as? T ?? { throw error }()
                
            default:
                let decoder: BencodeDecoder = BencodeDecoder(userInfo: userInfo, using: dependencies)
                
                return try decoder.decode(T.self, from: container.data)
        }
    }
    
    func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        try checkCanDecodeValue()
        defer { self.currentIndex += 1 }
        
        guard let container: _BencodeDecoder.UnkeyedContainer = nestedContainers[currentIndex] as? _BencodeDecoder.UnkeyedContainer else {
            throw DecodingError.typeMismatch(
                _BencodeDecoder.UnkeyedContainer.self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "nested container is not an UnkeyedContainer"
                )
            )
        }
        
        return container
    }
    
    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        try checkCanDecodeValue()
        defer { self.currentIndex += 1 }
        
        guard let container: _BencodeDecoder.KeyedContainer<NestedKey> = nestedContainers[currentIndex] as? _BencodeDecoder.KeyedContainer<NestedKey> else {
            throw DecodingError.typeMismatch(
                _BencodeDecoder.UnkeyedContainer.self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "nested container is not an KeyedContainer"
                )
            )
        }
        
        return KeyedDecodingContainer(container)
    }

    func superDecoder() throws -> Decoder {
        return _BencodeDecoder(data: data, userInfo: userInfo, using: dependencies)
    }
}

// MARK: - SingleValueContainer

extension _BencodeDecoder {
    final class SingleValueContainer {
        let dependencies: Dependencies
        var codingPath: [CodingKey]
        var userInfo: [CodingUserInfoKey: Any]
        var data: Data
        var remainingData: Data?

        init(data: Data, codingPath: [CodingKey], userInfo: [CodingUserInfoKey: Any], using dependencies: Dependencies) {
            self.dependencies = dependencies
            self.codingPath = codingPath
            self.userInfo = userInfo
            
            let elementData: Data? = (try? _BencodeDecoder.elementData(codingPath, data))
            self.data = (elementData ?? data)
            self.remainingData = elementData.map { data.dropFirst($0.count) }
        }
    }
}

extension _BencodeDecoder.SingleValueContainer: _BencodeDecodingContainer {}

extension _BencodeDecoder.SingleValueContainer: SingleValueDecodingContainer {
    func decodeNil() -> Bool { return true }   // Nil values are omitted in Bencoded data
    
    func decode(_ type: Bool.Type) throws -> Bool {
        throw DecodingError.typeMismatch(
            Bool.self,
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Bencode doesn't support Bool values, use an Int and custom Encode/Decode functions isntead"
            )
        )
    }
    
    func decode(_ type: String.Type) throws -> String {
        guard
            let decodedData = _BencodeDecoder.decodeString(data),
            let result: String = decodedData.value.value
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "failed to decode String"
                )
            )
        }
        
        return result
    }
    
    func decode(_ type: Double.Type) throws -> Double {
        let intValue: Int = try decodeFixedInt(Int.self)
        
        return Double(intValue)
    }

    func decode(_ type: Float.Type) throws -> Float {
        let intValue: Int = try decodeFixedInt(Int.self)
        
        return Float(intValue)
    }
    
    func decode(_ type: Int.Type) throws -> Int { return try decodeFixedInt(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { return try decodeFixedInt(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { return try decodeFixedInt(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { return try decodeFixedInt(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { return try decodeFixedInt(type) }
    func decode(_ type: UInt.Type) throws -> UInt { return try decodeFixedInt(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { return try decodeFixedInt(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { return try decodeFixedInt(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { return try decodeFixedInt(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { return try decodeFixedInt(type) }
    
    func decodeFixedInt<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        var mutableData: Data = data
        var intData: [UInt8] = []
        _ = mutableData.popFirst()                                                      // drop `i`
        
        // Pop until after `e`
        while let next: UInt8 = mutableData.popFirst(), Bencode.Element(next) != .endIndicator {
            intData.append(next)
        }
        
        guard
            let intString: String = String(data: Data(intData), encoding: .ascii),
            let result: T = T(intString, radix: 10)
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "failed to decode Int"
                )
            )
        }
        
        return result
    }
    
    func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        if T.self is any FixedWidthInteger.Type {
            // This will be handled by the integer-specific decode function
            throw DecodingError.typeMismatch(
                T.self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "attempted to use generic decode function instead of integer-specific one for integer type"
                )
            )
        }
        
        let decoder = _BencodeDecoder(data: data, userInfo: userInfo, using: dependencies)
        let value = try T(from: decoder)
        
        return value
    }
}
