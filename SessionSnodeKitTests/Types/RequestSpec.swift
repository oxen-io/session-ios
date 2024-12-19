// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionSnodeKit

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
                let request: Request<NoBody, TestEndpoint> = try! Request(
                    endpoint: .test1,
                    destination: try! .server(
                        server: "testServer",
                        x25519PublicKey: ""
                    )
                )
                
                expect(request.destination.method.rawValue).to(equal("GET"))
                expect(request.destination.headers).to(equal([:]))
                expect(request.body).to(beNil())
            }
            
            // MARK: ---- sets all the values correctly
            it("sets all the values correctly") {
                let request: Request<NoBody, TestEndpoint> = try! Request(
                    endpoint: .test1,
                    destination: try! .server(
                        method: .delete,
                        server: "testServer",
                        headers: [
                            .testHeader: "test"
                        ],
                        x25519PublicKey: ""
                    )
                )
                
                expect(request.destination.url?.absoluteString).to(equal("testServer/test1"))
                expect(request.destination.method.rawValue).to(equal("DELETE"))
                expect(request.destination.urlPathAndParamsString).to(equal("/test1"))
                expect(request.destination.headers).to(equal(["TestHeader": "test"]))
                expect(request.body).to(beNil())
            }
            
            // MARK: ---- with a base64 string body
            context("with a base64 string body") {
                // MARK: ------ successfully encodes the body
                it("successfully encodes the body") {
                    let request: Request<String, TestEndpoint> = try! Request(
                        endpoint: .test1,
                        destination: try! .server(
                            server: "testServer",
                            x25519PublicKey: ""
                        ),
                        body: "TestMessage".data(using: .utf8)!.base64EncodedString()
                    )
                    
                    let requestBody: Data? = try? request.bodyData(using: dependencies)
                    let requestBodyString: String? = String(data: requestBody ?? Data(), encoding: .utf8)
                    
                    expect(requestBodyString).to(equal("TestMessage"))
                }
                
                // MARK: ------ throws an error if the body is not base64 encoded
                it("throws an error if the body is not base64 encoded") {
                    let request: Request<String, TestEndpoint> = try! Request(
                        endpoint: .test1,
                        destination: try! .server(
                            server: "testServer",
                            x25519PublicKey: ""
                        ),
                        body: "TestMessage"
                    )
                    
                    expect {
                        _ = try request.bodyData(using: dependencies)
                    }
                    .to(throwError(NetworkError.parsingFailed))
                }
            }
            
            // MARK: ---- with a byte body
            context("with a byte body") {
                // MARK: ------ successfully encodes the body
                it("successfully encodes the body") {
                    let request: Request<[UInt8], TestEndpoint> = try! Request(
                        endpoint: .test1,
                        destination: try! .server(
                            server: "testServer",
                            x25519PublicKey: ""
                        ),
                        body: [1, 2, 3]
                    )
                    
                    let requestBody: Data? = try? request.bodyData(using: dependencies)
                    
                    expect(requestBody?.bytes).to(equal([1, 2, 3]))
                }
            }
            
            // MARK: ---- with a JSON body
            context("with a JSON body") {
                // MARK: ------ successfully encodes the body
                it("successfully encodes the body") {
                    let request: Request<TestType, TestEndpoint> = try! Request(
                        endpoint: .test1,
                        destination: try! .server(
                            server: "testServer",
                            x25519PublicKey: ""
                        ),
                        body: TestType(stringValue: "test")
                    )
                    
                    let requestBodyData: Data? = try? request.bodyData(using: dependencies)
                    let requestBody: TestType? = try? JSONDecoder(using: dependencies).decode(
                        TestType.self,
                        from: requestBodyData ?? Data()
                    )
                    
                    expect(requestBody).to(equal(TestType(stringValue: "test")))
                }
                
                // MARK: ------ successfully encodes no body
                it("successfully encodes no body") {
                    let request: Request<NoBody, TestEndpoint> = try! Request(
                        endpoint: .test1,
                        destination: try! .server(
                            server: "testServer",
                            x25519PublicKey: ""
                        ),
                        body: nil
                    )
                    
                    expect {
                        _ = try request.bodyData(using: dependencies)
                    }.toNot(throwError())
                }
            }
        }
    }
}

// MARK: - Test Types

fileprivate extension HTTPHeader {
    static let testHeader: HTTPHeader = "TestHeader"
}

fileprivate enum TestEndpoint: EndpointType {
    case test1
    
    static var name: String { "TestEndpoint" }
    static var batchRequestVariant: Network.BatchRequest.Child.Variant { .storageServer }
    static var excludedSubRequestHeaders: [HTTPHeader] { [] }
    
    var path: String {
        switch self {
            case .test1: return "test1"
        }
    }
}

fileprivate struct TestType: Codable, Equatable {
    let stringValue: String
}
