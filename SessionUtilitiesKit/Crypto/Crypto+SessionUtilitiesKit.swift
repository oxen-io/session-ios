// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

// MARK: - Randomness

public extension Crypto.Generator {
    static func uuid() -> Crypto.Generator<UUID> {
        return Crypto.Generator(id: "uuid") { UUID() }
    }
    
    static func randomBytes(_ count: Int) -> Crypto.Generator<Data> {
        return Crypto.Generator(id: "randomBytes_Data", args: [count]) { () -> Data in
            Data(bytes: session_random(count), count: count)
        }
    }
    
    static func randomBytes(_ count: Int) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(id: "randomBytes_[UInt8]", args: [count]) { () -> [UInt8] in
            Array(Data(bytes: session_random(count), count: count))
        }
    }
}

// MARK: - Hash

public extension Crypto.Generator {
    static func hash(message: [UInt8], key: [UInt8]? = nil, length: Int = 32) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(id: "hash", args: [message, key]) {
            var cMessage: [UInt8] = message
            var cHash: [UInt8] = [UInt8](repeating: 0, count: length)
            
            switch key {
                case .some(let finalKey):
                    var cKey: [UInt8] = finalKey
                    guard session_hash(length, &cMessage, cMessage.count, &cKey, cKey.count, &cHash) else {
                        throw CryptoError.failedToGenerateOutput
                    }
                    
                case .none:
                    guard session_hash(length, &cMessage, cMessage.count, nil, 0, &cHash) else {
                        throw CryptoError.failedToGenerateOutput
                    }
            }
     
            return cHash
        }
    }
}

// MARK: - curve25519

public extension Crypto.Generator {
    static func x25519KeyPair() -> Crypto.Generator<KeyPair> {
        return Crypto.Generator<KeyPair>(id: "x25519KeyPair") { () -> KeyPair in
            var pubkey: [UInt8] = [UInt8](repeating: 0, count: 32)
            var seckey: [UInt8] = [UInt8](repeating: 0, count: 64)
            
            guard session_curve25519_key_pair(&pubkey, &seckey) else { throw CryptoError.keyGenerationFailed }
            
            return KeyPair(publicKey: pubkey, secretKey: seckey)
        }
    }
    
    static func x25519(
        ed25519Pubkey: [UInt8]
    ) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(
            id: "ed25519Pubkey_to_x25519Pubkey",
            args: [ed25519Pubkey]
        ) {
            var cEd25519Pubkey: [UInt8] = ed25519Pubkey
            var pubkey: [UInt8] = [UInt8](repeating: 0, count: 32)
            
            guard
                cEd25519Pubkey.count == 32,
                session_to_curve25519_pubkey(&cEd25519Pubkey, &pubkey)
            else { throw CryptoError.keyGenerationFailed }
            
            return pubkey
        }
    }
    
    static func x25519(
        ed25519Seckey: [UInt8]
    ) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(
            id: "ed25519Seckey_to_x25519Seckey",
            args: [ed25519Seckey]
        ) {
            var cEd25519SecretKey: [UInt8] = ed25519Seckey
            var seckey: [UInt8] = [UInt8](repeating: 0, count: 32)
            
            guard
                cEd25519SecretKey.count == 64,
                session_to_curve25519_seckey(&cEd25519SecretKey, &seckey)
            else { throw CryptoError.keyGenerationFailed }
            
            return seckey
        }
    }
}

// MARK: - Ed25519

public extension Crypto.Generator {
    static func ed25519KeyPair() -> Crypto.Generator<KeyPair> {
        return Crypto.Generator(id: "ed25519KeyPair") {
            var pubkey: [UInt8] = [UInt8](repeating: 0, count: 32)
            var seckey: [UInt8] = [UInt8](repeating: 0, count: 64)
            
            guard session_ed25519_key_pair(&pubkey, &seckey) else { throw CryptoError.keyGenerationFailed }
            
            return KeyPair(publicKey: pubkey, secretKey: seckey)
        }
    }
    
    static func ed25519KeyPair(seed: [UInt8]) -> Crypto.Generator<KeyPair> {
        return Crypto.Generator(id: "ed25519KeyPair_Seed", args: [seed]) {
            var cSeed: [UInt8] = seed
            var pubkey: [UInt8] = [UInt8](repeating: 0, count: 32)
            var seckey: [UInt8] = [UInt8](repeating: 0, count: 64)
            
            guard
                cSeed.count == 32,
                session_ed25519_key_pair_seed(&cSeed, &pubkey, &seckey)
            else { throw CryptoError.invalidSeed }
            
            return KeyPair(publicKey: pubkey, secretKey: seckey)
        }
    }
    
    static func ed25519Seed(ed25519SecretKey: [UInt8]) -> Crypto.Generator<Data> {
        return Crypto.Generator(id: "ed25519Seed", args: [ed25519SecretKey]) {
            var cEd25519SecretKey: [UInt8] = ed25519SecretKey
            var seed: [UInt8] = [UInt8](repeating: 0, count: 32)
            
            guard
                cEd25519SecretKey.count == 64,
                session_seed_for_ed_privkey(&cEd25519SecretKey, &seed)
            else { throw CryptoError.invalidSeed }
            
            return Data(seed)
        }
    }
    
    static func signature(message: [UInt8], ed25519SecretKey: [UInt8]) -> Crypto.Generator<Authentication.Signature> {
        return Crypto.Generator(id: "signature", args: [message, ed25519SecretKey]) {
            var cEd25519SecretKey: [UInt8] = ed25519SecretKey
            var cMessage: [UInt8] = message
            var cSignature: [UInt8] = [UInt8](repeating: 0, count: 64)
            
            guard
                cEd25519SecretKey.count == 64,
                session_ed25519_sign(&cEd25519SecretKey, &cMessage, cMessage.count, &cSignature)
            else { throw CryptoError.signatureGenerationFailed }
            
            return Authentication.Signature.standard(signature: cSignature)
        }
    }
}

public extension Crypto.Verification {
    static func signature(message: [UInt8], publicKey: [UInt8], signature: [UInt8]) -> Crypto.Verification {
        return Crypto.Verification(id: "signature", args: [message, publicKey, signature]) {
            var cSignature: [UInt8] = signature
            var cPublicKey: [UInt8] = publicKey
            var cMessage: [UInt8] = message
            
            return session_ed25519_verify(
                &cSignature,
                &cPublicKey,
                &cMessage,
                cMessage.count
            )
        }
    }
}

// MARK: - Xed25519

public extension Crypto.Generator {
    static func signatureXed25519(data: [UInt8], curve25519PrivateKey: [UInt8]) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(id: "signatureXed25519", args: [data, curve25519PrivateKey]) {
            var cSignature: [UInt8] = [UInt8](repeating: 0, count: 64)
            var cCurve25519PrivateKey: [UInt8] = curve25519PrivateKey
            var cData: [UInt8] = data
            
            guard
                cCurve25519PrivateKey.count == 32,
                session_xed25519_sign(
                    &cSignature,
                    &cCurve25519PrivateKey,
                    &cData,
                    cData.count
                )
            else { throw CryptoError.signatureGenerationFailed }
            
            return cSignature
        }
    }
}

public extension Crypto.Verification {
    static func signatureXed25519(_ signature: Data, curve25519PublicKey: [UInt8], data: Data) -> Crypto.Verification {
        return Crypto.Verification(id: "signatureXed25519", args: [signature, curve25519PublicKey, data]) {
            var cSignature: [UInt8] = Array(signature)
            var cCurve25519PublicKey: [UInt8] = curve25519PublicKey
            var cData: [UInt8] = Array(data)
            
            return session_xed25519_verify(
                &cSignature,
                &cCurve25519PublicKey,
                &cData,
                cData.count
            )
        }
    }
}
