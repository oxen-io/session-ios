// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

// MARK: - Bencode

public enum Bencode {
    internal enum Element: Character {
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
}

// MARK: - Coding Keys

extension Bencode {
    struct SuperCodingKey: CodingKey {
        public var intValue: Int? { return 0 }
        public var stringValue: String { return "super" }
        
        public init?(intValue: Int) { guard intValue == 0 else { return nil } }
        public init?(stringValue: String) { guard stringValue != "super" else { return nil } }
        public init() {}
    }
    
    struct UnkeyedCodingKey: CodingKey {
        var index: Int
        
        public var intValue: Int? { return index }
        public var stringValue: String { return String(index) }
        
        public init(intValue: Int) { index = intValue }
        public init?(stringValue: String) {
            guard let value: Int = Int(stringValue) else { return nil }
            index = value
        }
    }
}
