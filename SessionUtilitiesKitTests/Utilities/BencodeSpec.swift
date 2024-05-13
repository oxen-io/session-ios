// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionUtilitiesKit

class BencodeSpec: QuickSpec {
    override class func spec() {
        // MARK: - Bencode
        describe("Bencode") {
            // MARK: -- when decoding
            context("when decoding") {
                // MARK: ---- should decode a basic string
                it("should decode a basic string") {
                    let basicStringData: Data = "5:howdy".data(using: .utf8)!
                    let result = try? Bencode.decode(String.self, from: basicStringData)
                    
                    expect(result).to(equal("howdy"))
                }
                
                // MARK: ---- should decode a basic integer
                it("should decode a basic integer") {
                    let basicIntegerData: Data = "i3e".data(using: .utf8)!
                    let result = try? Bencode.decode(Int.self, from: basicIntegerData)
                    
                    expect(result).to(equal(3))
                }
                
                // MARK: ---- should decode a list of integers
                it("should decode a list of integers") {
                    let basicIntListData: Data = "li1ei2ee".data(using: .utf8)!
                    let result = try? Bencode.decode([Int].self, from: basicIntListData)
                    
                    expect(result).to(equal([1, 2]))
                }
                
                // MARK: ---- should decode a basic dict
                it("should decode a basic dict") {
                    let basicDictData: Data = "d4:spaml1:a1:bee".data(using: .utf8)!
                    let result = try? Bencode.decode([String: [String]].self, from: basicDictData)
                    
                    expect(result).to(equal(["spam": ["a", "b"]]))
                }
                
                // MARK: ---- decodes a decodable type
                it("decodes a decodable type") {
                    let data: Data = "d8:intValuei100e11:stringValue4:Test".data(using: .utf8)!
                    let result: TestType? = try? Bencode.decode(TestType.self, from: data)
                    
                    expect(result).to(equal(TestType(intValue: 100, stringValue: "Test")))
                }
                
                // MARK: ---- decodes a stringified decodable type
                it("decodes a stringified decodable type") {
                    let data: Data = "37:{\"intValue\":100,\"stringValue\":\"Test\"}".data(using: .utf8)!
                    let result: TestType? = try? Bencode.decode(TestType.self, from: data)
                    
                    expect(result).to(equal(TestType(intValue: 100, stringValue: "Test")))
                }
            }
            
            // MARK: -- when decoding a response
            context("when decoding a response") {
                // MARK: ---- with a decodable type
                context("with a decodable type") {
                    // MARK: ------ decodes successfully
                    it("decodes successfully") {
                        let data: Data = "ld8:intValuei100e11:stringValue4:Teste5:\u{01}\u{02}\u{03}\u{04}\u{05}e"
                            .data(using: .utf8)!
                        let result: BencodeResponse<TestType>? = try? Bencode.decodeResponse(from: data)
                        
                        expect(result)
                            .to(equal(
                                BencodeResponse(
                                    info: TestType(
                                        intValue: 100,
                                        stringValue: "Test"
                                    ),
                                    data: Data([1, 2, 3, 4, 5])
                                )
                            ))
                    }
                    
                    // MARK: ------ decodes successfully with no body
                    it("decodes successfully with no body") {
                        let data: Data = "ld8:intValuei100e11:stringValue4:Teste"
                            .data(using: .utf8)!
                        let result: BencodeResponse<TestType>? = try? Bencode.decodeResponse(from: data)
                        
                        expect(result)
                            .to(equal(
                                BencodeResponse(
                                    info: TestType(
                                        intValue: 100,
                                        stringValue: "Test"
                                    ),
                                    data: nil
                                )
                            ))
                    }
                    
                    // MARK: ------ throws a parsing error when given an invalid length
                    it("throws a parsing error when given an invalid length") {
                        let data: Data = "ld12:intValuei100e11:stringValue4:Teste5:\u{01}\u{02}\u{03}\u{04}\u{05}e"
                            .data(using: .utf8)!
                        
                        expect {
                            let result: BencodeResponse<TestType> = try Bencode.decodeResponse(from: data)
                            _ = result
                        }.to(throwError(NetworkError.parsingFailed))
                    }
                    
                    // MARK: ------ throws a parsing error when given an invalid key
                    it("throws a parsing error when given an invalid key") {
                        let data: Data = "ld7:INVALIDi100e11:stringValue4:Teste5:\u{01}\u{02}\u{03}\u{04}\u{05}e"
                            .data(using: .utf8)!
                        
                        expect {
                            let result: BencodeResponse<TestType> = try Bencode.decodeResponse(from: data)
                            _ = result
                        }.to(throwError(NetworkError.parsingFailed))
                    }
                    
                    // MARK: ------ decodes correctly when trying to decode an int to a bool with custom handling
                    it("decodes correctly when trying to decode an int to a bool with custom handling") {
                        let data: Data = "ld9:boolValuei1e11:stringValue4:testee"
                            .data(using: .utf8)!
                        
                        expect {
                            let result: BencodeResponse<TestType3> = try Bencode.decodeResponse(from: data)
                            _ = result
                        }.toNot(throwError(NetworkError.parsingFailed))
                    }
                    
                    // MARK: ------ throws a parsing error when trying to decode an int to a bool
                    it("throws a parsing error when trying to decode an int to a bool") {
                        let data: Data = "ld9:boolValuei1e11:stringValue4:testee"
                            .data(using: .utf8)!
                        
                        expect {
                            let result: BencodeResponse<TestType2> = try Bencode.decodeResponse(from: data)
                            _ = result
                        }.to(throwError(NetworkError.parsingFailed))
                    }
                }
                
                // MARK: ---- with stringified json info
                context("with stringified json info") {
                    // MARK: ------ decodes successfully
                    it("decodes successfully") {
                        let data: Data = "l37:{\"intValue\":100,\"stringValue\":\"Test\"}5:\u{01}\u{02}\u{03}\u{04}\u{05}e"
                            .data(using: .utf8)!
                        let result: BencodeResponse<TestType>? = try? Bencode.decodeResponse(from: data)
                        
                        expect(result)
                            .to(equal(
                                BencodeResponse(
                                    info: TestType(
                                        intValue: 100,
                                        stringValue: "Test"
                                    ),
                                    data: Data([1, 2, 3, 4, 5])
                                )
                            ))
                    }
                    
                    // MARK: ------ decodes successfully with no body
                    it("decodes successfully with no body") {
                        let data: Data = "l37:{\"intValue\":100,\"stringValue\":\"Test\"}e"
                            .data(using: .utf8)!
                        let result: BencodeResponse<TestType>? = try? Bencode.decodeResponse(from: data)
                        
                        expect(result)
                            .to(equal(
                                BencodeResponse(
                                    info: TestType(
                                        intValue: 100,
                                        stringValue: "Test"
                                    ),
                                    data: nil
                                )
                            ))
                    }
                    
                    // MARK: ------ throws a parsing error when invalid
                    it("throws a parsing error when invalid") {
                        let data: Data = "l36:{\"INVALID\":100,\"stringValue\":\"Test\"}5:\u{01}\u{02}\u{03}\u{04}\u{05}e"
                            .data(using: .utf8)!
                        
                        expect {
                            let result: BencodeResponse<TestType> = try Bencode.decodeResponse(from: data)
                            _ = result
                        }.to(throwError(NetworkError.parsingFailed))
                    }
                }
                
                // MARK: ---- with a string value
                context("with a string value") {
                    // MARK: ------ decodes successfully
                    it("decodes successfully") {
                        let data: Data = "l4:Test5:\u{01}\u{02}\u{03}\u{04}\u{05}e".data(using: .utf8)!
                        let result: BencodeResponse<String>? = try? Bencode.decodeResponse(from: data)

                        expect(result)
                            .to(equal(
                                BencodeResponse(
                                    info: "Test",
                                    data: Data([1, 2, 3, 4, 5])
                                )
                            ))
                    }

                    // MARK: ------ decodes successfully with no body
                    it("decodes successfully with no body") {
                        let data: Data = "l4:Teste".data(using: .utf8)!
                        let result: BencodeResponse<String>? = try? Bencode.decodeResponse(from: data)

                        expect(result)
                            .to(equal(
                                BencodeResponse(
                                    info: "Test",
                                    data: nil
                                )
                            ))
                    }

                    // MARK: ------ throws a parsing error when invalid
                    it("throws a parsing error when invalid") {
                        let data: Data = "l10:Teste".data(using: .utf8)!

                        expect {
                            let result: BencodeResponse<String> = try Bencode.decodeResponse(from: data)
                            _ = result
                        }.to(throwError(NetworkError.parsingFailed))
                    }
                }
                
                // MARK: ---- with an int value
                context("with an int value") {
                    // MARK: ------ decodes successfully
                    it("decodes successfully") {
                        let data: Data = "li100e5:\u{01}\u{02}\u{03}\u{04}\u{05}e".data(using: .utf8)!
                        let result: BencodeResponse<Int>? = try? Bencode.decodeResponse(from: data)

                        expect(result)
                            .to(equal(
                                BencodeResponse(
                                    info: 100,
                                    data: Data([1, 2, 3, 4, 5])
                                )
                            ))
                    }

                    // MARK: ------ decodes successfully with no body
                    it("decodes successfully with no body") {
                        let data: Data = "li100ee".data(using: .utf8)!
                        let result: BencodeResponse<Int>? = try? Bencode.decodeResponse(from: data)

                        expect(result)
                            .to(equal(
                                BencodeResponse(
                                    info: 100,
                                    data: nil
                                )
                            ))
                    }

                    // MARK: ------ throws a parsing error when invalid
                    it("throws a parsing error when invalid") {
                        let data: Data = "l4:Teste".data(using: .utf8)!

                        expect {
                            let result: BencodeResponse<Int> = try Bencode.decodeResponse(from: data)
                            _ = result
                        }.to(throwError(NetworkError.parsingFailed))
                    }
                }
            }
        }
    }
}

// MARK: - Test Types

fileprivate struct TestType: Codable, Equatable {
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
