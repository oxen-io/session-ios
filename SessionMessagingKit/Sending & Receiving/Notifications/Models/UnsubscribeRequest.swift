// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionSnodeKit

extension PushNotificationAPI {
    struct UnsubscribeRequest: Encodable {
        struct ServiceInfo: Codable {
            private enum CodingKeys: String, CodingKey {
                case token
            }
            
            private let token: String
            
            // MARK: - Initialization
            
            init(token: String) {
                self.token = token
            }
        }
        
        private enum CodingKeys: String, CodingKey {
            case pubkey
            case ed25519PublicKey = "session_ed25519"
            case subkey = "subkey_tag"
            case timestamp = "sig_ts"
            case signatureBase64 = "signature"
            case service
            case serviceInfo = "service_info"
        }
        
        /// The 33-byte account being subscribed to; typically a session ID.
        private let pubkey: String
        
        /// Dict of service-specific data; typically this includes just a "token" field with a device-specific token, but different services in the
        /// future may have different input requirements.
        private let serviceInfo: ServiceInfo
        
        /// 32-byte swarm authentication subkey; omitted (or null) when not using subkey auth
        private let subkey: String?
        
        /// The signature unix timestamp (seconds, not ms)
        private let timestamp: Int64
        
        /// When the pubkey value starts with 05 (i.e. a session ID) this is the underlying ed25519 32-byte pubkey associated with the session
        /// ID.  When not 05, this field should not be provided.
        private let ed25519PublicKey: [UInt8]
        
        /// Secret key used to generate the signature (**Not** sent with the request)
        private let ed25519SecretKey: [UInt8]
        
        // MARK: - Initialization
        
        init(
            pubkey: String,
            serviceInfo: ServiceInfo,
            subkey: String?,
            timestamp: TimeInterval,
            ed25519PublicKey: [UInt8],
            ed25519SecretKey: [UInt8]
        ) {
            self.pubkey = pubkey
            self.serviceInfo = serviceInfo
            self.subkey = subkey
            self.timestamp = Int64(timestamp)   // Server expects rounded seconds
            self.ed25519PublicKey = ed25519PublicKey
            self.ed25519SecretKey = ed25519SecretKey
        }
        
        // MARK: - Coding
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            // Generate the signature for the request for encoding
            let signatureBase64: String = try generateSignature().toBase64()
            try container.encode(pubkey, forKey: .pubkey)
            try container.encode(ed25519PublicKey.toHexString(), forKey: .ed25519PublicKey)
            try container.encodeIfPresent(subkey, forKey: .subkey)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(signatureBase64, forKey: .signatureBase64)
            try container.encode(Service.apns, forKey: .service)
            try container.encode(serviceInfo, forKey: .serviceInfo)
        }
        
        // MARK: - Abstract Methods
        
        func generateSignature() throws -> [UInt8] {
            /// A signature is signed using the account's Ed25519 private key (or Ed25519 subkey, if using
            /// subkey authentication with a `subkey_tag`, for future closed group subscriptions), and signs the value:
            /// `"UNSUBSCRIBE" || HEX(ACCOUNT) || SIG_TS`
            ///
            /// Where `SIG_TS` is the `sig_ts` value as a base-10 string and must be within 24 hours of the current time.
            let verificationBytes: [UInt8] = "UNSUBSCRIBE".bytes
                .appending(contentsOf: pubkey.bytes)
                .appending(contentsOf: "\(timestamp)".data(using: .ascii)?.bytes)
            
            // TODO: Need to add handling for subkey auth
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
