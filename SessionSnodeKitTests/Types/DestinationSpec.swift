// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionSnodeKit

class DestinationSpec: QuickSpec {
    override class func spec() {
        // MARK: - a Destination
        describe("a Destination") {
            // MARK: -- when generating a path
            context("when generating a path") {
                // MARK: ---- adds a leading forward slash to the endpoint path
                it("adds a leading forward slash to the endpoint path") {
                    let result: String = Network.Destination.generatePathsAndParams(
                        endpoint: TestEndpoint.test1,
                        queryParameters: [:]
                    )
                    
                    expect(result).to(equal("/test1"))
                }
                
                // MARK: ---- creates a valid URL with no query parameters
                it("creates a valid URL with no query parameters") {
                    let result: String = Network.Destination.generatePathsAndParams(
                        endpoint: TestEndpoint.test1,
                        queryParameters: [:]
                    )
                    
                    expect(result).to(equal("/test1"))
                }
                
                // MARK: ---- creates a valid URL when query parameters are provided
                it("creates a valid URL when query parameters are provided") {
                    let result: String = Network.Destination.generatePathsAndParams(
                        endpoint: TestEndpoint.test1,
                        queryParameters: [
                            .testParam: "123"
                        ]
                    )
                    
                    expect(result).to(equal("/test1?testParam=123"))
                }
            }
            
            // MARK: -- for a server
            context("for a server") {
                // MARK: ---- throws an error if the generated URL is invalid
                it("throws an error if the generated URL is invalid") {
                    expect {
                        _ = try Network.Destination.server(
                            server: "ftp:// test Server",
                            x25519PublicKey: ""
                        ).withGeneratedUrl(for: TestEndpoint.testParams("test", 123))
                    }
                    .to(throwError(NetworkError.invalidURL))
                }
            }
        }
    }
}

// MARK: - Test Types

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
