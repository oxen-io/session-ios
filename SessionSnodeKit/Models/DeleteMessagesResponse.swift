// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public class DeleteMessagesResponse: SnodeRecursiveResponse<DeleteMessagesResponse.SwarmItem> {}

// MARK: - SwarmItem

public extension DeleteMessagesResponse {
    class SwarmItem: SnodeSwarmItem {
        private enum CodingKeys: String, CodingKey {
            case deleted
        }
        
        public let deleted: [String]
        
        // MARK: - Initialization
        
        required init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            deleted = ((try? container.decode([String].self, forKey: .deleted)) ?? [])
            
            try super.init(from: decoder)
        }
    }
}

// MARK: - ValidatableResponse

extension DeleteMessagesResponse: ValidatableResponse {
    typealias ValidationData = [String]
    typealias ValidationResponse = Bool
    
    /// Just one response in the swarm must be valid
    internal static var requiredSuccessfulResponses: Int { 1 }
    
    internal func validResultMap(
        publicKey: String,
        validationData: [String],
        using dependencies: Dependencies
    ) throws -> [String: Bool] {
        let validationMap: [String: Bool] = swarm.reduce(into: [:]) { result, next in
            guard
                !next.value.failed,
                let signatureBase64: String = next.value.signatureBase64,
                let encodedSignature: Data = Data(base64Encoded: signatureBase64)
            else {
                result[next.key] = false
                
                if let reason: String = next.value.reason, let statusCode: Int = next.value.code {
                    SNLog("Couldn't delete data from: \(next.key) due to error: \(reason) (\(statusCode)).")
                }
                else {
                    SNLog("Couldn't delete data from: \(next.key).")
                }
                return
            }
            
            /// The signature format is `( PUBKEY_HEX || RMSG[0] || ... || RMSG[N] || DMSG[0] || ... || DMSG[M] )`
            let verificationBytes: [UInt8] = publicKey.bytes
                .appending(contentsOf: validationData.joined().bytes)
                .appending(contentsOf: next.value.deleted.joined().bytes)
            
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
