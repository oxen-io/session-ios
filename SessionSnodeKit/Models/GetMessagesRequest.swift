// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension SnodeAPI {
    public class GetMessagesRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case lastHash = "last_hash"
            case namespace
            case maxCount = "max_count"
            case maxSize = "max_size"
        }
        
        let lastHash: String
        let namespace: SnodeAPI.Namespace?
        let maxCount: Int64?
        let maxSize: Int64?
        
        override var verificationBytes: [UInt8] {
            /// Ed25519 signature of `("retrieve" || namespace || timestamp)` (if using a non-0
            /// namespace), or `("retrieve" || timestamp)` when fetching from the default namespace.  Both
            /// namespace and timestamp are the base10 expressions of the relevant values.  Must be base64
            /// encoded for json requests; binary for OMQ requests.
            SnodeAPI.Endpoint.getMessages.path.bytes
                .appending(contentsOf: namespace?.verificationString.bytes)
                .appending(contentsOf: timestampMs.map { "\($0)" }?.data(using: .ascii)?.bytes)
        }
        
        // MARK: - Init
        
        public init(
            lastHash: String,
            namespace: SnodeAPI.Namespace?,
            authMethod: AuthenticationMethod,
            timestampMs: UInt64,
            maxCount: Int64? = nil,
            maxSize: Int64? = nil
        ) {
            self.lastHash = lastHash
            self.namespace = namespace
            self.maxCount = maxCount
            self.maxSize = maxSize
            
            super.init(
                authMethod: authMethod,
                timestampMs: timestampMs
            )
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(lastHash, forKey: .lastHash)
            try container.encodeIfPresent(namespace, forKey: .namespace)
            try container.encodeIfPresent(maxCount, forKey: .maxCount)
            try container.encodeIfPresent(maxSize, forKey: .maxSize)
            
            try super.encode(to: encoder)
        }
    }
}
