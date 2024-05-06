// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public class DeleteAllBeforeResponse: SnodeRecursiveResponse<DeleteAllMessagesResponse.SwarmItem> {}

// MARK: - ValidatableResponse

extension DeleteAllBeforeResponse: ValidatableResponse {
    typealias ValidationData = UInt64
    typealias ValidationResponse = Bool
    
    /// Just one response in the swarm must be valid
    internal static var requiredSuccessfulResponses: Int { 1 }
    
    internal func validResultMap(
        publicKey: String,
        validationData: UInt64,
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
            
            /// Signature of `( PUBKEY_HEX || BEFORE || DELETEDHASH[0] || ... || DELETEDHASH[N] )`
            /// signed by the node's ed25519 pubkey.  When doing a multi-namespace delete the `DELETEDHASH`
            /// values are totally ordered (i.e. among all the hashes deleted regardless of namespace)
            let verificationBytes: [UInt8] = publicKey.bytes
                .appending(contentsOf: "\(validationData)".data(using: .ascii)?.bytes)
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
