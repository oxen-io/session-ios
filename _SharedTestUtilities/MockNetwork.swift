// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

// MARK: - MockNetwork

class MockNetwork: Mock<NetworkType>, NetworkType {
    var requestData: RequestData?
    
    func send<T>(_ request: Network.RequestType<T>, using dependencies: Dependencies) -> AnyPublisher<(ResponseInfoType, T), Error> {
        requestData = request.data
        
        return accept(funcName: "send<T>(\(request.id))", args: request.args) as! AnyPublisher<(ResponseInfoType, T), Error>
    }
    
    static func response<T: Encodable>(info: MockResponseInfo = .mockValue, with value: T) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return Just((info, try? JSONEncoder().with(outputFormatting: .sortedKeys).encode(value)))
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    static func response<T: Mocked & Encodable>(info: MockResponseInfo = .mockValue, type: T.Type) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return response(info: info, with: T.mockValue)
    }
    
    static func response<T: Mocked & Encodable>(info: MockResponseInfo = .mockValue, type: Array<T>.Type) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return response(info: info, with: [T.mockValue])
    }
    
    static func batchResponseData<E: EndpointType>(
        info: MockResponseInfo = .mockValue,
        with value: [(endpoint: E, data: Data)]
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        let data: Data = "[\(value.map { String(data: $0.data, encoding: .utf8)! }.joined(separator: ","))]"
            .data(using: .utf8)!
        
        return Just((info, data))
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    static func response(info: MockResponseInfo = .mockValue, data: Data) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return Just((info, data))
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    static func nullResponse(info: MockResponseInfo = .mockValue) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return Just((info, nil))
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
}

// MARK: - MockResponseInfo

struct MockResponseInfo: ResponseInfoType, Mocked {
    static let mockValue: MockResponseInfo = MockResponseInfo(requestData: .fallbackData, code: 200, headers: [:])
    
    let requestData: RequestData
    let code: Int
    let headers: [String: String]
    
    init(requestData: RequestData, code: Int, headers: [String: String]) {
        self.requestData = requestData
        self.code = code
        self.headers = headers
    }
}

struct RequestData: Codable {
    static let fallbackData: RequestData = RequestData(urlString: nil, httpMethod: "GET", headers: [:], body: nil)
    
    let urlString: String?
    let httpMethod: String
    let headers: [String: String]
    let body: Data?
}

extension Network.RequestType {
    var data: RequestData {
        return RequestData(
            urlString: url,
            httpMethod: (method ?? ""),
            headers: (headers ?? [:]),
            body: body
        )
    }
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
    static func mockBatchSubResponse() -> Data { return mockValue.batchSubResponse() }
}

extension Array where Element: Mocked, Element: Codable {
    static func mockBatchSubResponse() -> Data { return [Element.mockValue].batchSubResponse() }
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
