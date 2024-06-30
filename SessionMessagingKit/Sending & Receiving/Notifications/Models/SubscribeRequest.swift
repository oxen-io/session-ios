// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionSnodeKit

extension PushNotificationAPI {
    struct SubscribeRequest: Encodable {
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
            case namespaces
            case includeMessageData = "data"
            case timestamp = "sig_ts"
            case signatureBase64 = "signature"
            case service
            case serviceInfo = "service_info"
            case notificationsEncryptionKey = "enc_key"
        }
        
        /// The 33-byte account being subscribed to; typically a session ID.
        private let pubkey: String
        
        /// List of integer namespace (-32768 through 32767).  These must be sorted in ascending order.
        private let namespaces: [SnodeAPI.Namespace]
        
        /// If provided and true then notifications will include the body of the message (as long as it isn't too large); if false then the body will
        /// not be included in notifications.
        private let includeMessageData: Bool
        
        /// Dict of service-specific data; typically this includes just a "token" field with a device-specific token, but different services in the
        /// future may have different input requirements.
        private let serviceInfo: ServiceInfo
        
        /// 32-byte encryption key; notification payloads sent to the device will be encrypted with XChaCha20-Poly1305 using this key.  Though
        /// it is permitted for this to change, it is recommended that the device generate this once and persist it.
        private let notificationsEncryptionKey: Data
        
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
            namespaces: [SnodeAPI.Namespace],
            includeMessageData: Bool,
            serviceInfo: ServiceInfo,
            notificationsEncryptionKey: Data,
            subkey: String?,
            timestamp: TimeInterval,
            ed25519PublicKey: [UInt8],
            ed25519SecretKey: [UInt8]
        ) {
            self.pubkey = pubkey
            self.namespaces = namespaces
            self.includeMessageData = includeMessageData
            self.serviceInfo = serviceInfo
            self.notificationsEncryptionKey = notificationsEncryptionKey
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
            try container.encode(namespaces.map { $0.rawValue}.sorted(), forKey: .namespaces)
            try container.encode(includeMessageData, forKey: .includeMessageData)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(signatureBase64, forKey: .signatureBase64)
            try container.encode(Service.apns, forKey: .service)
            try container.encode(serviceInfo, forKey: .serviceInfo)
            try container.encode(notificationsEncryptionKey.toHexString(), forKey: .notificationsEncryptionKey)
        }
        
        // MARK: - Abstract Methods
        
        func generateSignature() throws -> [UInt8] {
            /// The signature data collected and stored here is used by the PN server to subscribe to the swarms
            /// for the given account; the specific rules are governed by the storage server, but in general:
            ///
            /// A signature must have been produced (via the timestamp) within the past 14 days.  It is
            /// recommended that clients generate a new signature whenever they re-subscribe, and that
            /// re-subscriptions happen more frequently than once every 14 days.
            ///
            /// A signature is signed using the account's Ed25519 private key (or Ed25519 subkey, if using
            /// subkey authentication with a `subkey_tag`, for future closed group subscriptions), and signs the value:
            /// `"MONITOR" || HEX(ACCOUNT) || SIG_TS || DATA01 || NS[0] || "," || ... || "," || NS[n]`
            ///
            /// Where `SIG_TS` is the `sig_ts` value as a base-10 string; `DATA01` is either "0" or "1" depending
            /// on whether the subscription wants message data included; and the trailing `NS[i]` values are a
            /// comma-delimited list of namespaces that should be subscribed to, in the same sorted order as
            /// the `namespaces` parameter.
            let verificationBytes: [UInt8] = "MONITOR".bytes // stringlint:disable
                .appending(contentsOf: pubkey.bytes)
                .appending(contentsOf: "\(timestamp)".bytes)
                .appending(contentsOf: (includeMessageData ? "1" : "0").bytes) // stringlint:disable
                .appending(
                    contentsOf: namespaces
                        .map { $0.rawValue }    // Intentionally not using `verificationString` here
                        .sorted()
                        .map { "\($0)" }
                        .joined(separator: ",")
                        .bytes
                )
            
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
