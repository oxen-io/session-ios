// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension SnodeAPI {
    public class RevokeSubkeyRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case subkeyToRevoke = "revoke_subkey"
        }
        
        let subkeyToRevoke: String
        
        override var verificationBytes: [UInt8] {
            /// Ed25519 signature of `("revoke_subkey" || subkey)`; this signs the subkey tag,
            /// using `pubkey` to sign. Must be base64 encoded for json requests; binary for OMQ requests.
            SnodeAPI.Endpoint.revokeSubaccount.path.bytes
                .appending(contentsOf: subkeyToRevoke.bytes)
        }
        
        // MARK: - Init
        
        public init(
            subkeyToRevoke: String,
            pubkey: String,
            ed25519PublicKey: [UInt8],
            ed25519SecretKey: [UInt8]
        ) {
            self.subkeyToRevoke = subkeyToRevoke
            
            super.init(
                pubkey: pubkey,
                ed25519PublicKey: ed25519PublicKey,
                ed25519SecretKey: ed25519SecretKey
            )
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(subkeyToRevoke, forKey: .subkeyToRevoke)
            
            try super.encode(to: encoder)
        }
    }
}
