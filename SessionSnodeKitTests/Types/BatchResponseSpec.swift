// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionSnodeKit

class BatchResponseSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var responseInfo: ResponseInfoType! = Network.ResponseInfo(code: 200, headers: [:])
        @TestState var testType: TestType! = TestType(stringValue: "test1")
        @TestState var testType2: TestType2! = TestType2(intValue: 123, stringValue2: "test2")
        @TestState var data: Data! = """
            [\([
                try! JSONEncoder().with(outputFormatting: .sortedKeys).encode(
                    Network.BatchSubResponse(
                        code: 200,
                        headers: [:],
                        body: testType,
                        failedToParseBody: false
                    )
                ),
                try! JSONEncoder().with(outputFormatting: .sortedKeys).encode(
                    Network.BatchSubResponse(
                        code: 200,
                        headers: [:],
                        body: testType2,
                        failedToParseBody: false
                    )
                )
            ]
            .map { String(data: $0, encoding: .utf8)! }
            .joined(separator: ","))]
            """.data(using: .utf8)!
        
        // MARK: - an Network.BatchSubResponse<T>
        describe("an Network.BatchSubResponse<T>") {
            // MARK: -- when decoding
            context("when decoding") {
                // MARK: ---- decodes correctly
                it("decodes correctly") {
                    let jsonString: String = """
                    {
                        "code": 200,
                        "headers": {
                            "testKey": "testValue"
                        },
                        "body": {
                            "stringValue": "testValue"
                        }
                    }
                    """
                    let subResponse: Network.BatchSubResponse<TestType>? = try? JSONDecoder().decode(
                        Network.BatchSubResponse<TestType>.self,
                        from: jsonString.data(using: .utf8)!
                    )
                    
                    expect(subResponse).toNot(beNil())
                    expect(subResponse?.body).toNot(beNil())
                }
                
                // MARK: ---- decodes with invalid body data
                it("decodes with invalid body data") {
                    let jsonString: String = """
                    {
                        "code": 200,
                        "headers": {
                            "testKey": "testValue"
                        },
                        "body": "Hello!!!"
                    }
                    """
                    let subResponse: Network.BatchSubResponse<TestType>? = try? JSONDecoder().decode(
                        Network.BatchSubResponse<TestType>.self,
                        from: jsonString.data(using: .utf8)!
                    )
                    
                    expect(subResponse).toNot(beNil())
                }
                
                // MARK: ---- flags invalid body data as invalid
                it("flags invalid body data as invalid") {
                    let jsonString: String = """
                    {
                        "code": 200,
                        "headers": {
                            "testKey": "testValue"
                        },
                        "body": "Hello!!!"
                    }
                    """
                    let subResponse: Network.BatchSubResponse<TestType>? = try? JSONDecoder().decode(
                        Network.BatchSubResponse<TestType>.self,
                        from: jsonString.data(using: .utf8)!
                    )
                    
                    expect(subResponse).toNot(beNil())
                    expect(subResponse?.body).to(beNil())
                    expect(subResponse?.failedToParseBody).to(beTrue())
                }
                
                // MARK: ---- does not flag a missing or invalid optional body as invalid
                it("does not flag a missing or invalid optional body as invalid") {
                    let jsonString: String = """
                    {
                        "code": 200,
                        "headers": {
                            "testKey": "testValue"
                        }
                    }
                    """
                    let subResponse: Network.BatchSubResponse<TestType?>? = try? JSONDecoder().decode(
                        Network.BatchSubResponse<TestType?>.self,
                        from: jsonString.data(using: .utf8)!
                    )
                    
                    expect(subResponse).toNot(beNil())
                    expect(subResponse?.body).to(beNil())
                    expect(subResponse?.failedToParseBody).to(beFalse())
                }
                
                // MARK: ---- does not flag a NoResponse body as invalid
                it("does not flag a NoResponse body as invalid") {
                    let jsonString: String = """
                    {
                        "code": 200,
                        "headers": {
                            "testKey": "testValue"
                        }
                    }
                    """
                    let subResponse: Network.BatchSubResponse<NoResponse>? = try? JSONDecoder().decode(
                        Network.BatchSubResponse<NoResponse>.self,
                        from: jsonString.data(using: .utf8)!
                    )
                    
                    expect(subResponse).toNot(beNil())
                    expect(subResponse?.body).to(beNil())
                    expect(subResponse?.failedToParseBody).to(beFalse())
                }
            }
        }
        
        // MARK: - an Network.BatchResponse
        describe("an Network.BatchResponse") {
            // MARK: -- when decoding responses
            context("when decoding responses") {
                // MARK: -- decodes valid data correctly
                it("decodes valid data correctly") {
                    let result: Network.BatchResponse? = try? Network.BatchResponse.decodingResponses(
                        from: data,
                        as: [
                            Network.BatchSubResponse<TestType>.self,
                            Network.BatchSubResponse<TestType2>.self
                        ],
                        requireAllResults: true,
                        using: dependencies
                    )
                    
                    expect(result).toNot(beNil())
                    expect((result?.data[0] as? Network.BatchSubResponse<TestType>)?.body)
                        .to(equal(testType))
                    expect((result?.data[1] as? Network.BatchSubResponse<TestType2>)?.body)
                        .to(equal(testType2))
                }
            }
            
            // MARK: -- fails if there is no data
            it("fails if there is no data") {
                expect {
                    try Network.BatchResponse.decodingResponses(
                        from: nil,
                        as: [Int.self],
                        requireAllResults: true,
                        using: dependencies
                    )
                }.to(throwError(NetworkError.parsingFailed))
            }
            
            // MARK: -- fails if the data is not JSON
            it("fails if the data is not JSON") {
                expect {
                    try Network.BatchResponse.decodingResponses(
                        from: Data([1, 2, 3]),
                        as: [Int.self],
                        requireAllResults: true,
                        using: dependencies
                    )
                }.to(throwError(NetworkError.parsingFailed))
            }
            
            // MARK: -- fails if the data is not a JSON array
            it("fails if the data is not a JSON array") {
                expect {
                    try Network.BatchResponse.decodingResponses(
                        from: "{}".data(using: .utf8),
                        as: [Int.self],
                        requireAllResults: true,
                        using: dependencies
                    )
                }.to(throwError(NetworkError.parsingFailed))
            }
            
            // MARK: -- and requiring all responses
            context("and requiring all responses") {
                // MARK: ---- fails if the JSON array does not have the same number of items as the expected types
                it("fails if the JSON array does not have the same number of items as the expected types") {
                    expect {
                        try Network.BatchResponse.decodingResponses(
                            from: data,
                            as: [
                                Network.BatchSubResponse<TestType>.self,
                                Network.BatchSubResponse<TestType2>.self,
                                Network.BatchSubResponse<TestType2>.self
                            ],
                            requireAllResults: true,
                            using: dependencies
                        )
                    }.to(throwError(NetworkError.parsingFailed))
                }
                
                // MARK: ---- fails if one of the JSON array values fails to decode
                it("fails if one of the JSON array values fails to decode") {
                    data = """
                    [\([
                        try! JSONEncoder().with(outputFormatting: .sortedKeys).encode(
                            Network.BatchSubResponse(
                                code: 200,
                                headers: [:],
                                body: testType,
                                failedToParseBody: false
                            )
                        )
                    ]
                    .map { String(data: $0, encoding: .utf8)! }
                    .joined(separator: ",")),{"test": "test"}]
                    """.data(using: .utf8)!
                    
                    expect {
                        try Network.BatchResponse.decodingResponses(
                            from: data,
                            as: [
                                Network.BatchSubResponse<TestType>.self,
                                Network.BatchSubResponse<TestType2>.self
                            ],
                            requireAllResults: true,
                            using: dependencies
                        )
                    }.to(throwError(NetworkError.parsingFailed))
                }
            }
            
            // MARK: -- and not requiring all responses
            context("and not requiring all responses") {
                // MARK: ---- succeeds when the JSON array does not have the same number of items as the expected types
                it("succeeds when the JSON array does not have the same number of items as the expected types") {
                    expect {
                        try Network.BatchResponse.decodingResponses(
                            from: data,
                            as: [
                                Network.BatchSubResponse<TestType>.self,
                                Network.BatchSubResponse<TestType2>.self,
                                Network.BatchSubResponse<TestType2>.self
                            ],
                            requireAllResults: false,
                            using: dependencies
                        )
                    }.toNot(throwError(NetworkError.parsingFailed))
                }
            }
        }
    }
}

// MARK: - Test Types

fileprivate struct TestType: Codable, Equatable {
    let stringValue: String
}
fileprivate struct TestType2: Codable, Equatable {
    let intValue: Int
    let stringValue2: String
}
