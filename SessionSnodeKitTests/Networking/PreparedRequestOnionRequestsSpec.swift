// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionSnodeKit

class PreparedRequestOnionRequestsSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
        }
        @TestState(singleton: .network, in: dependencies) var mockNetwork: MockNetwork! = MockNetwork()
        @TestState var preparedRequest: HTTP.PreparedRequest<Int>! = {
            let request = Request<NoBody, TestEndpoint>(
                method: .post,
                server: "https://www.oxen.io",
                endpoint: TestEndpoint.endpoint1,
                x25519PublicKey: ""
            )
            
            return HTTP.PreparedRequest(
                request: request,
                urlRequest: try! request.generateUrlRequest(using: dependencies),
                responseType: Int.self,
                retryCount: 0,
                timeout: 10
            )
        }()
        @TestState var error: Error?
        @TestState var disposables: [AnyCancellable]! = []
        
        // MARK: - a PreparedRequest sending Onion Requests
        describe("a PreparedRequest sending Onion Requests") {
            // MARK: -- when sending
            context("when sending") {
                beforeEach {
                    mockNetwork
                        .when { $0.send(.selectedNetworkRequest(.any, to: .any, with: .any, using: .any)) }
                        .thenReturn(MockNetwork.response(with: 1))
                }
                
                // MARK: ---- triggers sending correctly
                it("triggers sending correctly") {
                    var response: (info: ResponseInfoType, data: Int)?
                    
                    preparedRequest
                        .send(using: dependencies)
                        .handleEvents(receiveOutput: { result in response = result })
                        .mapError { error.setting(to: $0) }
                        .sinkAndStore(in: &disposables)
                    
                    expect(response).toNot(beNil())
                    expect(response?.data).to(equal(1))
                    expect(error).to(beNil())
                }
                
                // MARK: ---- returns an error when the prepared request is null
                it("returns an error when the prepared request is null") {
                    var response: (info: ResponseInfoType, data: Int)?
                    
                    preparedRequest = nil
                    preparedRequest
                        .send(using: dependencies)
                        .handleEvents(receiveOutput: { result in response = result })
                        .mapError { error.setting(to: $0) }
                        .sinkAndStore(in: &disposables)

                    expect(error).to(matchError(HTTPError.invalidPreparedRequest))
                    expect(response).to(beNil())
                }
                
                // MARK: ------ can return a cached response
                it("can return a cached response") {
                    var response: (info: ResponseInfoType, data: Int)?
                    
                    preparedRequest = HTTP.PreparedRequest<Int>.cached(
                        100,
                        endpoint: TestEndpoint.endpoint1
                    )
                    
                    preparedRequest
                        .send(using: dependencies)
                        .handleEvents(receiveOutput: { result in response = result })
                        .mapError { error.setting(to: $0) }
                        .sinkAndStore(in: &disposables)
                    
                    expect(response).toNot(beNil())
                    expect(response?.data).to(equal(100))
                    expect(error).to(beNil())
                }
                
                // MARK: ---- and handling events
                context("and handling events") {
                    @TestState var didReceiveSubscription: Bool! = false
                    @TestState var didReceiveCancel: Bool! = false
                    @TestState var receivedOutput: (ResponseInfoType, Int)? = nil
                    @TestState var receivedCompletion: Subscribers.Completion<Error>? = nil
                    @TestState var multiDidReceiveSubscription: [Bool]! = []
                    @TestState var multiReceivedCompletion: [Subscribers.Completion<Error>]! = []
                    
                    // MARK: ------ calls receiveSubscription correctly
                    it("calls receiveSubscription correctly") {
                        preparedRequest
                            .handleEvents(
                                receiveSubscription: { didReceiveSubscription = true }
                            )
                            .send(using: dependencies)
                            .sinkAndStore(in: &disposables)
                    
                        expect(didReceiveSubscription).to(beTrue())
                    }
                    
                    // MARK: ------ calls receiveOutput correctly
                    it("calls receiveOutput correctly") {
                        preparedRequest
                            .handleEvents(
                                receiveOutput: { info, output in receivedOutput = (info, output) }
                            )
                            .send(using: dependencies)
                            .sinkAndStore(in: &disposables)
                        
                        expect(receivedOutput).toNot(beNil())
                    }
                    
                    // MARK: ------ calls receiveCompletion correctly
                    it("calls receiveCompletion correctly") {
                        preparedRequest
                            .handleEvents(
                                receiveCompletion: { result in receivedCompletion = result }
                            )
                            .send(using: dependencies)
                            .sinkAndStore(in: &disposables)
                        
                        expect(receivedCompletion).toNot(beNil())
                    }
                    
                    // MARK: ------ calls receiveCancel correctly
                    it("calls receiveCancel correctly") {
                        preparedRequest
                            .handleEvents(
                                receiveCancel: { didReceiveCancel = true }
                            )
                            .send(using: dependencies)
                            .handleEvents(
                                receiveSubscription: { $0.cancel() }
                            )
                            .sinkAndStore(in: &disposables)
                        
                        expect(didReceiveCancel).to(beTrue())
                    }
                    
                    // MARK: ------ calls multiple callbacks without issue
                    it("calls multiple callbacks without issue") {
                        preparedRequest
                            .handleEvents(
                                receiveSubscription: { didReceiveSubscription = true },
                                receiveCompletion: { result in receivedCompletion = result }
                            )
                            .send(using: dependencies)
                            .sinkAndStore(in: &disposables)
                        
                        expect(didReceiveSubscription).to(beTrue())
                        expect(receivedCompletion).toNot(beNil())
                    }
                    
                    // MARK: ------ supports multiple handleEvents calls
                    it("supports multiple handleEvents calls") {
                        preparedRequest
                            .handleEvents(
                                receiveSubscription: { multiDidReceiveSubscription.append(true) },
                                receiveCompletion: { result in multiReceivedCompletion.append(result) }
                            )
                            .handleEvents(
                                receiveSubscription: { multiDidReceiveSubscription.append(true) },
                                receiveCompletion: { result in multiReceivedCompletion.append(result) }
                            )
                            .handleEvents(
                                receiveSubscription: { multiDidReceiveSubscription.append(true) },
                                receiveCompletion: { result in multiReceivedCompletion.append(result) }
                            )
                            .send(using: dependencies)
                            .sinkAndStore(in: &disposables)
                        
                        expect(multiDidReceiveSubscription).to(equal([true, true, true]))
                        expect(multiReceivedCompletion.count).to(equal(3))
                    }
                }

                // MARK: ---- and transforming the result
                context("and transforming the result") {
                    @TestState var receivedOutput: (ResponseInfoType, String)? = nil
                    @TestState var didReceiveSubscription: Bool! = false
                    @TestState var receivedCompletion: Subscribers.Completion<Error>? = nil
                    
                    // MARK: ------ successfully transforms the result
                    it("successfully transforms the result") {
                        preparedRequest
                            .map { _, output -> String in "\(output)" }
                            .send(using: dependencies)
                            .handleEvents(receiveOutput: { info, output in receivedOutput = (info, output) })
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(receivedOutput?.1).to(equal("1"))
                    }
                    
                    // MARK: ------ successfully transforms multiple times
                    it("successfully transforms multiple times") {
                        var result: TestType?
                        
                        preparedRequest
                            .map { _, output -> TestType in
                                TestType(intValue: output, stringValue: "Test", optionalStringValue: nil)
                            }
                            .map { _, output -> TestType in
                                TestType(
                                    intValue: output.intValue,
                                    stringValue: output.stringValue,
                                    optionalStringValue: "AnotherString"
                                )
                            }
                            .send(using: dependencies)
                            .handleEvents(receiveOutput: { _, output in result = output })
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(result?.intValue).to(equal(1))
                        expect(result?.stringValue).to(equal("Test"))
                        expect(result?.optionalStringValue).to(equal("AnotherString"))
                    }
                    
                    // MARK: ------ will fail if the transformation throws
                    it("will fail if the transformation throws") {
                        preparedRequest
                            .tryMap { _, output -> String in throw HTTPError.generic }
                            .send(using: dependencies)
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(error).to(matchError(HTTPError.generic))
                    }
                    
                    // MARK: ------ works with a cached response
                    it("works with a cached response") {
                        var response: (info: ResponseInfoType, data: String)?
                        
                        preparedRequest = HTTP.PreparedRequest<Int>.cached(
                            100,
                            endpoint: TestEndpoint.endpoint1
                        )
                        
                        preparedRequest
                            .map { _, output -> String in "\(output)" }
                            .send(using: dependencies)
                            .handleEvents(receiveOutput: { result in response = result })
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(response).toNot(beNil())
                        expect(response?.data).to(equal("100"))
                        expect(error).to(beNil())
                    }
                    
                    // MARK: ------ works with the event handling
                    it("works with the event handling") {
                        preparedRequest
                            .map { _, output -> String in "\(output)" }
                            .handleEvents(
                                receiveSubscription: { didReceiveSubscription = true },
                                receiveCompletion: { result in receivedCompletion = result }
                            )
                            .send(using: dependencies)
                            .sinkAndStore(in: &disposables)
                        
                        expect(didReceiveSubscription).to(beTrue())
                        expect(receivedCompletion).toNot(beNil())
                    }
                }
                
                // MARK: ---- a batch request
                context("a batch request") {
                    // MARK: ---- with a BatchResponseMap
                    context("with a BatchResponseMap") {
                        @TestState var subRequest1: Request<NoBody, TestEndpoint>! = Request<NoBody, TestEndpoint>(
                            method: .post,
                            server: "https://www.oxen.io",
                            endpoint: TestEndpoint.endpoint1,
                            x25519PublicKey: ""
                        )
                        @TestState var subRequest2: Request<NoBody, TestEndpoint>! = Request<NoBody, TestEndpoint>(
                            method: .post,
                            server: "https://www.oxen.io",
                            endpoint: TestEndpoint.endpoint2,
                            x25519PublicKey: ""
                        )
                        @TestState var preparedBatchRequest: HTTP.PreparedRequest<HTTP.BatchResponseMap<TestEndpoint>>! = {
                            let request = Request<HTTP.BatchRequest, TestEndpoint>(
                                method: .post,
                                server: "https://www.oxen.io",
                                endpoint: TestEndpoint.batch,
                                x25519PublicKey: "",
                                body: HTTP.BatchRequest(
                                    requests: [
                                        HTTP.PreparedRequest(
                                            request:  subRequest1,
                                            urlRequest: try! subRequest1.generateUrlRequest(using: dependencies),
                                            responseType: TestType.self,
                                            retryCount: 0,
                                            timeout: 10
                                        ),
                                        HTTP.PreparedRequest(
                                            request:  subRequest2,
                                            urlRequest: try! subRequest1.generateUrlRequest(using: dependencies),
                                            responseType: TestType.self,
                                            retryCount: 0,
                                            timeout: 10
                                        )
                                    ]
                                )
                            )
                            
                            return HTTP.PreparedRequest(
                                request: request,
                                urlRequest: try! request.generateUrlRequest(using: dependencies),
                                responseType: HTTP.BatchResponseMap<TestEndpoint>.self,
                                retryCount: 0,
                                timeout: 10
                            )
                        }()
                        @TestState var response: (info: ResponseInfoType, data: HTTP.BatchResponseMap<TestEndpoint>)?
                        @TestState var receivedOutput: (ResponseInfoType, String)? = nil
                        @TestState var didReceiveSubscription: Bool! = false
                        @TestState var receivedCompletion: Subscribers.Completion<Error>? = nil
                        
                        beforeEach {
                            mockNetwork
                                .when { $0.send(.selectedNetworkRequest(.any, to: .any, with: .any, using: .any)) }
                                .thenReturn(
                                    MockNetwork.batchResponseData(with: [
                                        (endpoint: TestEndpoint.endpoint1, data: TestType.mockBatchSubResponse()),
                                        (endpoint: TestEndpoint.endpoint2, data: TestType.mockBatchSubResponse())
                                    ])
                                )
                        }
                        
                        // MARK: ---- triggers sending correctly
                        it("triggers sending correctly") {
                            preparedBatchRequest
                                .send(using: dependencies)
                                .handleEvents(receiveOutput: { result in response = result })
                                .mapError { error.setting(to: $0) }
                                .sinkAndStore(in: &disposables)
                            
                            expect(response).toNot(beNil())
                            expect(response?.data.count).to(equal(2))
                            expect((response?.data.data[.endpoint1] as? HTTP.BatchSubResponse<TestType>)?.body)
                                .to(equal(TestType(intValue: 100, stringValue: "Test", optionalStringValue: nil)))
                            expect((response?.data.data[.endpoint2] as? HTTP.BatchSubResponse<TestType>)?.body)
                                .to(equal(TestType(intValue: 100, stringValue: "Test", optionalStringValue: nil)))
                            expect(error).to(beNil())
                        }
                        
                        // MARK: ------ works with transformations
                        it("works with transformations") {
                            preparedBatchRequest
                                .map { info, _ in receivedOutput = (info, "Test") }
                                .send(using: dependencies)
                                .sinkAndStore(in: &disposables)
                            
                            expect(receivedOutput?.1).to(equal("Test"))
                        }
                        
                        // MARK: ------ supports transformations on subrequests
                        it("supports transformations on subrequests") {
                            preparedBatchRequest = {
                                let request = Request<HTTP.BatchRequest, TestEndpoint>(
                                    method: .post,
                                    server: "https://www.oxen.io",
                                    endpoint: TestEndpoint.batch,
                                    x25519PublicKey: "",
                                    body: HTTP.BatchRequest(
                                        requests: [
                                            HTTP.PreparedRequest(
                                                request:  subRequest1,
                                                urlRequest: try! subRequest1.generateUrlRequest(using: dependencies),
                                                responseType: TestType.self,
                                                retryCount: 0,
                                                timeout: 10
                                            )
                                            .map { _, _ in "Test" },
                                            HTTP.PreparedRequest(
                                                request:  subRequest2,
                                                urlRequest: try! subRequest1.generateUrlRequest(using: dependencies),
                                                responseType: TestType.self,
                                                retryCount: 0,
                                                timeout: 10
                                            )
                                        ]
                                    )
                                )
                                
                                return HTTP.PreparedRequest(
                                    request: request,
                                    urlRequest: try! request.generateUrlRequest(using: dependencies),
                                    responseType: HTTP.BatchResponseMap<TestEndpoint>.self,
                                    retryCount: 0,
                                    timeout: 10
                                )
                            }()
                            
                            preparedBatchRequest
                                .send(using: dependencies)
                                .handleEvents(receiveOutput: { result in response = result })
                                .mapError { error.setting(to: $0) }
                                .sinkAndStore(in: &disposables)
                            
                            expect(response).toNot(beNil())
                            expect(response?.data.count).to(equal(2))
                            expect((response?.data.data[.endpoint1] as? HTTP.BatchSubResponse<String>)?.body)
                                .to(equal("Test"))
                            expect((response?.data.data[.endpoint2] as? HTTP.BatchSubResponse<TestType>)?.body)
                                .to(equal(TestType(intValue: 100, stringValue: "Test", optionalStringValue: nil)))
                            expect(error).to(beNil())
                        }
                        
                        // MARK: ------ works with the event handling
                        it("works with the event handling") {
                            preparedBatchRequest
                                .handleEvents(
                                    receiveSubscription: { didReceiveSubscription = true },
                                    receiveCompletion: { result in receivedCompletion = result }
                                )
                                .send(using: dependencies)
                                .sinkAndStore(in: &disposables)
                            
                            expect(didReceiveSubscription).to(beTrue())
                            expect(receivedCompletion).toNot(beNil())
                        }
                        
                        // MARK: ------ supports event handling on sub requests
                        it("supports event handling on sub requests") {
                            preparedBatchRequest = {
                                let request = Request<HTTP.BatchRequest, TestEndpoint>(
                                    method: .post,
                                    server: "https://www.oxen.io",
                                    endpoint: TestEndpoint.batch,
                                    x25519PublicKey: "",
                                    body: HTTP.BatchRequest(
                                        requests: [
                                            HTTP.PreparedRequest(
                                                request:  subRequest1,
                                                urlRequest: try! subRequest1.generateUrlRequest(using: dependencies),
                                                responseType: TestType.self,
                                                retryCount: 0,
                                                timeout: 10
                                            )
                                            .handleEvents(
                                                receiveCompletion: { result in receivedCompletion = result }
                                            ),
                                            HTTP.PreparedRequest(
                                                request:  subRequest2,
                                                urlRequest: try! subRequest1.generateUrlRequest(using: dependencies),
                                                responseType: TestType.self,
                                                retryCount: 0,
                                                timeout: 10
                                            )
                                        ]
                                    )
                                )
                                
                                return HTTP.PreparedRequest(
                                    request: request,
                                    urlRequest: try! request.generateUrlRequest(using: dependencies),
                                    responseType: HTTP.BatchResponseMap<TestEndpoint>.self,
                                    retryCount: 0,
                                    timeout: 10
                                )
                            }()
                            
                            preparedBatchRequest
                                .send(using: dependencies)
                                .sinkAndStore(in: &disposables)
                            
                            expect(receivedCompletion).toNot(beNil())
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Test Types

fileprivate enum TestEndpoint: EndpointType {
    case endpoint1
    case endpoint2
    case batch
    
    static var name: String { "TestEndpoint" }
    static var batchRequestVariant: HTTP.BatchRequest.Child.Variant { .storageServer }
    static var excludedSubRequestHeaders: [HTTPHeader] { [] }
    
    var path: String {
        switch self {
            case .endpoint1: return "endpoint1"
            case .endpoint2: return "endpoint2"
            case .batch: return "batch"
        }
    }
}

fileprivate struct TestType: Codable, Equatable, Mocked {
    static var mock: TestType { TestType(intValue: 100, stringValue: "Test", optionalStringValue: nil) }
    
    let intValue: Int
    let stringValue: String
    let optionalStringValue: String?
}