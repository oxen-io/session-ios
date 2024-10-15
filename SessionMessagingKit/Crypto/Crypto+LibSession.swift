// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Crypto.Generator {
    static func tokenSubaccount(
        config: LibSession.Config?,
        groupSessionId: SessionId,
        memberId: String
    ) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(
            id: "tokenSubaccount",
            args: [config, groupSessionId, memberId]
        ) {
            guard case .groupKeys(let conf, _, _) = config else { throw LibSessionError.invalidConfigObject }
            
            var cMemberId: [CChar] = try memberId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
            var tokenData: [UInt8] = [UInt8](repeating: 0, count: LibSession.sizeSubaccountBytes)
            
            guard groups_keys_swarm_subaccount_token(
                conf,
                &cMemberId,
                &tokenData
            ) else { throw LibSessionError.failedToMakeSubAccountInGroup }
            
            return tokenData
        }
    }
    
    static func memberAuthData(
        config: LibSession.Config?,
        groupSessionId: SessionId,
        memberId: String
    ) -> Crypto.Generator<Authentication.Info> {
        return Crypto.Generator(
            id: "memberAuthData",
            args: [config, groupSessionId, memberId]
        ) {
            guard case .groupKeys(let conf, _, _) = config else { throw LibSessionError.invalidConfigObject }
            
            var cMemberId: [CChar] = try memberId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
            var authData: [UInt8] = [UInt8](repeating: 0, count: LibSession.sizeAuthDataBytes)
            
            guard groups_keys_swarm_make_subaccount(
                conf,
                &cMemberId,
                &authData
            ) else { throw LibSessionError.failedToMakeSubAccountInGroup }
            
            return .groupMember(groupSessionId: groupSessionId, authData: Data(authData))
        }
    }
    
    static func signatureSubaccount(
        config: LibSession.Config?,
        verificationBytes: [UInt8],
        memberAuthData: Data
    ) -> Crypto.Generator<Authentication.Signature> {
        return Crypto.Generator(
            id: "signatureSubaccount",
            args: [config, verificationBytes, memberAuthData]
        ) {
            guard case .groupKeys(let conf, _, _) = config else { throw LibSessionError.invalidConfigObject }
            
            var verificationBytes: [UInt8] = verificationBytes
            var memberAuthData: [UInt8] = Array(memberAuthData)
            var subaccount: [UInt8] = [UInt8](repeating: 0, count: LibSession.sizeSubaccountBytes)
            var subaccountSig: [UInt8] = [UInt8](repeating: 0, count: LibSession.sizeSubaccountSigBytes)
            var signature: [UInt8] = [UInt8](repeating: 0, count: LibSession.sizeSubaccountSignatureBytes)
            
            guard groups_keys_swarm_subaccount_sign_binary(
                conf,
                &verificationBytes,
                verificationBytes.count,
                &memberAuthData,
                &subaccount,
                &subaccountSig,
                &signature
            ) else { throw MessageSenderError.signingFailed }
            
            return Authentication.Signature.subaccount(
                subaccount: subaccount,
                subaccountSig: subaccountSig,
                signature: signature
            )
        }
    }
    
    static func ciphertextForGroupMessage(
        groupSessionId: SessionId,
        message: [UInt8]
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "ciphertextForGroupMessage",
            args: [groupSessionId, message]
        ) { dependencies in
            return try dependencies.mutate(cache: .libSession) { cache in
                guard case .groupKeys(let conf, _, _) = cache.config(for: .groupKeys, sessionId: groupSessionId) else {
                    throw LibSessionError.invalidConfigObject
                }
                
                var maybeCiphertext: UnsafeMutablePointer<UInt8>? = nil
                var ciphertextLen: Int = 0
                groups_keys_encrypt_message(
                    conf,
                    message,
                    message.count,
                    &maybeCiphertext,
                    &ciphertextLen
                )
                
                guard
                    ciphertextLen > 0,
                    let ciphertext: Data = maybeCiphertext
                        .map({ Data(bytes: $0, count: ciphertextLen) })
                else { throw MessageSenderError.encryptionFailed }
                
                return ciphertext
            } ?? { throw MessageSenderError.encryptionFailed }()
        }
    }
    
    static func plaintextForGroupMessage(
        groupSessionId: SessionId,
        ciphertext: [UInt8]
    ) throws -> Crypto.Generator<(plaintext: Data, sender: String)> {
        return Crypto.Generator(
            id: "plaintextForGroupMessage",
            args: [groupSessionId, ciphertext]
        ) { dependencies in
            return try dependencies.mutate(cache: .libSession) { cache in
                guard case .groupKeys(let conf, _, _) = cache.config(for: .groupKeys, sessionId: groupSessionId) else {
                    throw LibSessionError.invalidConfigObject
                }
                
                var cSessionId: [CChar] = [CChar](repeating: 0, count: 67)
                var maybePlaintext: UnsafeMutablePointer<UInt8>? = nil
                var plaintextLen: Int = 0
                let didDecrypt: Bool = groups_keys_decrypt_message(
                    conf,
                    ciphertext,
                    ciphertext.count,
                    &cSessionId,
                    &maybePlaintext,
                    &plaintextLen
                )
                
                // If we got a reported failure then just stop here
                guard didDecrypt else { throw MessageReceiverError.decryptionFailed }
                
                // We need to manually free 'maybePlaintext' upon a successful decryption
                defer { maybePlaintext?.deallocate() }
                
                guard
                    plaintextLen > 0,
                    let plaintext: Data = maybePlaintext
                        .map({ Data(bytes: $0, count: plaintextLen) })
                else { throw MessageReceiverError.decryptionFailed }
                
                return (plaintext, String(cString: cSessionId))
            } ?? { throw MessageReceiverError.decryptionFailed }()
        }
    }
}

public extension Crypto.Verification {
    static func memberAuthData(
        groupSessionId: SessionId,
        ed25519SecretKey: [UInt8],
        memberAuthData: Data
    ) -> Crypto.Verification {
        return Crypto.Verification(
            id: "memberAuthData",
            args: [groupSessionId, ed25519SecretKey, memberAuthData]
        ) {
            guard var cGroupId: [CChar] = groupSessionId.hexString.cString(using: .utf8) else { return false }
            
            var cEd25519SecretKey: [UInt8] = ed25519SecretKey
            var cAuthData: [UInt8] = Array(memberAuthData)
            
            return groups_keys_swarm_verify_subaccount(
                &cGroupId,
                &cEd25519SecretKey,
                &cAuthData
            )
        }
    }
}
