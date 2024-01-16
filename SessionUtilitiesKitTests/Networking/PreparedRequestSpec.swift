// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

import Quick
import Nimble

@testable import SessionUtilitiesKit

class PreparedRequestSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration

        @TestState var dependencies: TestDependencies! = TestDependencies()
        
        @TestState var urlRequest: URLRequest?
        @TestState var preparedRequest: HTTP.PreparedRequest<TestType>!
        @TestState var request: Request<NoBody, TestEndpoint>!
        @TestState var responseInfo: ResponseInfoType! = HTTP.ResponseInfo(code: 200, headers: [:])
        
        // MARK: - a PreparedRequest
        describe("a PreparedRequest") {
            // MARK: -- when generating a URLRequest
            context("when generating a URLRequest") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    request = Request<NoBody, TestEndpoint>(
                        method: .post,
                        server: "testServer",
                        endpoint: .endpoint,
                        queryParameters: [:],
                        headers: [
                            "TestCustomHeader": "TestCustom",
                            HTTPHeader.testHeader: "Test"
                        ],
                        x25519PublicKey: "",
                        body: nil
                    )
                    preparedRequest = HTTP.PreparedRequest(
                        request: request,
                        urlRequest: try! request.generateUrlRequest(using: dependencies),
                        responseType: TestType.self,
                        timeout: 10
                    )
                    
                    expect(preparedRequest.request.url?.absoluteString).to(equal("testServer/endpoint"))
                    expect(preparedRequest.request.httpMethod).to(equal("POST"))
                    expect(preparedRequest.request.allHTTPHeaderFields).to(equal([
                        "TestCustomHeader": "TestCustom",
                        HTTPHeader.testHeader: "Test"
                    ]))
                }
                
                // MARK: ---- does not strip excluded subrequest headers
                it("does not strip excluded subrequest headers") {
                    request = Request<NoBody, TestEndpoint>(
                        method: .post,
                        server: "testServer",
                        endpoint: .endpoint,
                        queryParameters: [:],
                        headers: [
                            "TestCustomHeader": "TestCustom",
                            HTTPHeader.testHeader: "Test"
                        ],
                        x25519PublicKey: "",
                        body: nil
                    )
                    preparedRequest = HTTP.PreparedRequest(
                        request: request,
                        urlRequest: try! request.generateUrlRequest(using: dependencies),
                        responseType: TestType.self,
                        timeout: 10
                    )
                    
                    expect(TestEndpoint.excludedSubRequestHeaders).to(equal([HTTPHeader.testHeader]))
                    expect(preparedRequest.request.allHTTPHeaderFields?.keys).to(contain([HTTPHeader.testHeader]))
                }
            }
        }
        
        // MARK: - a Decodable
        describe("a Decodable") {
            // MARK: -- decodes correctly
            it("decodes correctly") {
                let jsonData: Data = "{\"stringValue\":\"testValue\"}".data(using: .utf8)!
                let result: TestType? = try? TestType.decoded(from: jsonData)
                
                expect(result).to(equal(TestType(stringValue: "testValue")))
            }
        }
        
        // MARK: - a (ResponseInfoType, Data?) Publisher
        describe("a (ResponseInfoType, Data?) Publisher") {
            // MARK: -- decodes valid data correctly
            it("decodes valid data correctly") {
                let jsonData: Data = "{\"stringValue\":\"testValue\"}".data(using: .utf8)!
                var result: (info: ResponseInfoType, response: TestType)?
                Just((responseInfo, jsonData))
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
                    .decoded(as: TestType.self)
                    .sinkUntilComplete(
                        receiveValue: { result = $0 }
                    )
        
                expect(result).toNot(beNil())
                expect(result?.response).to(equal(TestType(stringValue: "testValue")))
            }
            
            // MARK: -- fails if there is no data
            it("fails if there is no data") {
                var error: Error?
                Just((responseInfo, nil))
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
                    .decoded(as: [Int].self)
                    .mapError { error.setting(to: $0) }
                    .sinkUntilComplete()
                
                expect(error).to(matchError(HTTPError.parsingFailed))
            }
            
            // MARK: -- fails if the data is not JSON
            it("fails if the data is not JSON") {
                var error: Error?
                Just((responseInfo, Data([1, 2, 3])))
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
                    .decoded(as: [Int].self)
                    .mapError { error.setting(to: $0) }
                    .sinkUntilComplete()
                
                expect(error).to(matchError(HTTPError.parsingFailed))
            }
            
            // MARK: -- fails if the data is not a JSON array
            it("fails if the data is not a JSON array") {
                var error: Error?
                Just((responseInfo, "{}".data(using: .utf8)))
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
                    .decoded(as: [Int].self)
                    .mapError { error.setting(to: $0) }
                    .sinkUntilComplete()
                
                expect(error).to(matchError(HTTPError.parsingFailed))
            }
        }
    }
}

// MARK: - Test Types

fileprivate extension HTTPHeader {
    static let testHeader: HTTPHeader = "TestHeader"
}

fileprivate enum TestEndpoint: EndpointType {
    case endpoint
    
    static var name: String { "TestEndpoint" }
    static var batchRequestVariant: HTTP.BatchRequest.Child.Variant { .storageServer }
    static var excludedSubRequestHeaders: [HTTPHeader] { [.testHeader] }
    
    var path: String { return "endpoint" }
}

fileprivate struct TestType: Codable, Equatable {
    let stringValue: String
}
