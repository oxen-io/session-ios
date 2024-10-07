// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionSnodeKit

class BencodeResponseSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        
        // MARK: - BencodeResponse
        describe("BencodeResponse") {
            // MARK: -- when decoding
            context("when decoding") {
                // MARK: ---- with a decodable type
                context("with a decodable type") {
                    // MARK: ------ decodes successfully
                    it("decodes successfully") {
                        let data: Data = "ld8:intValuei100e11:stringValue4:Teste5:\u{01}\u{02}\u{03}\u{04}\u{05}e"
                            .data(using: .utf8)!
                        let result: BencodeResponse<TestType>? = try? BencodeDecoder(using: dependencies)
                            .decode(BencodeResponse<TestType>.self, from: data)
                        
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
                        let result: BencodeResponse<TestType>? = try? BencodeDecoder(using: dependencies)
                            .decode(BencodeResponse<TestType>.self, from: data)
                        
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
                }
                
                // MARK: ---- with stringified json info
                context("with stringified json info") {
                    // MARK: ------ decodes successfully
                    it("decodes successfully") {
                        let data: Data = "l37:{\"intValue\":100,\"stringValue\":\"Test\"}5:\u{01}\u{02}\u{03}\u{04}\u{05}e"
                            .data(using: .utf8)!
                        let result: BencodeResponse<TestType>? = try? BencodeDecoder(using: dependencies)
                            .decode(BencodeResponse<TestType>.self, from: data)
                        
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
                        let result: BencodeResponse<TestType>? = try? BencodeDecoder(using: dependencies)
                            .decode(BencodeResponse<TestType>.self, from: data)
                        
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
                            try BencodeDecoder(using: dependencies).decode(BencodeResponse<TestType>.self, from: data)
                        }.to(throwError(DecodingError.keyNotFound(TestType.CodingKeys.intValue, DecodingError.Context(codingPath: [], debugDescription: "No value associated with key \(TestType.CodingKeys.intValue)"))))
                    }
                }
                
                // MARK: ---- with a string value
                context("with a string value") {
                    // MARK: ------ decodes successfully
                    it("decodes successfully") {
                        let data: Data = "l4:Test5:\u{01}\u{02}\u{03}\u{04}\u{05}e".data(using: .utf8)!
                        let result: BencodeResponse<String>? = try? BencodeDecoder(using: dependencies)
                            .decode(BencodeResponse<String>.self, from: data)

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
                        let result: BencodeResponse<String>? = try? BencodeDecoder(using: dependencies)
                            .decode(BencodeResponse<String>.self, from: data)

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
                            try BencodeDecoder(using: dependencies).decode(BencodeResponse<String>.self, from: data)
                        }.to(throwError(DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "failed to decode String"))))
                    }
                }
                
                // MARK: ---- with an int value
                context("with an int value") {
                    // MARK: ------ decodes successfully
                    it("decodes successfully") {
                        let data: Data = "li100e5:\u{01}\u{02}\u{03}\u{04}\u{05}e".data(using: .utf8)!
                        let result: BencodeResponse<Int>? = try? BencodeDecoder(using: dependencies)
                            .decode(BencodeResponse<Int>.self, from: data)

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
                        let result: BencodeResponse<Int>? = try? BencodeDecoder(using: dependencies)
                            .decode(BencodeResponse<Int>.self, from: data)

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
                            try BencodeDecoder(using: dependencies).decode(BencodeResponse<Int>.self, from: data)
                        }.to(throwError(DecodingError.dataCorrupted(DecodingError.Context(
                            codingPath: [],
                            debugDescription: "The given data was not valid JSON",
                            underlyingError: NSError(
                                domain: "NSCocoaErrorDomain",
                                code: 3840,
                                userInfo: [
                                    "NSJSONSerializationErrorIndex": 0,
                                    "NSDebugDescription": "Unexpected character 'T' around line 1, column 1."
                                ]
                            )
                        ))))
                    }
                }
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
