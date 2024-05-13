// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Network {
    struct RequestInfo: Codable {
        let method: String
        let endpoint: String
        let headers: [String: String]
        
        public init(
            method: String,
            endpoint: String,
            headers: [String: String]
        ) {
            self.method = method
            self.endpoint = endpoint
            self.headers = headers
        }
    }
}
