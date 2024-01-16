// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

// MARK: Request - PushNotificationAPI

public extension Request where Endpoint == PushNotificationAPI.Endpoint {
    init(
        method: HTTPMethod = .get,
        endpoint: Endpoint,
        queryParameters: [HTTPQueryParam: String] = [:],
        headers: [HTTPHeader: String] = [:],
        body: T? = nil,
        using dependencies: Dependencies
    ) {
        self = Request(
            method: method,
            endpoint: endpoint,
            target: HTTP.ServerTarget(
                server: endpoint.server(using: dependencies),
                path: endpoint.path,
                queryParameters: queryParameters,
                x25519PublicKey: endpoint.serverPublicKey
            ),
            headers: headers,
            body: body
        )
    }
}
