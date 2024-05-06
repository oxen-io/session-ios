// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension SnodeAPI {
    public class GetExpiriesRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case messageHashes = "messages"
        }
        
        /// Array of message hash strings (as provided by the storage server) to update. Messages can be from any namespace(s).
        /// You may pass a single message id of "all" to retrieve the timestamps of all
        let messageHashes: [String]
        
        override var verificationBytes: [UInt8] {
            /// Ed25519 signature of `("get_expiries" || timestamp || messages[0] || ... || messages[N])`
            /// where `timestamp` is expressed as a string (base10).  The signature must be base64 encoded (json) or bytes (bt).
            SnodeAPI.Endpoint.getExpiries.path.bytes
                .appending(contentsOf: timestampMs.map { "\($0)" }?.data(using: .ascii)?.bytes)
                .appending(contentsOf: messageHashes.joined().bytes)
        }
        
        // MARK: - Init
        
        public init(
            messageHashes: [String],
            authMethod: AuthenticationMethod,
            timestampMs: UInt64
        ) {
            self.messageHashes = messageHashes
            
            super.init(
                authMethod: authMethod,
                timestampMs: timestampMs
            )
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(messageHashes, forKey: .messageHashes)
            
            try super.encode(to: encoder)
        }
    }
}
