// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionUtilitiesKit

public extension Network.RequestType {
    static func onionRequest(
        _ payload: Data,
        to snode: LibSession.Snode,
        swarmPublicKey: String?,
        timeout: TimeInterval = Network.defaultTimeout
    ) -> Network.RequestType<Data?> {
        return Network.RequestType(
            id: "onionRequest",
            url: "quic://\(snode.address)",
            method: "POST",
            body: payload,
            args: [payload, snode, swarmPublicKey, timeout]
        ) { dependencies in
            LibSession.sendOnionRequest(
                to: OnionRequestAPIDestination.snode(snode),
                body: payload,
                swarmPublicKey: swarmPublicKey,
                timeout: timeout,
                using: dependencies
            )
        }
    }
    
    static func onionRequest(
        _ request: URLRequest,
        to server: String,
        with x25519PublicKey: String,
        timeout: TimeInterval = Network.defaultTimeout
    ) -> Network.RequestType<Data?> {
        return Network.RequestType(
            id: "onionRequest",
            url: request.url?.absoluteString,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields,
            body: request.httpBody,
            args: [request, server, x25519PublicKey, timeout]
        ) { dependencies in
            guard let url = request.url, let host = request.url?.host else {
                return Fail(error: NetworkError.invalidURL).eraseToAnyPublisher()
            }
            
            return LibSession.sendOnionRequest(
                to: OnionRequestAPIDestination.server(
                    method: request.httpMethod,
                    scheme: url.scheme,
                    host: host,
                    endpoint: url.path,
                    port: url.port.map { UInt16($0) },
                    headers: request.allHTTPHeaderFields,
                    x25519PublicKey: x25519PublicKey
                ),
                body: request.httpBody,
                swarmPublicKey: nil,
                timeout: timeout,
                using: dependencies
            )
        }
    }
}
