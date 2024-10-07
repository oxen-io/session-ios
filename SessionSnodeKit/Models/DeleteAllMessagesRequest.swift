// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension SnodeAPI {
    public final class DeleteAllMessagesRequest: SnodeAuthenticatedRequestBody, UpdatableTimestamp {
        enum CodingKeys: String, CodingKey {
            case namespace
        }
        
        /// The message namespace from which to delete messages.  The request will delete all messages
        /// from the specific namespace, or from all namespaces when not provided
        ///
        /// **Note:** If omitted when sending the request, messages are deleted from the default namespace
        /// only (namespace 0)
        let namespace: SnodeAPI.Namespace
        
        override var verificationBytes: [UInt8] {
            /// Ed25519 signature of `( "delete_all" || namespace || timestamp )`, where
            /// `namespace` is the empty string for the default namespace (whether explicitly specified or
            /// not), and otherwise the stringified version of the namespace parameter (i.e. "99" or "-42" or "all").
            /// The signature must be signed by the ed25519 pubkey in `pubkey` (omitting the leading prefix).
            /// Must be base64 encoded for json requests; binary for OMQ requests.
            SnodeAPI.Endpoint.deleteAll.path.bytes
                .appending(contentsOf: namespace.verificationString.bytes)
                .appending(contentsOf: timestampMs.map { "\($0)" }?.data(using: .ascii)?.bytes)
        }
        
        // MARK: - Init
        
        public init(
            namespace: SnodeAPI.Namespace,
            authMethod: AuthenticationMethod,
            timestampMs: UInt64
        ) {
            self.namespace = namespace
            
            super.init(
                authMethod: authMethod,
                timestampMs: timestampMs
            )
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            // The 'all' namespace should be sent through as `all` instead of a numerical value
            switch namespace {
                case .all: try container.encode(namespace.verificationString, forKey: .namespace)
                default: try container.encode(namespace, forKey: .namespace)
            }
            
            try super.encode(to: encoder)
        }
        
        // MARK: - UpdatableTimestamp
        
        public func with(timestampMs: UInt64) -> DeleteAllMessagesRequest {
            return DeleteAllMessagesRequest(
                namespace: self.namespace,
                authMethod: self.authMethod,
                timestampMs: timestampMs
            )
        }
    }
}
