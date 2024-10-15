// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension PushNotificationAPI {
    public class AuthenticatedRequest: Encodable {
        private enum CodingKeys: String, CodingKey {
            case pubkey
            case subaccount
            case timestamp = "sig_ts"
            case ed25519PublicKey = "session_ed25519"
            case signatureBase64 = "signature"
            case subaccountSignatureBase64 = "subaccount_sig"
        }
        
        /// The authentication method used for this request
        internal let authMethod: AuthenticationMethod
        
        /// The signature unix timestamp (seconds, not ms)
        internal let timestamp: Int64
        
        var verificationBytes: [UInt8] { preconditionFailure("abstract class - override in subclass") }
        
        // MARK: - Initialization
        
        public init(
            authMethod: AuthenticationMethod,
            timestamp: Int64
        ) {
            self.authMethod = authMethod
            self.timestamp = timestamp
        }
        
        // MARK: - Codable
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            // Generate the signature for the request for encoding
            let signature: Authentication.Signature = try authMethod.generateSignature(
                with: verificationBytes,
                using: try encoder.dependencies ?? { throw DependenciesError.missingDependencies }()
            )
            try container.encode(timestamp, forKey: .timestamp)
            
            switch authMethod.info {
                case .standard(let sessionId, let ed25519KeyPair):
                    try container.encode(sessionId.hexString, forKey: .pubkey)
                    try container.encode(ed25519KeyPair.publicKey.toHexString(), forKey: .ed25519PublicKey)
                    
                case .groupAdmin(let sessionId, _):
                    try container.encode(sessionId.hexString, forKey: .pubkey)
                    
                case .groupMember(let sessionId, _):
                    try container.encode(sessionId.hexString, forKey: .pubkey)
            }
            
            switch signature {
                case .standard(let signature):
                    try container.encode(signature.toBase64(), forKey: .signatureBase64)
                    
                case .subaccount(let subaccount, let subaccountSig, let signature):
                    try container.encode(subaccount.toHexString(), forKey: .subaccount)
                    try container.encode(signature.toBase64(), forKey: .signatureBase64)
                    try container.encode(subaccountSig.toBase64(), forKey: .subaccountSignatureBase64)
            }
        }
    }
}
