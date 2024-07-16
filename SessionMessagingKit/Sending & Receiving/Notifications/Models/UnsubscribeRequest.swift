// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionSnodeKit
import SessionUtilitiesKit

extension PushNotificationAPI {
    struct UnsubscribeRequest: Encodable {
        class Subscription: AuthenticatedRequest {
            private enum CodingKeys: String, CodingKey {
                case service
                case serviceInfo = "service_info"
            }
            
            /// Dict of service-specific data; typically this includes just a "token" field with a device-specific token, but different services in the
            /// future may have different input requirements.
            private let serviceInfo: ServiceInfo
            
            override var verificationBytes: [UInt8] {
                /// A signature is signed using the account's Ed25519 private key (or Ed25519 subaccount, if using
                /// subaccount authentication with a `subaccount_token`, for future closed group subscriptions),
                /// and signs the value:
                /// `"UNSUBSCRIBE" || HEX(ACCOUNT) || SIG_TS`
                ///
                /// Where `SIG_TS` is the `sig_ts` value as a base-10 string and must be within 24 hours of the current time.
                "UNSUBSCRIBE".bytes
                    .appending(contentsOf: authMethod.swarmPublicKey.bytes)
                    .appending(contentsOf: "\(timestamp)".data(using: .ascii)?.bytes)
            }
            
            // MARK: - Initialization
            
            init(
                serviceInfo: ServiceInfo,
                authMethod: AuthenticationMethod,
                timestamp: TimeInterval
            ) {
                self.serviceInfo = serviceInfo
                
                super.init(
                    authMethod: authMethod,
                    timestamp: Int64(timestamp)   // Server expects rounded seconds
                )
            }
            
            // MARK: - Coding
            
            override public func encode(to encoder: Encoder) throws {
                var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
                
                try container.encode(serviceInfo, forKey: .serviceInfo)
                
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
