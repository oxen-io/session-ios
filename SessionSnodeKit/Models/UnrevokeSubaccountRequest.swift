// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension SnodeAPI {
    public class UnrevokeSubaccountRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case subaccountsToUnrevoke = "unrevoke"
        }
        
        let subaccountsToUnrevoke: [[UInt8]]
        
        override var verificationBytes: [UInt8] {
            /// Ed25519 signature of `("unrevoke_subaccount" || timestamp || subaccount)`; this signs
            /// the subaccount token, using `pubkey` to sign. Must be base64 encoded for json requests; binary for OMQ requests.
            SnodeAPI.Endpoint.unrevokeSubaccount.path.bytes
                .appending(contentsOf: timestampMs.map { "\($0)" }?.data(using: .ascii)?.bytes)
                .appending(contentsOf: Array(subaccountsToUnrevoke.joined()))
        }
        
        // MARK: - Init
        
        public init(
            subaccountsToUnrevoke: [[UInt8]],
            authMethod: AuthenticationMethod,
            timestampMs: UInt64
        ) {
            self.subaccountsToUnrevoke = subaccountsToUnrevoke
            
            super.init(
                authMethod: authMethod,
                timestampMs: timestampMs
            )
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            /// The `subaccountsToUnrevoke` should be sent as either a single hex string or an array of them
            switch subaccountsToUnrevoke.count {
                case 1: try container.encode(subaccountsToUnrevoke[0].toHexString(), forKey: .subaccountsToUnrevoke)
                default:
                    try container.encode(subaccountsToUnrevoke.map { $0.toHexString() }, forKey: .subaccountsToUnrevoke)
            }
            
            try super.encode(to: encoder)
        }
    }
}
