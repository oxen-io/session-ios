// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

// MARK: - SnodeTarget

internal extension HTTP {
    struct SnodeTarget: RequestTarget, Equatable {
        let snode: Snode
        
        var url: URL? { URL(string: "snode:\(snode.x25519PublicKey)") }
        var urlPathAndParamsString: String { return "" }
    }
}

// MARK: - RandomSnodeTarget

internal extension HTTP {
    struct RandomSnodeTarget: RequestTarget, Equatable {
        let publicKey: String
        
        var url: URL? { URL(string: "snode:\(publicKey)") }
        var urlPathAndParamsString: String { return "" }
    }
}

// MARK: - RandomSnodeLatestNetworkTimeTarget

internal extension HTTP {
    struct RandomSnodeLatestNetworkTimeTarget: RequestTarget, Equatable {
        let publicKey: String
        let urlRequestWithUpdatedTimestampMs: ((UInt64, Dependencies) throws -> URLRequest)
        
        var url: URL? { URL(string: "snode:\(publicKey)") }
        var urlPathAndParamsString: String { return "" }
        
        static func == (lhs: HTTP.RandomSnodeLatestNetworkTimeTarget, rhs: HTTP.RandomSnodeLatestNetworkTimeTarget) -> Bool {
            lhs.publicKey == rhs.publicKey
        }
    }
}

// MARK: Request - SnodeTarget

public extension Request {
    init(
        method: HTTPMethod = .get,
        endpoint: Endpoint,
        snode: Snode,
        headers: [HTTPHeader: String] = [:],
        body: T? = nil
    ) {
        self = Request(
            method: method,
            endpoint: endpoint,
            target: HTTP.SnodeTarget(
                snode: snode
            ),
            headers: headers,
            body: body
        )
    }
}

// MARK: Request - RandomSnodeTarget

public extension Request {
    init(
        method: HTTPMethod = .get,
        endpoint: Endpoint,
        publicKey: String,
        headers: [HTTPHeader: String] = [:],
        body: T? = nil
    ) {
        self = Request(
            method: method,
            endpoint: endpoint,
            target: HTTP.RandomSnodeTarget(
                publicKey: publicKey
            ),
            headers: headers,
            body: body
        )
    }
}

// MARK: Request - RandomSnodeLatestNetworkTimeTarget
    
public extension Request {
    init(
        method: HTTPMethod = .get,
        endpoint: Endpoint,
        publicKey: String,
        headers: [HTTPHeader: String] = [:],
        requiresLatestNetworkTime: Bool,
        body: T? = nil
    ) where T: UpdatableTimestamp {
        self = Request(
            method: method,
            endpoint: endpoint,
            target: HTTP.RandomSnodeLatestNetworkTimeTarget(
                publicKey: publicKey,
                urlRequestWithUpdatedTimestampMs: { timestampMs, dependencies in
                    try Request(
                        method: method,
                        endpoint: endpoint,
                        publicKey: publicKey,
                        headers: headers,
                        body: body?.with(timestampMs: timestampMs)
                    ).generateUrlRequest(using: dependencies)
                }
            ),
            headers: headers,
            body: body
        )
    }
}
