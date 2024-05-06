// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

// MARK: - OpenGroupAPITarget

internal extension HTTP {
    struct OpenGroupAPITarget: ServerRequestTarget {
        public let server: String
        let path: String
        let queryParameters: [HTTPQueryParam: String]
        public let serverPublicKey: String
        public let forceBlinded: Bool
        
        public var url: URL? { URL(string: "\(server)\(urlPathAndParamsString)") }
        public var urlPathAndParamsString: String { pathFor(path: path, queryParams: queryParameters) }
        public var x25519PublicKey: String { serverPublicKey }
    }
}

// MARK: Request - OpenGroupAPITarget

public extension Request {
    init(
        _ db: Database,
        method: HTTPMethod = .get,
        server: String,
        endpoint: Endpoint,
        queryParameters: [HTTPQueryParam: String] = [:],
        headers: [HTTPHeader: String] = [:],
        body: T? = nil,
        forceBlinded: Bool = false
    ) throws {
        let maybePublicKey: String? = try? OpenGroup
            .select(.publicKey)
            .filter(OpenGroup.Columns.server == server.lowercased())
            .asRequest(of: String.self)
            .fetchOne(db)

        guard let publicKey: String = maybePublicKey else { throw OpenGroupAPIError.noPublicKey }
        
        self = Request(
            method: method,
            endpoint: endpoint,
            target: HTTP.OpenGroupAPITarget(
                server: server,
                path: endpoint.path,
                queryParameters: queryParameters,
                serverPublicKey: publicKey,
                forceBlinded: forceBlinded
            ),
            headers: headers,
            body: body
        )
    }
}
