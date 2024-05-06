// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension SnodeAPI {
    public class SendMessageRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case namespace
        }
        
        let message: SnodeMessage
        let namespace: SnodeAPI.Namespace
        
        override var verificationBytes: [UInt8] {
            /// Ed25519 signature of `("store" || namespace || timestamp)`, where namespace and
            /// `timestamp` are the base10 expression of the namespace and `timestamp` values.  Must be
            /// base64 encoded for json requests; binary for OMQ requests.  For non-05 type pubkeys (i.e. non
            /// session ids) the signature will be verified using `pubkey`.  For 05 pubkeys, see the following
            /// option.
            SnodeAPI.Endpoint.sendMessage.path.bytes
                .appending(contentsOf: namespace.verificationString.bytes)
                .appending(contentsOf: timestampMs.map { "\($0)" }?.data(using: .ascii)?.bytes)
        }
        
        // MARK: - Init
        
        public init(
            message: SnodeMessage,
            namespace: SnodeAPI.Namespace,
            authMethod: AuthenticationMethod,
            timestampMs: UInt64
        ) {
            self.message = message
            self.namespace = namespace
            
            super.init(
                authMethod: authMethod,
                timestampMs: timestampMs
            )
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            /// **Note:** We **MUST** do the `message.encode` before we call `super.encode` because otherwise
            /// it will override the `timestampMs` value with the value in the message which is incorrect - we actually want the
            /// `timestampMs` value at the time the request was made so that older messages stuck in the job queue don't
            /// end up failing due to being outside the approved timestamp window (clients use the timestamp within the message
            /// data rather than this one anyway)
            try message.encode(to: encoder)
            try container.encode(namespace, forKey: .namespace)
            
            try super.encode(to: encoder)
        }
    }
}
