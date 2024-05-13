// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension SnodeAPI {
    public class RevokeSubkeyRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case subkeyToRevoke = "revoke_subkey"
        }
        
        let subkeyToRevoke: String
        
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
        
        // MARK: - Abstract Methods
        
        override func generateSignature() throws -> [UInt8] {
            /// Ed25519 signature of `("revoke_subkey" || subkey)`; this signs the subkey tag,
            /// using `pubkey` to sign. Must be base64 encoded for json requests; binary for OMQ requests.
            let verificationBytes: [UInt8] = SnodeAPI.Endpoint.revokeSubaccount.path.bytes
                .appending(contentsOf: subkeyToRevoke.bytes)
            
            guard
                let signatureBytes: [UInt8] = sodium.wrappedValue.sign.signature(
                    message: verificationBytes,
                    secretKey: ed25519SecretKey
                )
            else {
                throw SnodeAPIError.signingFailed
            }
            
            return signatureBytes
        }
    }
}
