// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import GRDB
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class MessageReceiverDecryptionSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto
                    .when { crypto in
                        try crypto.perform(
                            .encryptAeadXChaCha20(
                                message: anyArray(),
                                secretKey: anyArray(),
                                nonce: anyArray(),
                                using: any()
                            )
                        )
                    }
                    .thenReturn(nil)
                crypto
                    .when {
                        try $0.perform(
                            .open(
                                anonymousCipherText: anyArray(),
                                recipientPublicKey: anyArray(),
                                recipientSecretKey: anyArray()
                            )
                        )
                    }
                    .thenReturn([UInt8](repeating: 0, count: 100))
                crypto
                    .when { crypto in
                        crypto.generate(
                            .blindedKeyPair(
                                serverPublicKey: any(),
                                edKeyPair: any(),
                                using: any()
                            )
                        )
                    }
                    .thenReturn(
                        KeyPair(
                            publicKey: Data(hex: TestConstants.blindedPublicKey).bytes,
                            secretKey: Data(hex: TestConstants.edSecretKey).bytes
                        )
                    )
                crypto
                    .when { crypto in
                        try crypto.perform(
                            .sharedBlindedEncryptionKey(
                                secretKey: anyArray(),
                                otherBlindedPublicKey: anyArray(),
                                fromBlindedPublicKey: anyArray(),
                                toBlindedPublicKey: anyArray(),
                                using: any()
                            )
                        )
                    }
                    .thenReturn([])
                crypto
                    .when { crypto in
                        try crypto.perform(
                            .generateBlindingFactor(serverPublicKey: any(), using: any())
                        )
                    }
                    .thenReturn([])
                crypto
                    .when { try $0.perform(.combineKeys(lhsKeyBytes: anyArray(), rhsKeyBytes: anyArray())) }
                    .thenReturn(Data(hex: TestConstants.blindedPublicKey).bytes)
                crypto
                    .when { try $0.perform(.toX25519(ed25519PublicKey: anyArray())) }
                    .thenReturn(Data(hex: TestConstants.publicKey).bytes)
                crypto
                    .when { $0.verify(.signature(message: anyArray(), publicKey: anyArray(), signature: anyArray())) }
                    .thenReturn(true)
                crypto
                    .when {
                        try $0.perform(
                            .decryptAeadXChaCha20(
                                authenticatedCipherText: anyArray(),
                                secretKey: anyArray(),
                                nonce: anyArray()
                            )
                        )
                    }
                    .thenReturn("TestMessage".data(using: .utf8)!.bytes + [UInt8](repeating: 0, count: 32))
                crypto.when { $0.size(.nonce24) }.thenReturn(24)
                crypto.when { $0.size(.publicKey) }.thenReturn(32)
                crypto.when { $0.size(.signature) }.thenReturn(64)
                crypto
                    .when { try $0.perform(.generateNonce24()) }
                    .thenReturn(Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!.bytes)
            }
        )
        @TestState var dependencies: Dependencies! = Dependencies(
            storage: nil,
            crypto: mockCrypto
        )
        @TestState var mockStorage: Storage! = {
            let result = SynchronousStorage(
                customWriter: try! DatabaseQueue(),
                migrationTargets: [
                    SNUtilitiesKit.self,
                    SNMessagingKit.self
                ],
                initialData: { db in
                    try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                    try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
                },
                using: dependencies
            )
            dependencies.storage = result
            
            return result
        }()
        
        // MARK: - a MessageReceiver
        describe("a MessageReceiver") {
            // MARK: -- when decrypting with the session protocol
            context("when decrypting with the session protocol") {
                // MARK: ---- successfully decrypts a message
                it("successfully decrypts a message") {
                    let result = try? MessageReceiver.decryptWithSessionProtocol(
                        ciphertext: Data(
                            base64Encoded: "SRP0eBUWh4ez6ppWjUs5/Wph5fhnPRgB5zsWWnTz+FBAw/YI3oS2pDpIfyetMTbU" +
                            "sFMhE5G4PbRtQFey1hsxLl221Qivc3ayaX2Mm/X89Dl8e45BC+Lb/KU9EdesxIK4pVgYXs9XrMtX3v8" +
                            "dt0eBaXneOBfr7qB8pHwwMZjtkOu1ED07T9nszgbWabBphUfWXe2U9K3PTRisSCI="
                        )!,
                        using: KeyPair(
                            publicKey: Data.data(fromHex: TestConstants.publicKey)!.bytes,
                            secretKey: Data.data(fromHex: TestConstants.privateKey)!.bytes
                        ),
                        using: Dependencies()
                    )
                    
                    expect(String(data: (result?.plaintext ?? Data()), encoding: .utf8)).to(equal("TestMessage"))
                    expect(result?.senderX25519PublicKey)
                        .to(equal("0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
                }
                
                // MARK: ---- throws an error if it cannot open the message
                it("throws an error if it cannot open the message") {
                    mockCrypto
                        .when {
                            try $0.perform(
                                .open(
                                    anonymousCipherText: anyArray(),
                                    recipientPublicKey: anyArray(),
                                    recipientSecretKey: anyArray()
                                )
                            )
                        }
                        .thenReturn(nil)
                    
                    expect {
                        try MessageReceiver.decryptWithSessionProtocol(
                            ciphertext: "TestMessage".data(using: .utf8)!,
                            using: KeyPair(
                                publicKey: Data.data(fromHex: TestConstants.publicKey)!.bytes,
                                secretKey: Data.data(fromHex: TestConstants.privateKey)!.bytes
                            ),
                            using: dependencies
                        )
                    }
                    .to(throwError(MessageReceiverError.decryptionFailed))
                }
                
                // MARK: ---- throws an error if the open message is too short
                it("throws an error if the open message is too short") {
                    mockCrypto
                        .when {
                            try $0.perform(
                                .open(
                                    anonymousCipherText: anyArray(),
                                    recipientPublicKey: anyArray(),
                                    recipientSecretKey: anyArray()
                                )
                            )
                        }
                        .thenReturn([1, 2, 3])
                    
                    expect {
                        try MessageReceiver.decryptWithSessionProtocol(
                            ciphertext: "TestMessage".data(using: .utf8)!,
                            using: KeyPair(
                                publicKey: Data.data(fromHex: TestConstants.publicKey)!.bytes,
                                secretKey: Data.data(fromHex: TestConstants.privateKey)!.bytes
                            ),
                            using: dependencies
                        )
                    }
                    .to(throwError(MessageReceiverError.decryptionFailed))
                }
                
                // MARK: ---- throws an error if it cannot verify the message
                it("throws an error if it cannot verify the message") {
                    mockCrypto
                        .when { $0.verify(.signature(message: anyArray(), publicKey: anyArray(), signature: anyArray())) }
                        .thenReturn(false)
                    
                    expect {
                        try MessageReceiver.decryptWithSessionProtocol(
                            ciphertext: "TestMessage".data(using: .utf8)!,
                            using: KeyPair(
                                publicKey: Data.data(fromHex: TestConstants.publicKey)!.bytes,
                                secretKey: Data.data(fromHex: TestConstants.privateKey)!.bytes
                            ),
                            using: dependencies
                        )
                    }
                    .to(throwError(MessageReceiverError.invalidSignature))
                }
                
                // MARK: ---- throws an error if it cannot get the senders x25519 public key
                it("throws an error if it cannot get the senders x25519 public key") {
                    mockCrypto.when { try $0.perform(.toX25519(ed25519PublicKey: anyArray())) }.thenReturn(nil)
                    
                    expect {
                        try MessageReceiver.decryptWithSessionProtocol(
                            ciphertext: "TestMessage".data(using: .utf8)!,
                            using: KeyPair(
                                publicKey: Data.data(fromHex: TestConstants.publicKey)!.bytes,
                                secretKey: Data.data(fromHex: TestConstants.privateKey)!.bytes
                            ),
                            using: dependencies
                        )
                    }
                    .to(throwError(MessageReceiverError.decryptionFailed))
                }
            }
            
            // MARK: -- when decrypting with the blinded session protocol
            context("when decrypting with the blinded session protocol") {
                // MARK: ---- successfully decrypts a message
                it("successfully decrypts a message") {
                    let result = try? MessageReceiver.decryptWithSessionBlindingProtocol(
                        data: Data(
                            hex: "00db16b6687382811d69875a5376f66acad9c49fe5e26bcf770c7e6e9c230299" +
                            "f61b315299dd1fa700dd7f34305c0465af9e64dc791d7f4123f1eeafa5b4d48b3ade4" +
                            "f4b2a2764762e5a2c7900f254bd91633b43"
                        ),
                        isOutgoing: true,
                        otherBlindedPublicKey: "15\(TestConstants.blindedPublicKey)",
                        with: TestConstants.serverPublicKey,
                        userEd25519KeyPair: KeyPair(
                            publicKey: Data.data(fromHex: TestConstants.edPublicKey)!.bytes,
                            secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                        ),
                        using: Dependencies()
                    )
                    
                    expect(String(data: (result?.plaintext ?? Data()), encoding: .utf8)).to(equal("TestMessage"))
                    expect(result?.senderX25519PublicKey)
                        .to(equal("0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
                }
                
                // MARK: ---- successfully decrypts a mocked incoming message
                it("successfully decrypts a mocked incoming message") {
                    let result = try? MessageReceiver.decryptWithSessionBlindingProtocol(
                        data: (
                            Data([0]) +
                            "TestMessage".data(using: .utf8)! +
                            Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!
                        ),
                        isOutgoing: false,
                        otherBlindedPublicKey: "15\(TestConstants.blindedPublicKey)",
                        with: TestConstants.serverPublicKey,
                        userEd25519KeyPair: KeyPair(
                            publicKey: Data.data(fromHex: TestConstants.edPublicKey)!.bytes,
                            secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                        ),
                        using: dependencies
                    )
                    
                    expect(String(data: (result?.plaintext ?? Data()), encoding: .utf8)).to(equal("TestMessage"))
                    expect(result?.senderX25519PublicKey)
                        .to(equal("0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
                }
                
                // MARK: ---- throws an error if the data is too short
                it("throws an error if the data is too short") {
                    expect {
                        try MessageReceiver.decryptWithSessionBlindingProtocol(
                            data: Data([1, 2, 3]),
                            isOutgoing: true,
                            otherBlindedPublicKey: "15\(TestConstants.blindedPublicKey)",
                            with: TestConstants.serverPublicKey,
                            userEd25519KeyPair: KeyPair(
                                publicKey: Data.data(fromHex: TestConstants.edPublicKey)!.bytes,
                                secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                            ),
                            using: dependencies
                        )
                    }
                    .to(throwError(MessageReceiverError.decryptionFailed))
                }
                
                // MARK: ---- throws an error if it cannot get the blinded keyPair
                it("throws an error if it cannot get the blinded keyPair") {
                    mockCrypto
                        .when { [dependencies = dependencies!] crypto in
                            crypto.generate(
                                .blindedKeyPair(
                                    serverPublicKey: any(),
                                    edKeyPair: any(),
                                    using: dependencies
                                )
                            )
                        }
                        .thenReturn(nil)
                    
                    expect {
                        try MessageReceiver.decryptWithSessionBlindingProtocol(
                            data: (
                                Data([0]) +
                                "TestMessage".data(using: .utf8)! +
                                Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!
                            ),
                            isOutgoing: true,
                            otherBlindedPublicKey: "15\(TestConstants.blindedPublicKey)",
                            with: TestConstants.serverPublicKey,
                            userEd25519KeyPair: KeyPair(
                                publicKey: Data.data(fromHex: TestConstants.edPublicKey)!.bytes,
                                secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                            ),
                            using: dependencies
                        )
                    }
                    .to(throwError(MessageReceiverError.decryptionFailed))
                }
                
                // MARK: ---- throws an error if it cannot get the decryption key
                it("throws an error if it cannot get the decryption key") {
                    mockCrypto
                        .when { [dependencies = dependencies!] crypto in
                            try crypto.perform(
                                .sharedBlindedEncryptionKey(
                                    secretKey: anyArray(),
                                    otherBlindedPublicKey: anyArray(),
                                    fromBlindedPublicKey: anyArray(),
                                    toBlindedPublicKey: anyArray(),
                                    using: dependencies
                                )
                            )
                        }
                        .thenReturn(nil)
                    
                    expect {
                        try MessageReceiver.decryptWithSessionBlindingProtocol(
                            data: (
                                Data([0]) +
                                "TestMessage".data(using: .utf8)! +
                                Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!
                            ),
                            isOutgoing: true,
                            otherBlindedPublicKey: "15\(TestConstants.blindedPublicKey)",
                            with: TestConstants.serverPublicKey,
                            userEd25519KeyPair: KeyPair(
                                publicKey: Data.data(fromHex: TestConstants.edPublicKey)!.bytes,
                                secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                            ),
                            using: dependencies
                        )
                    }
                    .to(throwError(MessageReceiverError.decryptionFailed))
                }
                
                // MARK: ---- throws an error if the data version is not 0
                it("throws an error if the data version is not 0") {
                    expect {
                        try MessageReceiver.decryptWithSessionBlindingProtocol(
                            data: (
                                Data([1]) +
                                "TestMessage".data(using: .utf8)! +
                                Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!
                            ),
                            isOutgoing: true,
                            otherBlindedPublicKey: "15\(TestConstants.blindedPublicKey)",
                            with: TestConstants.serverPublicKey,
                            userEd25519KeyPair: KeyPair(
                                publicKey: Data.data(fromHex: TestConstants.edPublicKey)!.bytes,
                                secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                            ),
                            using: dependencies
                        )
                    }
                    .to(throwError(MessageReceiverError.decryptionFailed))
                }
                
                // MARK: ---- throws an error if it cannot decrypt the data
                it("throws an error if it cannot decrypt the data") {
                    mockCrypto
                        .when {
                            try $0.perform(
                                .decryptAeadXChaCha20(
                                    authenticatedCipherText: anyArray(),
                                    secretKey: anyArray(),
                                    nonce: anyArray()
                                )
                            )
                        }
                        .thenReturn(nil)
                    
                    expect {
                        try MessageReceiver.decryptWithSessionBlindingProtocol(
                            data: (
                                Data([0]) +
                                "TestMessage".data(using: .utf8)! +
                                Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!
                            ),
                            isOutgoing: true,
                            otherBlindedPublicKey: "15\(TestConstants.blindedPublicKey)",
                            with: TestConstants.serverPublicKey,
                            userEd25519KeyPair: KeyPair(
                                publicKey: Data.data(fromHex: TestConstants.edPublicKey)!.bytes,
                                secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                            ),
                            using: dependencies
                        )
                    }
                    .to(throwError(MessageReceiverError.decryptionFailed))
                }
                
                // MARK: ---- throws an error if the inner bytes are too short
                it("throws an error if the inner bytes are too short") {
                    mockCrypto
                        .when {
                            try $0.perform(
                                .decryptAeadXChaCha20(
                                    authenticatedCipherText: anyArray(),
                                    secretKey: anyArray(),
                                    nonce: anyArray()
                                )
                            )
                        }
                        .thenReturn([1, 2, 3])
                    
                    expect {
                        try MessageReceiver.decryptWithSessionBlindingProtocol(
                            data: (
                                Data([0]) +
                                "TestMessage".data(using: .utf8)! +
                                Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!
                            ),
                            isOutgoing: true,
                            otherBlindedPublicKey: "15\(TestConstants.blindedPublicKey)",
                            with: TestConstants.serverPublicKey,
                            userEd25519KeyPair: KeyPair(
                                publicKey: Data.data(fromHex: TestConstants.edPublicKey)!.bytes,
                                secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                            ),
                            using: dependencies
                        )
                    }
                    .to(throwError(MessageReceiverError.decryptionFailed))
                }
                
                // MARK: ---- throws an error if it cannot generate the blinding factor
                it("throws an error if it cannot generate the blinding factor") {
                    mockCrypto
                        .when { [dependencies = dependencies!] crypto in
                            try crypto.perform(.generateBlindingFactor(serverPublicKey: any(), using: dependencies))
                        }
                        .thenReturn(nil)
                    
                    expect {
                        try MessageReceiver.decryptWithSessionBlindingProtocol(
                            data: (
                                Data([0]) +
                                "TestMessage".data(using: .utf8)! +
                                Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!
                            ),
                            isOutgoing: true,
                            otherBlindedPublicKey: "15\(TestConstants.blindedPublicKey)",
                            with: TestConstants.serverPublicKey,
                            userEd25519KeyPair: KeyPair(
                                publicKey: Data.data(fromHex: TestConstants.edPublicKey)!.bytes,
                                secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                            ),
                            using: dependencies
                        )
                    }
                    .to(throwError(MessageReceiverError.invalidSignature))
                }
                
                // MARK: ---- throws an error if it cannot generate the combined key
                it("throws an error if it cannot generate the combined key") {
                    mockCrypto
                        .when { try $0.perform(.combineKeys(lhsKeyBytes: anyArray(), rhsKeyBytes: anyArray())) }
                        .thenReturn(nil)
                    
                    expect {
                        try MessageReceiver.decryptWithSessionBlindingProtocol(
                            data: (
                                Data([0]) +
                                "TestMessage".data(using: .utf8)! +
                                Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!
                            ),
                            isOutgoing: true,
                            otherBlindedPublicKey: "15\(TestConstants.blindedPublicKey)",
                            with: TestConstants.serverPublicKey,
                            userEd25519KeyPair: KeyPair(
                                publicKey: Data.data(fromHex: TestConstants.edPublicKey)!.bytes,
                                secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                            ),
                            using: dependencies
                        )
                    }
                    .to(throwError(MessageReceiverError.invalidSignature))
                }
                
                // MARK: ---- throws an error if the combined key does not match kA
                it("throws an error if the combined key does not match kA") {
                    mockCrypto
                        .when { try $0.perform(.combineKeys(lhsKeyBytes: anyArray(), rhsKeyBytes: anyArray())) }
                        .thenReturn(Data(hex: TestConstants.publicKey).bytes)
                    
                    expect {
                        try MessageReceiver.decryptWithSessionBlindingProtocol(
                            data: (
                                Data([0]) +
                                "TestMessage".data(using: .utf8)! +
                                Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!
                            ),
                            isOutgoing: true,
                            otherBlindedPublicKey: "15\(TestConstants.blindedPublicKey)",
                            with: TestConstants.serverPublicKey,
                            userEd25519KeyPair: KeyPair(
                                publicKey: Data.data(fromHex: TestConstants.edPublicKey)!.bytes,
                                secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                            ),
                            using: dependencies
                        )
                    }
                    .to(throwError(MessageReceiverError.invalidSignature))
                }
                
                // MARK: ---- throws an error if it cannot get the senders x25519 public key
                it("throws an error if it cannot get the senders x25519 public key") {
                    mockCrypto
                        .when { try $0.perform(.toX25519(ed25519PublicKey: anyArray())) }
                        .thenReturn(nil)
                    
                    expect {
                        try MessageReceiver.decryptWithSessionBlindingProtocol(
                            data: (
                                Data([0]) +
                                "TestMessage".data(using: .utf8)! +
                                Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!
                            ),
                            isOutgoing: true,
                            otherBlindedPublicKey: "15\(TestConstants.blindedPublicKey)",
                            with: TestConstants.serverPublicKey,
                            userEd25519KeyPair: KeyPair(
                                publicKey: Data.data(fromHex: TestConstants.edPublicKey)!.bytes,
                                secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                            ),
                            using: dependencies
                        )
                    }
                    .to(throwError(MessageReceiverError.decryptionFailed))
                }
            }
        }
    }
}
