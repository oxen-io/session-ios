// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionSnodeKit

class BatchRequestSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var request: Network.BatchRequest!
        
        // MARK: - a BatchRequest.Child
        describe("a BatchRequest.Child") {
            // MARK: -- when encoding
            context("when encoding") {
                // MARK: ---- correctly strips specified headers from sub requests
                it("correctly strips specified headers from sub requests") {
                    let httpRequest: Request<NoBody, TestEndpoint1> = try! Request<NoBody, TestEndpoint1>(
                        endpoint: .endpoint1,
                        destination: try! .server(
                            server: "testServer",
                            queryParameters: [:],
                            headers: [
                                "TestCustomHeader": "TestCustom",
                                HTTPHeader.testHeader: "Test"
                            ],
                            x25519PublicKey: "05\(TestConstants.publicKey)"
                        ),
                        body: nil
                    )
                    
                    request = Network.BatchRequest(
                        requests: [
                            try! Network.PreparedRequest<NoResponse>(
                                request: httpRequest,
                                responseType: NoResponse.self,
                                requestTimeout: 0,
                                using: dependencies
                            )
                        ]
                    )
                    
                    let requestData: Data = try! JSONEncoder().encode(request)
                    let requestString: String? = String(data: requestData, encoding: .utf8)
                    
                    expect(requestString)
                        .toNot(contain([
                            HTTPHeader.testHeader
                        ]))
                }
                
                // MARK: ---- does not strip unspecified headers from sub requests
                it("does not strip unspecified headers from sub requests") {
                    let httpRequest: Request<NoBody, TestEndpoint1> = try! Request<NoBody, TestEndpoint1>(
                        endpoint: .endpoint1,
                        destination: try! .server(
                            server: "testServer",
                            queryParameters: [:],
                            headers: [
                                "TestCustomHeader": "TestCustom",
                                HTTPHeader.testHeader: "Test"
                            ],
                            x25519PublicKey: "05\(TestConstants.publicKey)"
                        ),
                        body: nil
                    )
                    request = Network.BatchRequest(
                        requests: [
                            try! Network.PreparedRequest<NoResponse>(
                                request: httpRequest,
                                responseType: NoResponse.self,
                                requestTimeout: 0,
                                using: dependencies
                            )
                        ]
                    )
                    
                    let requestData: Data = try! JSONEncoder().encode(request)
                    let requestString: String? = String(data: requestData, encoding: .utf8)
                    
                    expect(requestString)
                        .to(contain("\"TestCustomHeader\":\"TestCustom\""))
                }
            }
            
            // MARK: -- when encoding a sogs type endpoint
            context("when encoding a sogs type endpoint") {
                // MARK: ---- successfully encodes a string body
                it("successfully encodes a string body") {
                    request = Network.BatchRequest(
                        requests: [
                            try! Network.PreparedRequest<NoResponse>(
                                request: Request<String, TestEndpoint1>(
                                    endpoint: .endpoint1,
                                    destination: try! .server(
                                        server: "testServer",
                                        queryParameters: [:],
                                        headers: [:],
                                        x25519PublicKey: "05\(TestConstants.publicKey)"
                                    ),
                                    body: "testBody"
                                ),
                                responseType: NoResponse.self,
                                requestTimeout: 0,
                                using: dependencies
                            )
                        ]
                    )
                    
                    let requestData: Data? = try? JSONEncoder().encode(request)
                    let requestJson: [[String: Any]]? = requestData
                        .map { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
                    expect(requestJson?.first?["path"] as? String).to(equal("/endpoint1"))
                    expect(requestJson?.first?["method"] as? String).to(equal("GET"))
                    expect(requestJson?.first?["b64"] as? String).to(equal("testBody"))
                }
                
                // MARK: ---- successfully encodes a byte body
                it("successfully encodes a byte body") {
                    request = Network.BatchRequest(
                        requests: [
                            try! Network.PreparedRequest<NoResponse>(
                                request: Request<[UInt8], TestEndpoint1>(
                                    endpoint: .endpoint1,
                                    destination: try! .server(
                                        server: "testServer",
                                        queryParameters: [:],
                                        headers: [:],
                                        x25519PublicKey: "05\(TestConstants.publicKey)"
                                    ),
                                    body: [1, 2, 3]
                                ),
                                responseType: NoResponse.self,
                                requestTimeout: 0,
                                using: dependencies
                            )
                        ]
                    )
                    
                    let requestData: Data? = try? JSONEncoder().encode(request)
                    let requestJson: [[String: Any]]? = requestData
                        .map { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
                    expect(requestJson?.first?["path"] as? String).to(equal("/endpoint1"))
                    expect(requestJson?.first?["method"] as? String).to(equal("GET"))
                    expect(requestJson?.first?["bytes"] as? [Int]).to(equal([1, 2, 3]))
                }
                
                // MARK: ---- successfully encodes a JSON body
                it("successfully encodes a JSON body") {
                    request = Network.BatchRequest(
                        requests: [
                            try! Network.PreparedRequest<NoResponse>(
                                request: Request<TestType, TestEndpoint1>(
                                    endpoint: .endpoint1,
                                    destination: try! .server(
                                        server: "testServer",
                                        queryParameters: [:],
                                        headers: [:],
                                        x25519PublicKey: "05\(TestConstants.publicKey)"
                                    ),
                                    body: TestType(stringValue: "testValue")
                                ),
                                responseType: NoResponse.self,
                                requestTimeout: 0,
                                using: dependencies
                            )
                        ]
                    )
                    
                    let requestData: Data? = try? JSONEncoder().encode(request)
                    let requestJson: [[String: Any]]? = requestData
                        .map { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
                    expect(requestJson?.first?["path"] as? String).to(equal("/endpoint1"))
                    expect(requestJson?.first?["method"] as? String).to(equal("GET"))
                    expect(requestJson?.first?["json"] as? [String: String]).to(equal(["stringValue": "testValue"]))
                }
            }
            
            // MARK: -- when encoding a storage server type endpoint
            context("when encoding a storage server type endpoint") {
                // MARK: ---- ignores a string body
                it("ignores a string body") {
                    request = Network.BatchRequest(
                        requestsKey: .requests,
                        requests: [
                            try! Network.PreparedRequest<NoResponse>(
                                request: Request<String, TestEndpoint2>(
                                    endpoint: .endpoint2,
                                    destination: try! .server(
                                        server: "testServer",
                                        queryParameters: [:],
                                        headers: [:],
                                        x25519PublicKey: "05\(TestConstants.publicKey)"
                                    ),
                                    body: "TestMessage".data(using: .utf8)!.base64EncodedString()
                                ),
                                responseType: NoResponse.self,
                                requestTimeout: 0,
                                using: dependencies
                            )
                        ]
                    )
                    
                    let requestData: Data? = try? JSONEncoder().encode(request)
                    let requestJson: [String: [[String: Any]]]? = requestData
                        .map { try? JSONSerialization.jsonObject(with: $0) as? [String: [[String: Any]]] }
                    let requests: [[String: Any]]? = requestJson?["requests"]
                    expect(requests?.count).to(equal(1))
                    expect(requests?.first?.count).to(equal(0))
                }
                
                // MARK: ---- ignores a byte body
                it("ignores a byte body") {
                    request = Network.BatchRequest(
                        requestsKey: .requests,
                        requests: [
                            try! Network.PreparedRequest<NoResponse>(
                                request: Request<[UInt8], TestEndpoint2>(
                                    endpoint: .endpoint2,
                                    destination: try! .server(
                                        server: "testServer",
                                        queryParameters: [:],
                                        headers: [:],
                                        x25519PublicKey: "05\(TestConstants.publicKey)"
                                    ),
                                    body: [1, 2, 3]
                                ),
                                responseType: NoResponse.self,
                                requestTimeout: 0,
                                using: dependencies
                            )
                        ]
                    )
                    
                    let requestData: Data? = try? JSONEncoder().encode(request)
                    let requestJson: [String: [[String: Any]]]? = requestData
                        .map { try? JSONSerialization.jsonObject(with: $0) as? [String: [[String: Any]]] }
                    let requests: [[String: Any]]? = requestJson?["requests"]
                    expect(requests?.count).to(equal(1))
                    expect(requests?.first?.count).to(equal(0))
                }
                
                // MARK: ---- successfully encodes a JSON body
                it("successfully encodes a JSON body") {
                    request = Network.BatchRequest(
                        requestsKey: .requests,
                        requests: [
                            try! Network.PreparedRequest<NoResponse>(
                                request: Request<TestType, TestEndpoint2>(
                                    endpoint: .endpoint2,
                                    destination: try! .server(
                                        server: "testServer",
                                        queryParameters: [:],
                                        headers: [:],
                                        x25519PublicKey: "05\(TestConstants.publicKey)"
                                    ),
                                    body: TestType(stringValue: "testValue")
                                ),
                                responseType: NoResponse.self,
                                requestTimeout: 0,
                                using: dependencies
                            )
                        ]
                    )
                    
                    let requestData: Data? = try? JSONEncoder().encode(request)
                    let requestJson: [String: [[String: Any]]]? = requestData
                        .map { try? JSONSerialization.jsonObject(with: $0) as? [String: [[String: Any]]] }
                    let requests: [[String: Any]]? = requestJson?["requests"]
                    expect(requests?.count).to(equal(1))
                    expect(requests?.first as? [String: String])
                        .to(equal(["stringValue": "testValue"]))
                }
            }
        }
    }
}

// MARK: - Test Types

fileprivate extension HTTPHeader {
    static let testHeader: HTTPHeader = "TestHeader"
}

fileprivate enum TestEndpoint1: EndpointType {
    case endpoint1
    
    static var name: String { "TestEndpoint1" }
    static var batchRequestVariant: Network.BatchRequest.Child.Variant { .sogs }
    static var excludedSubRequestHeaders: [HTTPHeader] { [.testHeader] }
    
    var path: String { return "endpoint1" }
}

fileprivate enum TestEndpoint2: EndpointType {
    case endpoint2
    
    static var name: String { "TestEndpoint2" }
    static var batchRequestVariant: Network.BatchRequest.Child.Variant { .storageServer }
    static var excludedSubRequestHeaders: [HTTPHeader] { [] }
    
    var path: String { return "endpoint2" }
}

fileprivate struct TestType: Codable, Equatable {
    let stringValue: String
}
