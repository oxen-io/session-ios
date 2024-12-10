// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionUtilitiesKit

class BencodeDecoderSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        
        // MARK: - BencodeDecoder
        describe("BencodeDecoder") {
            // MARK: ---- should decode a basic string
            it("should decode a basic string") {
                let basicStringData: Data = "5:howdy".data(using: .utf8)!
                let result = try? BencodeDecoder(using: dependencies).decode(String.self, from: basicStringData)
                
                expect(result).to(equal("howdy"))
            }
            
            // MARK: ---- should decode a basic integer
            it("should decode a basic integer") {
                let basicIntegerData: Data = "i3e".data(using: .utf8)!
                let result = try? BencodeDecoder(using: dependencies).decode(Int.self, from: basicIntegerData)
                
                expect(result).to(equal(3))
            }
            
            // MARK: ---- should decode a list of integers
            it("should decode a list of integers") {
                let basicIntListData: Data = "li1ei2ee".data(using: .utf8)!
                let result = try? BencodeDecoder(using: dependencies).decode([Int].self, from: basicIntListData)
                
                expect(result).to(equal([1, 2]))
            }
            
            // MARK: ---- should decode a basic dict
            it("should decode a basic dict") {
                let basicDictData: Data = "d4:spaml1:a1:bee".data(using: .utf8)!
                let result = try? BencodeDecoder(using: dependencies).decode([String: [String]].self, from: basicDictData)
                
                expect(result).to(equal(["spam": ["a", "b"]]))
            }
            
            // MARK: ---- decodes a decodable type
            it("decodes a decodable type") {
                let data: Data = "d8:intValuei100e11:stringValue4:Test".data(using: .utf8)!
                let result: TestType? = try? BencodeDecoder(using: dependencies).decode(TestType.self, from: data)
                
                expect(result).to(equal(TestType(intValue: 100, stringValue: "Test")))
            }
            
            // MARK: ------ throws an error when decoding the wrong type
            it("throws an error when decoding the wrong type") {
                let data: Data = "l4:Teste".data(using: .utf8)!

                expect {
                    try BencodeDecoder(using: dependencies).decode(Int.self, from: data)
                }.to(throwError(DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "failed to decode String"))))
            }
            
            // MARK: ------ throws an error when given an invalid length
            it("throws an error when given an invalid length") {
                let data: Data = "d12:intValuei100e11:stringValue4:Teste"
                    .data(using: .utf8)!
                
                expect {
                    try BencodeDecoder(using: dependencies).decode(TestType.self, from: data)
                }.to(throwError(DecodingError.keyNotFound(TestType.CodingKeys.intValue, DecodingError.Context(codingPath: [], debugDescription: "key not found: intValue"))))
            }
            
            // MARK: ------ throws an error when given an invalid key
            it("throws an error when given an invalid key") {
                let data: Data = "d7:INVALIDi100e11:stringValue4:Test"
                    .data(using: .utf8)!
                
                expect {
                    try BencodeDecoder(using: dependencies).decode(TestType.self, from: data)
                }.to(throwError(DecodingError.keyNotFound(TestType.CodingKeys.intValue, DecodingError.Context(codingPath: [], debugDescription: "key not found: intValue"))))
            }
            
            // MARK: ------ decodes correctly when trying to decode an int to a bool with custom handling
            it("decodes correctly when trying to decode an int to a bool with custom handling") {
                let data: Data = "d9:boolValuei1e11:stringValue4:teste"
                    .data(using: .utf8)!
                
                expect {
                    try BencodeDecoder(using: dependencies).decode(TestType3.self, from: data)
                }.toNot(throwError())
            }
            
            // MARK: ------ throws an error when trying to decode an int to a bool
            it("throws an error when trying to decode an int to a bool") {
                let data: Data = "d9:boolValuei1e11:stringValue4:teste"
                    .data(using: .utf8)!
                
                expect {
                    try BencodeDecoder(using: dependencies).decode(TestType2.self, from: data)
                }.to(throwError(DecodingError.typeMismatch(Bool.self, DecodingError.Context(codingPath: [], debugDescription: "Bencode doesn't support Bool values, use an Int and custom Encode/Decode functions isntead"))))
            }
            
            // MARK: ---- does not end up in an infinite loop when decoding Int64 types
            it("does not end up in an infinite loop when decoding Int64 types") {
                let basicIntListData: Data = "li1ei2ee".data(using: .utf8)!
                let result = try? BencodeDecoder(using: dependencies).decode([Int64].self, from: basicIntListData)
                
                expect(result).to(equal([1, 2]))
            }
            
            // MARK: ---- does not end up in an infinite loop when decoding Double types
            it("does not end up in an infinite loop when decoding Double types") {
                let basicIntListData: Data = "li1ei2ee".data(using: .utf8)!
                let result = try? BencodeDecoder(using: dependencies).decode([Double].self, from: basicIntListData)
                
                expect(result).to(equal([1, 2]))
            }
            
            // MARK: ---- does not end up in an infinite loop when decoding Float types
            it("does not end up in an infinite loop when decoding Float types") {
                let basicIntListData: Data = "li1ei2ee".data(using: .utf8)!
                let result = try? BencodeDecoder(using: dependencies).decode([Float].self, from: basicIntListData)
                
                expect(result).to(equal([1, 2]))
            }
        }
    }
}

// MARK: - Test Types

fileprivate struct TestType: Codable, Equatable {
    public enum CodingKeys: String, CodingKey {
        case intValue
        case stringValue
    }
    
    let intValue: Int
    let stringValue: String
}

fileprivate struct TestType2: Codable, Equatable {
    let stringValue: String
    let boolValue: Bool
}

fileprivate struct TestType3: Codable, Equatable {
    let stringValue: String
    let boolValue: Bool
    
    init(_ stringValue: String, _ boolValue: Bool) {
        self.stringValue = stringValue
        self.boolValue = boolValue
    }
    
    init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        self = TestType3(
            try container.decode(String.self, forKey: .stringValue),
            ((try? container.decode(Bool.self, forKey: .boolValue)) ?? false)
        )
    }
}
