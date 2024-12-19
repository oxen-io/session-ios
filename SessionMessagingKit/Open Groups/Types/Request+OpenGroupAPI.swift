// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: Request - OpenGroupAPI

public extension Request where Endpoint == OpenGroupAPI.Endpoint {
    init(
        _ db: Database,
        method: HTTPMethod = .get,
        server: String,
        endpoint: Endpoint,
        queryParameters: [HTTPQueryParam: String] = [:],
        headers: [HTTPHeader: String] = [:],
        body: T? = nil
    ) throws {
        let maybePublicKey: String? = try? OpenGroup
            .select(.publicKey)
            .filter(OpenGroup.Columns.server == server.lowercased())
            .asRequest(of: String.self)
            .fetchOne(db)

        guard let publicKey: String = maybePublicKey else { throw OpenGroupAPIError.noPublicKey }
        
        self = try Request(
            endpoint: endpoint,
            destination: try .server(
                method: method,
                server: server,
                queryParameters: queryParameters,
                headers: headers,
                x25519PublicKey: publicKey
            ),
            body: body
        )
    }
}
