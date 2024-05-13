// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtilitiesKit

extension SnodeAPI {
    public class ONSResolveResponse: SnodeResponse {
        private struct Result: Codable {
            enum CodingKeys: String, CodingKey {
                case nonce
                case encryptedValue = "encrypted_value"
            }
            
            fileprivate let nonce: String?
            fileprivate let encryptedValue: String
        }
        
        enum CodingKeys: String, CodingKey {
            case result
        }
        
        private let result: Result
        
        // MARK: - Initialization
        
        required init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            result = try container.decode(Result.self, forKey: .result)
            
            try super.init(from: decoder)
        }
        
        // MARK: - Convenience
        
        func sessionId(sodium: Sodium, nameBytes: [UInt8], nameHashBytes: [UInt8]) throws -> String {
            let ciphertext: [UInt8] = Data(hex: result.encryptedValue).bytes
            
            // Handle old Argon2-based encryption used before HF16
            guard let hexEncodedNonce: String = result.nonce else {
                let salt: [UInt8] = Data(repeating: 0, count: sodium.pwHash.SaltBytes).bytes
                
                guard
                    let key: [UInt8] = sodium.pwHash.hash(
                        outputLength: sodium.secretBox.KeyBytes,
                        passwd: nameBytes,
                        salt: salt,
                        opsLimit: sodium.pwHash.OpsLimitModerate,
                        memLimit: sodium.pwHash.MemLimitModerate,
                        alg: .Argon2ID13
                    )
                else { throw SnodeAPIError.onsHashingFailed }
                
                let nonce: [UInt8] = Data(repeating: 0, count: sodium.secretBox.NonceBytes).bytes
                
                guard let sessionIdAsData: [UInt8] = sodium.secretBox.open(authenticatedCipherText: ciphertext, secretKey: key, nonce: nonce) else {
                    throw SnodeAPIError.onsDecryptionFailed
                }

                return sessionIdAsData.toHexString()
            }
            
            let nonceBytes: [UInt8] = Data(hex: hexEncodedNonce).bytes

            // xchacha-based encryption
            // key = H(name, key=H(name))
            guard let key: [UInt8] = sodium.genericHash.hash(message: nameBytes, key: nameHashBytes) else {
                throw SnodeAPIError.onsHashingFailed
            }
            guard
                // Should always be equal in practice
                ciphertext.count >= (SessionId.byteCount + sodium.aead.xchacha20poly1305ietf.ABytes),
                let sessionIdAsData = sodium.aead.xchacha20poly1305ietf.decrypt(
                    authenticatedCipherText: ciphertext,
                    secretKey: key,
                    nonce: nonceBytes
                )
            else { throw SnodeAPIError.onsDecryptionFailed }

            return sessionIdAsData.toHexString()
        }
    }
}
