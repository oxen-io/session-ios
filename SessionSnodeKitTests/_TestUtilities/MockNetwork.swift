// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

@testable import SessionSnodeKit

// MARK: - MockNetwork

class MockNetwork: Mock<NetworkType>, NetworkType {
    var requestData: RequestData?
    
    func getSwarm(for swarmPublicKey: String) -> AnyPublisher<Set<LibSession.Snode>, Error> {
        return mock(args: [swarmPublicKey])
    }
    
    func getRandomNodes(count: Int) -> AnyPublisher<Set<LibSession.Snode>, Error> {
        return mock(args: [count])
    }
    
    func send(
        _ body: Data?,
        to destination: Network.Destination,
        requestTimeout: TimeInterval,
        requestAndPathBuildTimeout: TimeInterval?
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        requestData = RequestData(
            body: body,
            method: destination.method,
            pathAndParamsString: destination.urlPathAndParamsString,
            headers: destination.headers,
            x25519PublicKey: {
                switch destination {
                    case .server(let info), .serverUpload(let info, _), .serverDownload(let info): return info.x25519PublicKey
                    case .snode(_, let swarmPublicKey): return swarmPublicKey
                    case .randomSnode(let swarmPublicKey, _), .randomSnodeLatestNetworkTimeTarget(let swarmPublicKey, _, _):
                        return swarmPublicKey
                    
                    case .cached: return nil
                }
            }(),
            requestTimeout: requestTimeout,
            requestAndPathBuildTimeout: requestAndPathBuildTimeout
        )
        
        return mock(args: [body, destination, requestTimeout, requestAndPathBuildTimeout])
    }
    
    func checkClientVersion(ed25519SecretKey: [UInt8]) -> AnyPublisher<(ResponseInfoType, AppVersionResponse), Error> {
        return mock(args: [ed25519SecretKey])
    }
}

// MARK: - Test Convenience

extension MockNetwork {
    static func response<T: Encodable>(info: MockResponseInfo = .mock, with value: T) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return Just((info, try? JSONEncoder().with(outputFormatting: .sortedKeys).encode(value)))
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    static func response<T: Mocked & Encodable>(info: MockResponseInfo = .mock, type: T.Type) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return response(info: info, with: T.mock)
    }
    
    static func response<T: Mocked & Encodable>(info: MockResponseInfo = .mock, type: Array<T>.Type) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return response(info: info, with: [T.mock])
    }
    
    static func batchResponseData<E: EndpointType>(
        info: MockResponseInfo = .mock,
        with value: [(endpoint: E, data: Data)]
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        let data: Data = "[\(value.map { String(data: $0.data, encoding: .utf8)! }.joined(separator: ","))]"
            .data(using: .utf8)!
        
        return Just((info, data))
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    static func response(info: MockResponseInfo = .mock, data: Data) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return Just((info, data))
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    static func nullResponse(info: MockResponseInfo = .mock) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return Just((info, nil))
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    static func errorResponse() -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return Fail(error: TestError.mock).eraseToAnyPublisher()
    }
}

// MARK: - MockResponseInfo

struct MockResponseInfo: ResponseInfoType, Mocked {
    static let mock: MockResponseInfo = MockResponseInfo(requestData: .mock, code: 200, headers: [:])
    
    let requestData: RequestData
    let code: Int
    let headers: [String: String]
    
    init(requestData: RequestData, code: Int, headers: [String: String]) {
        self.requestData = requestData
        self.code = code
        self.headers = headers
    }
}

struct RequestData: Codable, Mocked {
    static let mock: RequestData = RequestData(
        body: nil,
        method: .get,
        pathAndParamsString: "",
        headers: [:],
        x25519PublicKey: nil,
        requestTimeout: 0,
        requestAndPathBuildTimeout: nil
    )
    
    let body: Data?
    let method: HTTPMethod
    let pathAndParamsString: String
    let headers: [HTTPHeader: String]
    let x25519PublicKey: String?
    let requestTimeout: TimeInterval
    let requestAndPathBuildTimeout: TimeInterval?
}

// MARK: - Network.BatchSubResponse Encoding Convenience

extension Encodable where Self: Codable {
    func batchSubResponse() -> Data {
        return try! JSONEncoder().with(outputFormatting: .sortedKeys).encode(
            Network.BatchSubResponse(
                code: 200,
                headers: [:],
                body: self,
                failedToParseBody: false
            )
        )
    }
}

extension Mocked where Self: Codable {
    static func mockBatchSubResponse() -> Data { return mock.batchSubResponse() }
}

extension Array where Element: Mocked, Element: Codable {
    static func mockBatchSubResponse() -> Data { return [Element.mock].batchSubResponse() }
}

// MARK: - Endpoint

enum MockEndpoint: EndpointType, Mocked {
    static var mockValue: MockEndpoint = .mock
    
    case mock
    
    static var name: String { "MockEndpoint" }
    static var batchRequestVariant: Network.BatchRequest.Child.Variant { .storageServer }
    static var excludedSubRequestHeaders: [HTTPHeader] { [] }
    
    var path: String { return "mock" }
}
