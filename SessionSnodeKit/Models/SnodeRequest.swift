// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public struct SnodeRequest<T: Encodable>: Encodable {
    private enum CodingKeys: String, CodingKey {
        case method
        case body = "params"
    }
    
    internal let endpoint: SnodeAPI.Endpoint
    internal let body: T
    
    // MARK: - Initialization
    
    public init(
        endpoint: SnodeAPI.Endpoint,
        body: T
    ) {
        self.endpoint = endpoint
        self.body = body
    }
    
    // MARK: - Codable
    
    public func encode(to encoder: Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(endpoint.path, forKey: .method)
        try container.encode(body, forKey: .body)
    }
}

// MARK: - BatchRequestChildRetrievable

extension SnodeRequest: BatchRequestChildRetrievable where T: BatchRequestChildRetrievable {
    public var requests: [Network.BatchRequest.Child] { body.requests }
}

// MARK: - UpdatableTimestamp

extension SnodeRequest: UpdatableTimestamp where T: UpdatableTimestamp {
    public func with(timestampMs: UInt64) -> SnodeRequest<T> {
        return SnodeRequest(
            endpoint: self.endpoint,
            body: self.body.with(timestampMs: timestampMs)
        )
    }
}
