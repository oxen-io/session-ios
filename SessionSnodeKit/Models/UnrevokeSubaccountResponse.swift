// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public class UnrevokeSubaccountResponse: SnodeRecursiveResponse<SnodeSwarmItem> {}

// MARK: - ValidatableResponse

extension UnrevokeSubaccountResponse: ValidatableResponse {
    typealias ValidationData = (subaccountsToUnrevoke: [[UInt8]], timestampMs: UInt64)
    typealias ValidationResponse = Bool
    
    /// All responses in the swarm must be valid
    internal static var requiredSuccessfulResponses: Int { -1 }
    
    internal func validResultMap(
        publicKey: String,
        validationData: (subaccountsToUnrevoke: [[UInt8]], timestampMs: UInt64),
        using dependencies: Dependencies
    ) throws -> [String: Bool] {
        let validationMap: [String: Bool] = try swarm.reduce(into: [:]) { result, next in
            guard
                !next.value.failed,
                let signatureBase64: String = next.value.signatureBase64,
                let encodedSignature: Data = Data(base64Encoded: signatureBase64)
            else {
                if let reason: String = next.value.reason, let statusCode: Int = next.value.code {
                    SNLog("Couldn't revoke subaccount from: \(next.key) due to error: \(reason) (\(statusCode)).")
                }
                else {
                    SNLog("Couldn't revoke subaccount from: \(next.key).")
                }
                return
            }
            
            /// Signature of `( PUBKEY_HEX || timestamp || SUBACCOUNT_TOKEN_BYTES... )` where `SUBACCOUNT_TOKEN_BYTES` is the
            /// requested subaccount token for revocation
            let verificationBytes: [UInt8] = publicKey.bytes
                .appending(contentsOf: "\(validationData.timestampMs)".data(using: .ascii)?.bytes)
                .appending(contentsOf: Array(validationData.subaccountsToUnrevoke.joined()))
            
            let isValid: Bool = dependencies[singleton: .crypto].verify(
                .signature(
                    message: verificationBytes,
                    publicKey: Data(hex: next.key).bytes,
                    signature: encodedSignature.bytes
                )
            )
            
            // If the update signature is invalid then we want to fail here
            guard isValid else { throw SnodeAPIError.signatureVerificationFailed }
            
            result[next.key] = isValid
        }
        
        return try Self.validated(map: validationMap)
    }
}
