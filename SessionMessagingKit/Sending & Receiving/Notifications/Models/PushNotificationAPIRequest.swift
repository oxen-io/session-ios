// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public struct PushNotificationAPIRequest<T: Encodable>: Encodable {
    private enum CodingKeys: String, CodingKey {
        case method
        case body = "params"
    }
    
    internal let endpoint: PushNotificationAPI.Endpoint
    internal let body: T
    
    // MARK: - Initialization
    
    public init(
        endpoint: PushNotificationAPI.Endpoint,
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
