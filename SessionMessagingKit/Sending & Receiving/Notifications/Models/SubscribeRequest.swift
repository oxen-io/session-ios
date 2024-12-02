// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionSnodeKit
import SessionUtilitiesKit

extension PushNotificationAPI {
    struct SubscribeRequest: Encodable {
        class Subscription: AuthenticatedRequest {
            private enum CodingKeys: String, CodingKey {
                case namespaces
                case includeMessageData = "data"
                case service
                case serviceInfo = "service_info"
                case notificationsEncryptionKey = "enc_key"
            }
            
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
            
            override var verificationBytes: [UInt8] {
                /// The signature data collected and stored here is used by the PN server to subscribe to the swarms
                /// for the given account; the specific rules are governed by the storage server, but in general:
                ///
                /// A signature must have been produced (via the timestamp) within the past 14 days.  It is
                /// recommended that clients generate a new signature whenever they re-subscribe, and that
                /// re-subscriptions happen more frequently than once every 14 days.
                ///
                /// A signature is signed using the account's Ed25519 private key (or Ed25519 subaccount, if using
                /// subaccount authentication with a `subaccount_token`, for future closed group subscriptions),
                /// and signs the value:
                /// `"MONITOR" || HEX(ACCOUNT) || SIG_TS || DATA01 || NS[0] || "," || ... || "," || NS[n]`
                ///
                /// Where `SIG_TS` is the `sig_ts` value as a base-10 string; `DATA01` is either "0" or "1" depending
                /// on whether the subscription wants message data included; and the trailing `NS[i]` values are a
                /// comma-delimited list of namespaces that should be subscribed to, in the same sorted order as
                /// the `namespaces` parameter.
                "MONITOR".bytes
                    .appending(contentsOf: authMethod.swarmPublicKey.bytes)
                    .appending(contentsOf: "\(timestamp)".bytes)
                    .appending(contentsOf: (includeMessageData ? "1" : "0").bytes)
                    .appending(
                        contentsOf: namespaces
                            .map { $0.rawValue }    // Intentionally not using `verificationString` here
                            .sorted()
                            .map { "\($0)" }
                            .joined(separator: ",")
                            .bytes
                    )
            }
            
            // MARK: - Initialization
            
            init(
                namespaces: [SnodeAPI.Namespace],
                includeMessageData: Bool,
                serviceInfo: ServiceInfo,
                notificationsEncryptionKey: Data,
                authMethod: AuthenticationMethod,
                timestamp: TimeInterval
            ) {
                self.namespaces = namespaces
                self.includeMessageData = includeMessageData
                self.serviceInfo = serviceInfo
                self.notificationsEncryptionKey = notificationsEncryptionKey
                
                super.init(
                    authMethod: authMethod,
                    timestamp: Int64(timestamp)   // Server expects rounded seconds
                )
            }
            
            // MARK: - Coding
            
            override public func encode(to encoder: Encoder) throws {
                var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
                
                // Generate the signature for the request for encoding
                try container.encode(namespaces.map { $0.rawValue}.sorted(), forKey: .namespaces)
                try container.encode(includeMessageData, forKey: .includeMessageData)
                try container.encode(serviceInfo, forKey: .serviceInfo)
                try container.encode(notificationsEncryptionKey.toHexString(), forKey: .notificationsEncryptionKey)
                
                // Use the correct APNS service based on the serviceNetwork (default to mainnet)
                switch encoder.dependencies?[feature: .serviceNetwork] {
                    case .testnet: try container.encode(Service.sandbox, forKey: .service)
                    case .mainnet, .none: try container.encode(Service.apns, forKey: .service)
                }
                
                try super.encode(to: encoder)
            }
        }
        
        private let subscriptions: [Subscription]
        
        public init(
            subscriptions: [Subscription]
        ) {
            self.subscriptions = subscriptions
        }
        
        // MARK: - Coding
        
        public func encode(to encoder: Encoder) throws {
            guard subscriptions.count > 1 else {
                try subscriptions[0].encode(to: encoder)
                return
            }
            
            try subscriptions.encode(to: encoder)
        }
    }
}
