// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import CryptoKit
import SessionUtil
import SessionUtilitiesKit

public extension Crypto.Generator {
    /// Constructs a "blinded" key pair (`ka, kA`) based on an open group server `publicKey` and an ed25519 `keyPair`
    static func blinded15KeyPair(
        serverPublicKey: String,
        ed25519SecretKey: [UInt8]
    ) -> Crypto.Generator<KeyPair> {
        return Crypto.Generator(
            id: "blindedKeyPair",
            args: [serverPublicKey, ed25519SecretKey]
        ) {
            var cEd25519SecretKey: [UInt8] = Array(ed25519SecretKey)
            var cServerPublicKey: [UInt8] = Array(Data(hex: serverPublicKey))
            var cBlindedPubkey: [UInt8] = [UInt8](repeating: 0, count: 32)
            var cBlindedSeckey: [UInt8] = [UInt8](repeating: 0, count: 32)

            guard
                cEd25519SecretKey.count == 64,
                cServerPublicKey.count == 32,
                session_blind15_key_pair(
                    &cEd25519SecretKey,
                    &cServerPublicKey,
                    &cBlindedPubkey,
                    &cBlindedSeckey
                )
            else { throw CryptoError.keyGenerationFailed }

            return KeyPair(publicKey: cBlindedPubkey, secretKey: cBlindedSeckey)
        }
    }
    
    /// Constructs a "blinded" key pair (`ka, kA`) based on an open group server `publicKey` and an ed25519 `keyPair`
    static func blinded25KeyPair(
        serverPublicKey: String,
        ed25519SecretKey: [UInt8]
    ) -> Crypto.Generator<KeyPair> {
        return Crypto.Generator(
            id: "blindedKeyPair",
            args: [serverPublicKey, ed25519SecretKey]
        ) {
            var cEd25519SecretKey: [UInt8] = Array(ed25519SecretKey)
            var cServerPublicKey: [UInt8] = Array(Data(hex: serverPublicKey))
            var cBlindedPubkey: [UInt8] = [UInt8](repeating: 0, count: 32)
            var cBlindedSeckey: [UInt8] = [UInt8](repeating: 0, count: 32)

            guard
                cEd25519SecretKey.count == 64,
                cServerPublicKey.count == 32,
                session_blind25_key_pair(
                    &cEd25519SecretKey,
                    &cServerPublicKey,
                    &cBlindedPubkey,
                    &cBlindedSeckey
                )
            else { throw CryptoError.keyGenerationFailed }

            return KeyPair(publicKey: cBlindedPubkey, secretKey: cBlindedSeckey)
        }
    }
    
    static func signatureBlind15(
        message: [UInt8],
        serverPublicKey: String,
        ed25519SecretKey: [UInt8]
    ) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(
            id: "signatureBlind15",
            args: [message, serverPublicKey, ed25519SecretKey]
        ) {
            var cEd25519SecretKey: [UInt8] = ed25519SecretKey
            var cServerPublicKey: [UInt8] = Array(Data(hex: serverPublicKey))
            var cMessage: [UInt8] = message
            var cSignature: [UInt8] = [UInt8](repeating: 0, count: 64)
            
            guard
                cEd25519SecretKey.count == 64,
                cServerPublicKey.count == 32,
                session_blind15_sign(
                    &cEd25519SecretKey,
                    &cServerPublicKey,
                    &cMessage,
                    cMessage.count,
                    &cSignature
                )
            else { throw CryptoError.signatureGenerationFailed }
            
            return cSignature
        }
    }
    
    static func signatureBlind25(
        message: [UInt8],
        serverPublicKey: String,
        ed25519SecretKey: [UInt8]
    ) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(
            id: "signatureBlind25",
            args: [message, serverPublicKey, ed25519SecretKey]
        ) {
            var cEd25519SecretKey: [UInt8] = ed25519SecretKey
            var cServerPublicKey: [UInt8] = Array(Data(hex: serverPublicKey))
            var cMessage: [UInt8] = message
            var cSignature: [UInt8] = [UInt8](repeating: 0, count: 64)
            
            guard
                cEd25519SecretKey.count == 64,
                cServerPublicKey.count == 32,
                session_blind25_sign(
                    &cEd25519SecretKey,
                    &cServerPublicKey,
                    &cMessage,
                    cMessage.count,
                    &cSignature
                )
            else { throw CryptoError.signatureGenerationFailed }
            
            return cSignature
        }
    }
}

public extension Crypto.Verification {
    /// This method should be used to check if a users standard sessionId matches a blinded one
    static func sessionId(
        _ standardSessionId: String,
        matchesBlindedId blindedSessionId: String,
        serverPublicKey: String
    ) -> Crypto.Verification {
        return Crypto.Verification(
            id: "sessionId",
            args: [standardSessionId, blindedSessionId, serverPublicKey]
        ) {
            var cSessionId: [CChar] = standardSessionId.cArray
            var cBlindedId15: [CChar] = blindedSessionId.cArray
            var cServerPublicKey: [CChar] = serverPublicKey.cArray
            
            return session_id_matches_blinded_id(
                &cSessionId,
                &cBlindedId15,
                &cServerPublicKey
            )
        }
    }
}

// MARK: - Messages

public extension Crypto.Generator {
    static func ciphertextWithSessionBlindingProtocol(
        _ db: Database,
        plaintext: Data,
        recipientBlindedId: String,
        serverPublicKey: String,
        using dependencies: Dependencies
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "ciphertextWithSessionBlindingProtocol",
            args: [plaintext, serverPublicKey]
        ) {
            let ed25519KeyPair: KeyPair = try Identity.fetchUserEd25519KeyPair(db, using: dependencies) ?? {
                throw MessageSenderError.noUserED25519KeyPair
            }()
            
            var cPlaintext: [UInt8] = Array(plaintext)
            var cEd25519SecretKey: [UInt8] = ed25519KeyPair.secretKey
            var cRecipientBlindedId: [UInt8] = Array(Data(hex: recipientBlindedId))
            var cServerPublicKey: [UInt8] = Array(Data(hex: serverPublicKey))
            var maybeCiphertext: UnsafeMutablePointer<UInt8>? = nil
            var ciphertextLen: Int = 0
            
            guard
                cEd25519SecretKey.count == 64,
                cServerPublicKey.count == 32,
                session_encrypt_for_blinded_recipient(
                    &cPlaintext,
                    cPlaintext.count,
                    &cEd25519SecretKey,
                    &cServerPublicKey,
                    &cRecipientBlindedId,
                    &maybeCiphertext,
                    &ciphertextLen
                ),
                ciphertextLen > 0,
                let ciphertext: Data = maybeCiphertext.map({ Data(bytes: $0, count: ciphertextLen) })
            else { throw MessageSenderError.encryptionFailed }
            
            maybeCiphertext?.deallocate()
            
            return ciphertext
        }
    }
    
    static func plaintextWithSessionBlindingProtocol(
        _ db: Database,
        ciphertext: Data,
        senderId: String,
        recipientId: String,
        serverPublicKey: String,
        using dependencies: Dependencies
    ) -> Crypto.Generator<(plaintext: Data, senderSessionIdHex: String)> {
        return Crypto.Generator(
            id: "plaintextWithSessionBlindingProtocol",
            args: [ciphertext, senderId, recipientId]
        ) {
            let ed25519KeyPair: KeyPair = try Identity.fetchUserEd25519KeyPair(db, using: dependencies) ?? {
                throw MessageSenderError.noUserED25519KeyPair
            }()
            
            var cCiphertext: [UInt8] = Array(ciphertext)
            var cEd25519SecretKey: [UInt8] = ed25519KeyPair.secretKey
            var cSenderId: [UInt8] = Array(Data(hex: senderId))
            var cRecipientId: [UInt8] = Array(Data(hex: recipientId))
            var cServerPublicKey: [UInt8] = Array(Data(hex: serverPublicKey))
            var cSenderSessionId: [CChar] = [CChar](repeating: 0, count: 67)
            var maybePlaintext: UnsafeMutablePointer<UInt8>? = nil
            var plaintextLen: Int = 0
            
            guard
                cEd25519SecretKey.count == 64,
                cServerPublicKey.count == 32,
                session_decrypt_for_blinded_recipient(
                    &cCiphertext,
                    cCiphertext.count,
                    &cEd25519SecretKey,
                    &cServerPublicKey,
                    &cSenderId,
                    &cRecipientId,
                    &cSenderSessionId,
                    &maybePlaintext,
                    &plaintextLen
                ),
                plaintextLen > 0,
                let plaintext: Data = maybePlaintext.map({ Data(bytes: $0, count: plaintextLen) })
            else { throw MessageReceiverError.decryptionFailed }
            
            maybePlaintext?.deallocate()
            
            return (plaintext, String(cString: cSenderSessionId))
        }
    }
}
