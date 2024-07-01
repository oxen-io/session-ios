// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

extension SnodeAPI {
    public final class DeleteAllBeforeRequest: SnodeAuthenticatedRequestBody, UpdatableTimestamp {
        enum CodingKeys: String, CodingKey {
            case beforeMs = "before"
            case namespace
        }
        
        let beforeMs: UInt64
        let namespace: SnodeAPI.Namespace?
        
        override var verificationBytes: [UInt8] {
            /// Ed25519 signature of `("delete_before" || namespace || before)`, signed by
            /// `pubkey`.  Must be base64 encoded (json) or bytes (OMQ).  `namespace` is the stringified
            /// version of the given non-default namespace parameter (i.e. "-42" or "all"), or the empty
            /// string for the default namespace (whether explicitly given or not).
            SnodeAPI.Endpoint.deleteAllBefore.path.bytes
                .appending(
                    contentsOf: (namespace == nil ?
                        "all" :
                        namespace?.verificationString
                    )?.bytes
                )
                .appending(contentsOf: "\(beforeMs)".data(using: .ascii)?.bytes)
        }
        
        // MARK: - Init
        
        public init(
            beforeMs: UInt64,
            namespace: SnodeAPI.Namespace?,
            pubkey: String,
            timestampMs: UInt64,
            ed25519PublicKey: [UInt8],
            ed25519SecretKey: [UInt8]
        ) {
            self.beforeMs = beforeMs
            self.namespace = namespace
            
            super.init(
                pubkey: pubkey,
                ed25519PublicKey: ed25519PublicKey,
                ed25519SecretKey: ed25519SecretKey,
                timestampMs: timestampMs
            )
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(beforeMs, forKey: .beforeMs)
            
            // If no namespace is specified it defaults to the default namespace only (namespace
            // 0), so instead in this case we want to explicitly delete from `all` namespaces
            switch namespace {
                case .some(let namespace): try container.encode(namespace, forKey: .namespace)
                case .none: try container.encode("all", forKey: .namespace)
            }
            
            try super.encode(to: encoder)
        }
        
        // MARK: - UpdatableTimestamp
        
        public func with(timestampMs: UInt64) -> DeleteAllBeforeRequest {
            return DeleteAllBeforeRequest(
                beforeMs: self.beforeMs,
                namespace: self.namespace,
                pubkey: self.pubkey,
                timestampMs: timestampMs,
                ed25519PublicKey: self.ed25519PublicKey,
                ed25519SecretKey: self.ed25519SecretKey
            )
        }
    }
}
