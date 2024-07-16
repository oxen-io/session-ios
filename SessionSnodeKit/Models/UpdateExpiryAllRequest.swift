// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

extension SnodeAPI {
    public class UpdateExpiryAllRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case expiryMs = "expiry"
            case namespace
        }
        
        let expiryMs: UInt64
        
        /// The message namespace from which to change message expiries.  The request will update the expiry for
        /// all messages from the specific namespace, or from all namespaces when not provided
        ///
        /// **Note:** If omitted when sending the request, message expiries are updated from the default namespace
        /// only (namespace 0)
        let namespace: SnodeAPI.Namespace?
        
        override var verificationBytes: [UInt8] {
            /// Ed25519 signature of `("expire_all" || namespace || expiry)`, signed by `pubkey`.  Must be
            /// base64 encoded (json) or bytes (OMQ).  namespace should be the stringified namespace for
            /// non-default namespace expiries (i.e. "42", "-99", "all"), or an empty string for the default
            /// namespace (whether or not explicitly provided).
            SnodeAPI.Endpoint.expireAll.path.bytes
                .appending(
                    contentsOf: (namespace == nil ?
                        "all" :
                        namespace?.verificationString
                    )?.bytes
                )
                .appending(contentsOf: "\(expiryMs)".data(using: .ascii)?.bytes)
        }
        
        // MARK: - Init
        
        public init(
            expiryMs: UInt64,
            namespace: SnodeAPI.Namespace?,
            authMethod: AuthenticationMethod
        ) {
            self.expiryMs = expiryMs
            self.namespace = namespace
            
            super.init(authMethod: authMethod)
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(expiryMs, forKey: .expiryMs)
            
            // If no namespace is specified it defaults to the default namespace only (namespace
            // 0), so instead in this case we want to explicitly delete from `all` namespaces
            switch namespace {
                case .some(let namespace): try container.encode(namespace, forKey: .namespace)
                case .none: try container.encode("all", forKey: .namespace)
            }
            
            try super.encode(to: encoder)
        }
    }
}
