// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionUtilitiesKit

class RequestSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration

        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var urlRequest: URLRequest?
        @TestState var request: Request<NoBody, TestEndpoint>!
        @TestState var responseInfo: ResponseInfoType! = Network.ResponseInfo(code: 200, headers: [:])
        
        // MARK: - a Request
        describe("a Request") {
            // MARK: -- is initialized with the correct default values
            it("is initialized with the correct default values") {
                let request: Request<NoBody, TestEndpoint> = Request(
                    endpoint: .test1,
                    target:  Network.ServerTarget(
                        server: "testServer",
                        endpoint: TestEndpoint.test1,
                        queryParameters: [:],
                        x25519PublicKey: ""
                    )
                )
                
                expect(request.method.rawValue).to(equal("GET"))
                expect(request.headers).to(equal([:]))
                expect(request.body).to(beNil())
            }
            
            // MARK: -- when generating a URLRequest
            context("when generating a URLRequest") {
                // MARK: ---- generates the request correctly
                it("generates the request correctly") {
                    request = Request<NoBody, TestEndpoint>(
                        method: .post,
                        server: "testServer",
                        endpoint: .test1,
                        queryParameters: [:],
                        headers: [
                            "TestCustomHeader": "TestCustom",
                            HTTPHeader.testHeader: "Test"
                        ],
                        x25519PublicKey: "",
                        body: nil
                    )
                    urlRequest = try? request.generateUrlRequest(using: dependencies)
                    
                    expect(urlRequest?.url?.absoluteString).to(equal("testServer/test1"))
                    expect(urlRequest?.httpMethod).to(equal("POST"))
                    expect(urlRequest?.allHTTPHeaderFields).to(equal([
                        "TestCustomHeader": "TestCustom",
                        HTTPHeader.testHeader: "Test"
                    ]))
                }
                
                // MARK: ---- sets all the values correctly
                it("sets all the values correctly") {
                    let request: Request<NoBody, TestEndpoint> = Request(
                        method: .delete,
                        server: "testServer",
                        endpoint: .test1,
                        headers: [
                            .authorization: "test"
                        ],
                        x25519PublicKey: ""
                    )
                    let urlRequest: URLRequest? = try? request.generateUrlRequest(using: dependencies)
                    
                    expect(urlRequest?.httpMethod).to(equal("DELETE"))
                    expect(urlRequest?.allHTTPHeaderFields).to(equal(["Authorization": "test"]))
                    expect(urlRequest?.httpBody).to(beNil())
                }
                
                // MARK: ---- throws an error if the URL is invalid
                it("throws an error if the URL is invalid") {
                    let request: Request<NoBody, TestEndpoint> = Request(
                        server: "ftp:// test Server",
                        endpoint: .testParams("test", 123),
                        x25519PublicKey: ""
                    )
                    
                    expect {
                        try request.generateUrlRequest(using: dependencies)
                    }
                    .to(throwError(NetworkError.invalidURL))
                }
                
                // MARK: ---- with a base64 string body
                context("with a base64 string body") {
                    // MARK: ------ successfully encodes the body
                    it("successfully encodes the body") {
                        let request: Request<String, TestEndpoint> = Request(
                            server: "testServer",
                            endpoint: .test1,
                            x25519PublicKey: "",
                            body: "TestMessage".data(using: .utf8)!.base64EncodedString()
                        )
                        
                        let urlRequest: URLRequest? = try? request.generateUrlRequest(using: dependencies)
                        let requestBody: Data? = Data(base64Encoded: urlRequest?.httpBody?.base64EncodedString() ?? "")
                        let requestBodyString: String? = String(data: requestBody ?? Data(), encoding: .utf8)
                        
                        expect(requestBodyString).to(equal("TestMessage"))
                    }
                    
                    // MARK: ------ throws an error if the body is not base64 encoded
                    it("throws an error if the body is not base64 encoded") {
                        let request: Request<String, TestEndpoint> = Request(
                            server: "testServer",
                            endpoint: .test1,
                            x25519PublicKey: "",
                            body: "TestMessage"
                        )
                        
                        expect {
                            try request.generateUrlRequest(using: dependencies)
                        }
                        .to(throwError(NetworkError.parsingFailed))
                    }
                }
                
                // MARK: ---- with a byte body
                context("with a byte body") {
                    // MARK: ------ successfully encodes the body
                    it("successfully encodes the body") {
                        let request: Request<[UInt8], TestEndpoint> = Request(
                            server: "testServer",
                            endpoint: .test1,
                            x25519PublicKey: "",
                            body: [1, 2, 3]
                        )
                        
                        let urlRequest: URLRequest? = try? request.generateUrlRequest(using: dependencies)
                        
                        expect(urlRequest?.httpBody?.bytes).to(equal([1, 2, 3]))
                    }
                }
                
                // MARK: ---- with a JSON body
                context("with a JSON body") {
                    // MARK: ------ successfully encodes the body
                    it("successfully encodes the body") {
                        let request: Request<TestType, TestEndpoint> = Request(
                            server: "testServer",
                            endpoint: .test1,
                            x25519PublicKey: "",
                            body: TestType(stringValue: "test")
                        )
                        
                        let urlRequest: URLRequest? = try? request.generateUrlRequest(using: dependencies)
                        let requestBody: TestType? = try? JSONDecoder(using: dependencies).decode(
                            TestType.self,
                            from: urlRequest?.httpBody ?? Data()
                        )
                        
                        expect(requestBody).to(equal(TestType(stringValue: "test")))
                    }
                    
                    // MARK: ------ successfully encodes no body
                    it("successfully encodes no body") {
                        let request: Request<NoBody, TestEndpoint> = Request(
                            server: "testServer",
                            endpoint: .test1,
                            x25519PublicKey: "",
                            body: nil
                        )
                        
                        expect {
                            try request.generateUrlRequest(using: dependencies)
                        }.toNot(throwError())
                    }
                }
            }
        }
        
        // MARK: - a HTTP ServerTarget
        describe("a HTTP ServerTarget") {
            // MARK: ---- adds a leading forward slash to the endpoint path
            it("adds a leading forward slash to the endpoint path") {
                let target: Network.ServerTarget = Network.ServerTarget(
                    server: "testServer",
                    endpoint: TestEndpoint.test1,
                    queryParameters: [:],
                    x25519PublicKey: ""
                )
                
                expect(target.urlPathAndParamsString).to(equal("/test1"))
            }
            
            // MARK: ---- creates a valid URL with no query parameters
            it("creates a valid URL with no query parameters") {
                let target: Network.ServerTarget = Network.ServerTarget(
                    server: "testServer",
                    endpoint: TestEndpoint.test1,
                    queryParameters: [:],
                    x25519PublicKey: ""
                )
                
                expect(target.urlPathAndParamsString).to(equal("/test1"))
            }
            
            // MARK: ---- creates a valid URL when query parameters are provided
            it("creates a valid URL when query parameters are provided") {
                let target: Network.ServerTarget = Network.ServerTarget(
                    server: "testServer",
                    endpoint: TestEndpoint.test1,
                    queryParameters: [
                        .testParam: "123"
                    ],
                    x25519PublicKey: ""
                )
                
                expect(target.urlPathAndParamsString).to(equal("/test1?testParam=123"))
            }
        }
    }
}

// MARK: - Test Types

fileprivate extension HTTPHeader {
    static let testHeader: HTTPHeader = "TestHeader"
}

fileprivate extension HTTPQueryParam {
    static let testParam: HTTPQueryParam = "testParam"
}

fileprivate enum TestEndpoint: EndpointType {
    case test1
    case testParams(String, Int)
    
    static var name: String { "TestEndpoint" }
    static var batchRequestVariant: Network.BatchRequest.Child.Variant { .storageServer }
    static var excludedSubRequestHeaders: [HTTPHeader] { [] }
    
    var path: String {
        switch self {
            case .test1: return "test1"
            case .testParams(let str, let int): return "testParams/\(str)/int/\(int)"
        }
    }
}

fileprivate struct TestType: Codable, Equatable {
    let stringValue: String
}
