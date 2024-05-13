// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public protocol RequestTarget: Equatable {
    var url: URL? { get }
    var urlPathAndParamsString: String { get }
}

public protocol ServerRequestTarget: RequestTarget {
    associatedtype Endpoint: EndpointType
    
    var server: String { get }
    var endpoint: Endpoint { get }
    var x25519PublicKey: String { get }
}

public extension ServerRequestTarget {
    func pathFor<E: EndpointType>(endpoint: E, queryParams: [HTTPQueryParam: String]) -> String {
        return [
            "/\(endpoint.path)",
            queryParams
                .map { key, value in "\(key)=\(value)" }
                .joined(separator: "&")
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: "?")
    }
}

// MARK: - ServerTarget

public extension Network {
    struct ServerTarget<E: EndpointType>: ServerRequestTarget {
        public typealias Endpoint = E
        
        public let server: String
        public let endpoint: Endpoint
        let queryParameters: [HTTPQueryParam: String]
        public let x25519PublicKey: String
        
        public var url: URL? { URL(string: "\(server)\(urlPathAndParamsString)") }
        public var urlPathAndParamsString: String { pathFor(endpoint: endpoint, queryParams: queryParameters) }
        
        // MARK: - Initialization
        
        public init(
            server: String,
            endpoint: E,
            queryParameters: [HTTPQueryParam: String],
            x25519PublicKey: String
        ) {
            self.server = server
            self.endpoint = endpoint
            self.queryParameters = queryParameters
            self.x25519PublicKey = x25519PublicKey
        }
    }
}

// MARK: Request - ServerTarget

public extension Request {
    init(
        method: HTTPMethod = .get,
        server: String,
        endpoint: Endpoint,
        queryParameters: [HTTPQueryParam: String] = [:],
        headers: [HTTPHeader: String] = [:],
        x25519PublicKey: String,
        body: T? = nil
    ) {
        self = Request(
            method: method,
            endpoint: endpoint,
            target: Network.ServerTarget(
                server: server,
                endpoint: endpoint,
                queryParameters: queryParameters,
                x25519PublicKey: x25519PublicKey
            ),
            headers: headers,
            body: body
        )
    }
}
