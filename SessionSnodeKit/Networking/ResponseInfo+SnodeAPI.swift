// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension SnodeAPI {
    struct LatestTimestampResponseInfo: ResponseInfoType {
        public let code: Int
        public let headers: [String: String]
        public let timestampMs: UInt64
        
        public init(code: Int, headers: [String: String], timestampMs: UInt64) {
            self.code = code
            self.headers = headers
            self.timestampMs = timestampMs
        }
    }
}
