// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension SnodeAPI {
    public class DeleteMessagesRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case messageHashes = "messages"
            case requireSuccessfulDeletion = "required"
        }
        
        let messageHashes: [String]
        let requireSuccessfulDeletion: Bool
        
        override var verificationBytes: [UInt8] {
            /// Ed25519 signature of `("delete" || messages...)`; this signs the value constructed
            /// by concatenating "delete" and all `messages` values, using `pubkey` to sign.  Must be base64
            /// encoded for json requests; binary for OMQ requests.
            SnodeAPI.Endpoint.deleteMessages.path.bytes
                .appending(contentsOf: messageHashes.joined().bytes)
        }
        
        // MARK: - Init
        
        public init(
            messageHashes: [String],
            requireSuccessfulDeletion: Bool,
            authMethod: AuthenticationMethod
        ) {
            self.messageHashes = messageHashes
            self.requireSuccessfulDeletion = requireSuccessfulDeletion
            
            super.init(authMethod: authMethod)
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(messageHashes, forKey: .messageHashes)
            
            // Omitting the value is the same as false so omit to save data
            if requireSuccessfulDeletion {
                try container.encode(requireSuccessfulDeletion, forKey: .requireSuccessfulDeletion)
            }
            
            try super.encode(to: encoder)
        }
    }
}
