// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionUtilitiesKit

public extension Network.RequestType {
    /// Sends an onion request to `snode`. Builds new paths as needed.
    static func directRequest(
        _ payload: Data,
        to snode: Snode,
        timeout: TimeInterval = HTTP.defaultTimeout
    ) -> Network.RequestType<Data?> {
        return Network.RequestType(
            id: "directRequest",
            url: snode.address,
            method: "POST",
            body: payload,
            args: [payload, snode, timeout]
        ) {
            DirectRequestAPI.sendRequest(
                method: .post,
                headers: [:],
                endpoint: "storage_rpc/v1",
                body: payload,
                destination: OnionRequestAPIDestination.snode(snode),
                timeout: timeout
            )
        }
    }
    
    /// Sends an onion request to `server`. Builds new paths as needed.
    static func directRequest(
        _ request: URLRequest,
        to server: String,
        with x25519PublicKey: String,
        timeout: TimeInterval = HTTP.defaultTimeout
    ) -> Network.RequestType<Data?> {
        return Network.RequestType(
            id: "directRequest",
            args: [request, server, x25519PublicKey, timeout]
        ) {
            guard let url = request.url, let host = request.url?.host else {
                return Fail(error: HTTPError.invalidURL).eraseToAnyPublisher()
            }
            
            var endpoint = url.path.removingPrefix("/")
            if let query = url.query { endpoint += "?\(query)" }
            let scheme = url.scheme
            let port = url.port.map { UInt16($0) }
            let headers: [String: String] = (request.allHTTPHeaderFields ?? [:])
                .setting(
                    "Content-Type",
                    (request.httpBody == nil ? nil :
                        // Default to JSON if not defined
                        ((request.allHTTPHeaderFields ?? [:])["Content-Type"] ?? "application/json")
                    )
                )
                .removingValue(forKey: "User-Agent")
            
            return DirectRequestAPI.sendRequest(
                method: (request.httpMethod.map { HTTPMethod(rawValue: $0) } ?? .get),   // The default (if nil) is 'GET'
                headers: headers,
                endpoint: endpoint,
                body: request.httpBody,
                destination: OnionRequestAPIDestination.server(
                    host: host,
                    target: OnionRequestAPIVersion.v4.rawValue,
                    x25519PublicKey: x25519PublicKey,
                    scheme: scheme,
                    port: port
                ),
                timeout: timeout
            )
        }
    }
}

public enum DirectRequestAPI {
    fileprivate static func sendRequest(
        method: HTTPMethod,
        headers: [String: String] = [:],
        endpoint: String,
        body: Data?,
        destination: OnionRequestAPIDestination,
        timeout: TimeInterval = HTTP.defaultTimeout
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        let maybeFinalUrlString: String? = {
            switch destination {
                case .server(let host, _, _, let scheme, _):
                    return "\(scheme ?? "https")://\(host)/\(endpoint)"
                    
                case .snode(let snode):
                    return "\(snode.address):\(snode.port)/\(endpoint)"
            }
        }()
        
        // Ensure we have the final URL
        guard let finalUrlString: String = maybeFinalUrlString else {
            return Fail(error: HTTPError.invalidURL).eraseToAnyPublisher()
        }
        
        return HTTP
            .execute(method, finalUrlString, headers: headers, body: body, timeout: timeout)
            .map { data in (HTTP.ResponseInfo(code: 0, headers: [:]), data) }
            .eraseToAnyPublisher()
    }
}
