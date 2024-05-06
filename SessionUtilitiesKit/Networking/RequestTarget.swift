// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public protocol RequestTarget: Equatable {
    var url: URL? { get }
    var urlPathAndParamsString: String { get }
}

public protocol ServerRequestTarget: RequestTarget {
    var server: String { get }
    var x25519PublicKey: String { get }
}

public extension ServerRequestTarget {
    func pathFor(path: String, queryParams: [HTTPQueryParam: String]) -> String {
        return [
            "/\(path)",
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

public extension HTTP {
    struct ServerTarget: ServerRequestTarget {
        public let server: String
        let path: String
        let queryParameters: [HTTPQueryParam: String]
        public let x25519PublicKey: String
        
        public var url: URL? { URL(string: "\(server)\(urlPathAndParamsString)") }
        public var urlPathAndParamsString: String { pathFor(path: path, queryParams: queryParameters) }
        
        // MARK: - Initialization
        
        public init(
            server: String,
            path: String,
            queryParameters: [HTTPQueryParam: String],
            x25519PublicKey: String
        ) {
            self.server = server
            self.path = path
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
            target: HTTP.ServerTarget(
                server: server,
                path: endpoint.path,
                queryParameters: queryParameters,
                x25519PublicKey: x25519PublicKey
            ),
            headers: headers,
            body: body
        )
    }
}
