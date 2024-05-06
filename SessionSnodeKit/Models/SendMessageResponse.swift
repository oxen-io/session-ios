// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public final class SendMessagesResponse: SnodeRecursiveResponse<SendMessagesResponse.SwarmItem> {
    private enum CodingKeys: String, CodingKey {
        case hash
        case swarm
    }
    
    public let hash: String
    
    // MARK: - Initialization
    
    internal init(
        hash: String,
        swarm: [String: SwarmItem],
        hardFork: [Int],
        timeOffset: Int64
    ) {
        self.hash = hash
        
        super.init(
            swarm: swarm,
            hardFork: hardFork,
            timeOffset: timeOffset
        )
    }
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        hash = try container.decode(String.self, forKey: .hash)
        
        try super.init(from: decoder)
    }
}

// MARK: - SwarmItem

public extension SendMessagesResponse {
    class SwarmItem: SnodeSwarmItem {
        private enum CodingKeys: String, CodingKey {
            case hash
            case already
        }
        
        public let hash: String?
        
        /// `true` if a message with this hash was already stored
        ///
        /// **Note:** The `hash` is still included and signed even if this occurs
        public let already: Bool
        
        // MARK: - Initialization
        
        required init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            hash = try? container.decode(String.self, forKey: .hash)
            already = ((try? container.decode(Bool.self, forKey: .already)) ?? false)
            
            try super.init(from: decoder)
        }
    }
}

// MARK: - ValidatableResponse

extension SendMessagesResponse: ValidatableResponse {
    typealias ValidationData = Void
    typealias ValidationResponse = Bool
    
    /// Half of the responses in the swarm must be valid
    internal static var requiredSuccessfulResponses: Int { -2 }
    
    internal func validResultMap(
        publicKey: String,
        validationData: Void,
        using dependencies: Dependencies
    ) throws -> [String: Bool] {
        let validationMap: [String: Bool] = swarm.reduce(into: [:]) { result, next in
            guard
                !next.value.failed,
                let signatureBase64: String = next.value.signatureBase64,
                let encodedSignature: Data = Data(base64Encoded: signatureBase64),
                let hash: String = next.value.hash
            else {
                result[next.key] = false
                
                if let reason: String = next.value.reason, let statusCode: Int = next.value.code {
                    SNLog("Couldn't store message on: \(next.key) due to error: \(reason) (\(statusCode)).")
                }
                else {
                    SNLog("Couldn't store message on: \(next.key).")
                }
                return
            }
            
            /// Signature of `hash` signed by the node's ed25519 pubkey
            let verificationBytes: [UInt8] = hash.bytes
            
            result[next.key] = dependencies[singleton: .crypto].verify(
                .signature(
                    message: verificationBytes,
                    publicKey: Data(hex: next.key).bytes,
                    signature: encodedSignature.bytes
                )
            )
        }
        
        return try Self.validated(map: validationMap)
    }
}
