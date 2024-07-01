// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUtilitiesKit

// MARK: - ONS Response

internal extension Crypto.Generator {
    static func sessionId(
        name: String,
        response: SnodeAPI.ONSResolveResponse
    ) -> Crypto.Generator<String> {
        return Crypto.Generator(
            id: "sessionId_for_ONS_response",
            args: [name, response]
        ) {
            guard let hexEncodedNonce: String = response.result.nonce else {
                throw SnodeAPIError.onsDecryptionFailed
            }
            
            // Name must be in lowercase
            var cCiphertext: [UInt8] = Array(Data(hex: response.result.encryptedValue))
            var cNonce: [UInt8] = Array(Data(hex: hexEncodedNonce))
            var cSessionId: [CChar] = [CChar](repeating: 0, count: 67)
            
            guard
                cNonce.count == 24,
                session_decrypt_ons_response(
                    name.lowercased().cString(using: .utf8),
                    name.count,
                    &cCiphertext,
                    cCiphertext.count,
                    &cNonce,
                    &cSessionId
                )
            else { throw SnodeAPIError.onsDecryptionFailed }
            
            return String(cString: cSessionId)
        }
    }
}
