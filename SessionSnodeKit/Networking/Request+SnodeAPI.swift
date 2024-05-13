// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

// MARK: - SnodeTarget

internal extension Network {
    struct SnodeTarget: RequestTarget, Equatable {
        let snode: LibSession.Snode
        let swarmPublicKey: String?
        
        var url: URL? { URL(string: "snode:\(snode.address)") }
        var urlPathAndParamsString: String { return "" }
    }
}

// MARK: - RandomSnodeTarget

internal extension Network {
    struct RandomSnodeTarget: RequestTarget, Equatable {
        let swarmPublicKey: String
        let retryCount: Int
        
        var url: URL? { URL(string: "snode:\(swarmPublicKey)") }
        var urlPathAndParamsString: String { return "" }
    }
}

// MARK: - RandomSnodeLatestNetworkTimeTarget

internal extension Network {
    struct RandomSnodeLatestNetworkTimeTarget: RequestTarget, Equatable {
        let swarmPublicKey: String
        let retryCount: Int
        let urlRequestWithUpdatedTimestampMs: ((UInt64, Dependencies) throws -> URLRequest)
        
        var url: URL? { URL(string: "snode:\(swarmPublicKey)") }
        var urlPathAndParamsString: String { return "" }
        
        static func == (lhs: Network.RandomSnodeLatestNetworkTimeTarget, rhs: Network.RandomSnodeLatestNetworkTimeTarget) -> Bool {
            lhs.swarmPublicKey == rhs.swarmPublicKey && lhs.retryCount == rhs.retryCount
        }
    }
}

// MARK: Request - SnodeTarget

public extension Request {
    init(
        method: HTTPMethod = .get,
        endpoint: Endpoint,
        snode: LibSession.Snode,
        headers: [HTTPHeader: String] = [:],
        body: T? = nil,
        swarmPublicKey: String?,
        retryCount: Int
    ) {
        self = Request(
            method: method,
            endpoint: endpoint,
            target: Network.SnodeTarget(
                snode: snode,
                swarmPublicKey: swarmPublicKey
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
        swarmPublicKey: String,
        headers: [HTTPHeader: String] = [:],
        body: T? = nil,
        retryCount: Int
    ) {
        self = Request(
            method: method,
            endpoint: endpoint,
            target: Network.RandomSnodeTarget(
                swarmPublicKey: swarmPublicKey,
                retryCount: retryCount
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
        swarmPublicKey: String,
        headers: [HTTPHeader: String] = [:],
        requiresLatestNetworkTime: Bool,
        body: T? = nil,
        retryCount: Int
    ) where T: UpdatableTimestamp {
        self = Request(
            method: method,
            endpoint: endpoint,
            target: Network.RandomSnodeLatestNetworkTimeTarget(
                swarmPublicKey: swarmPublicKey,
                retryCount: retryCount,
                urlRequestWithUpdatedTimestampMs: { timestampMs, dependencies in
                    try Request(
                        method: method,
                        endpoint: endpoint,
                        swarmPublicKey: swarmPublicKey,
                        headers: headers,
                        body: body?.with(timestampMs: timestampMs),
                        retryCount: retryCount
                    ).generateUrlRequest(using: dependencies)
                }
            ),
            headers: headers,
            body: body
        )
    }
}
