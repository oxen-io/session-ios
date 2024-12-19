// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionSnodeKit

class SnodeRequestSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var batchRequest: Network.BatchRequest!
        
        // MARK: - a SnodeRequest
        describe("a SnodeRequest") {
            // MARK: -- when encoding a Network.BatchRequest storage server type endpoint
            context("when encoding a Network.BatchRequest storage server type endpoint") {
                // MARK: ---- successfully encodes a SnodeRequest body
                it("successfully encodes a SnodeRequest body") {
                    batchRequest = Network.BatchRequest(
                        requestsKey: .requests,
                        requests: [
                            try! Network.PreparedRequest<NoResponse>(
                                request: Request<SnodeRequest<TestType>, TestEndpoint>(
                                    endpoint: .endpoint,
                                    destination: try! .server(
                                        method: .post,
                                        server: "testServer",
                                        x25519PublicKey: "05\(TestConstants.publicKey)"
                                    ),
                                    body: SnodeRequest<TestType>(
                                        endpoint: .sendMessage,
                                        body: TestType(stringValue: "testValue")
                                    )
                                ),
                                responseType: NoResponse.self,
                                requestTimeout: 0,
                                using: dependencies
                            )
                        ]
                    )
                    
                    let requestData: Data? = try? JSONEncoder().encode(batchRequest)
                    let requestJson: [String: [[String: Any]]]? = requestData
                        .map { try? JSONSerialization.jsonObject(with: $0) as? [String: [[String: Any]]] }
                    let request: [String: Any]? = requestJson?["requests"]?.first
                    expect(request?["method"] as? String).to(equal("store"))
                    expect(request?["params"] as? [String: String]).to(equal(["stringValue": "testValue"]))
                }
            }
        }
    }
}

// MARK: - Test Types

fileprivate enum TestEndpoint: EndpointType {
    case endpoint
    
    static var name: String { "TestEndpoint" }
    static var batchRequestVariant: Network.BatchRequest.Child.Variant { .storageServer }
    static var excludedSubRequestHeaders: [HTTPHeader] { [] }
    
    var path: String { return "endpoint" }
}

fileprivate struct TestType: Codable, Equatable {
    let stringValue: String
}
