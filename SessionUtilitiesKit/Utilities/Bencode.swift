// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public struct BencodeResponse<T: Codable> {
    public let info: T
    public let data: Data?
}

extension BencodeResponse: Equatable where T: Equatable {}

public enum Bencode {
    private enum Element: Character {
        case number0 = "0"
        case number1 = "1"
        case number2 = "2"
        case number3 = "3"
        case number4 = "4"
        case number5 = "5"
        case number6 = "6"
        case number7 = "7"
        case number8 = "8"
        case number9 = "9"
        case intIndicator = "i"
        case listIndicator = "l"
        case dictIndicator = "d"
        case endIndicator = "e"
        case separator = ":"
        
        init?(_ byte: UInt8?) {
            guard
                let byte: UInt8 = byte,
                let byteString: String = String(data: Data([byte]), encoding: .utf8),
                let character: Character = byteString.first,
                let result: Element = Element(rawValue: character)
            else { return nil }
            
            self = result
        }
    }
    
    private struct BencodeString {
        let value: String?
        let rawValue: Data
    }
    
    // MARK: - Functions
    
    public static func decodeResponse<T>(
        from data: Data,
        using dependencies: Dependencies = Dependencies()
    ) throws -> BencodeResponse<T> where T: Decodable {
        guard
            let decodedData: (value: Any, remainingData: Data) = decodeData(data),
            decodedData.remainingData.isEmpty == true,  // Ensure there is no left over data
            let resultArray: [Any] = decodedData.value as? [Any],
            resultArray.count > 0
        else { throw NetworkError.parsingFailed }
        
        return BencodeResponse(
            info: try Bencode.decode(T.self, decodedValue: resultArray[0], using: dependencies),
            data: {
                guard resultArray.count > 1 else { return nil }
                
                switch resultArray.last {
                    case let bencodeString as BencodeString: return bencodeString.rawValue
                    default: return resultArray.last as? Data
                }
            }()
        )
    }
    
    public static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        using dependencies: Dependencies = Dependencies()
    ) throws -> T {
        guard
            let decodedData: (value: Any, remainingData: Data) = decodeData(data),
            decodedData.remainingData.isEmpty == true  // Ensure there is no left over data
        else { throw NetworkError.parsingFailed }
        
        return try Bencode.decode(T.self, decodedValue: decodedData.value, using: dependencies)
    }
    
    private static func decode<T: Decodable>(
        _ type: T.Type,
        decodedValue: Any,
        using dependencies: Dependencies = Dependencies()
    ) throws -> T {
        switch (decodedValue, T.self) {
            case (let directResult as T, _): return directResult
            case
                (let bencodeString as BencodeString, is String.Type),
                (let bencodeString as BencodeString, is Optional<String>.Type):
                return try (bencodeString.value as? T ?? { throw NetworkError.parsingFailed }())
                
            case (let bencodeString as BencodeString, _):
                return try bencodeString.rawValue.decoded(as: T.self, using: dependencies)
                
            default:
                guard
                    let jsonifiedInfo: Any = try? jsonify(decodedValue),
                    let infoData: Data = try? JSONSerialization.data(withJSONObject: jsonifiedInfo)
                else { throw NetworkError.parsingFailed }
                
                return try infoData.decoded(as: T.self, using: dependencies)
        }
    }
    
    // MARK: - Logic
    
    private static func decodeData(_ data: Data) -> (value: Any, remainingData: Data)? {
        switch Element(data.first) {
            case .number0, .number1, .number2, .number3, .number4,
                .number5, .number6, .number7, .number8, .number9:
                return decodeString(data)
                
            case .intIndicator: return decodeInt(data)
            case .listIndicator: return decodeList(data)
            case .dictIndicator: return decodeDict(data)
            default: return nil
        }
    }
    
    /// Decode a string element from iterator assumed to have structure `{length}:{data}`
    private static func decodeString(_ data: Data) -> (value: BencodeString, remainingData: Data)? {
        var mutableData: Data = data
        var lengthData: [UInt8] = []
        
        // Remove bytes until we hit the separator
        while let next: UInt8 = mutableData.popFirst(), Element(next) != .separator {
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
    
    /// Decode an int element from iterator assumed to have structure `i{int}e`
    private static func decodeInt(_ data: Data) -> (value: Int, remainingData: Data)? {
        var mutableData: Data = data
        var intData: [UInt8] = []
        _ = mutableData.popFirst() // drop `i`
        
        // Pop until after `e`
        while let next: UInt8 = mutableData.popFirst(), Element(next) != .endIndicator {
            intData.append(next)
        }
        
        guard
            let intString: String = String(data: Data(intData), encoding: .ascii),
            let result: Int = Int(intString, radix: 10)
        else { return nil }
        
        // Need to reset the index of the data (it maintains the index after popping/slicing)
        // See https://forums.swift.org/t/data-subscript/57195 for more info
        return (result, Data(mutableData))
    }
    
    /// Decode a list element from iterator assumed to have structure `l{data}e`
    private static func decodeList(_ data: Data) -> ([Any], Data)? {
        var mutableData: Data = data
        var listElements: [Any] = []
        _ = mutableData.popFirst() // drop `l`
        
        while !mutableData.isEmpty, let next: UInt8 = mutableData.first, Element(next) != .endIndicator {
            guard let result = decodeData(mutableData) else { break }
                
            listElements.append(result.value)
            mutableData = result.remainingData
        }
        
        _ = mutableData.popFirst() // drop `e`
        
        // Need to reset the index of the data (it maintains the index after popping/slicing)
        // See https://forums.swift.org/t/data-subscript/57195 for more info
        return (listElements, Data(mutableData))
    }
    
    /// Decode a dict element from iterator assumed to have structure `d{data}e`
    private static func decodeDict(_ data: Data) -> ([String: Any], Data)? {
        var mutableData: Data = data
        var dictElements: [String: Any] = [:]
        _ = mutableData.popFirst() // drop `d`
        
        while !mutableData.isEmpty, let next: UInt8 = mutableData.first, Element(next) != .endIndicator {
            guard
                let keyResult = decodeString(mutableData),
                let key: String = keyResult.value.value,
                let valueResult = decodeData(keyResult.remainingData)
            else { return nil }
            
            dictElements[key] = valueResult.value
            mutableData = valueResult.remainingData
        }
        
        _ = mutableData.popFirst() // drop `e`
        
        // Need to reset the index of the data (it maintains the index after popping/slicing)
        // See https://forums.swift.org/t/data-subscript/57195 for more info
        return (dictElements, Data(mutableData))
    }
    
    // MARK: - Internal Functions
    
    private static func jsonify(_ value: Any) throws -> Any {
        switch value {
            case let arrayValue as [Any]: return try arrayValue.map { try jsonify($0) } as Any
            case let dictValue as [String: Any]: return try dictValue.mapValues { try jsonify($0) } as Any
            case let bencodeString as BencodeString: return bencodeString.value as Any
            default: return value
        }
    }
}
