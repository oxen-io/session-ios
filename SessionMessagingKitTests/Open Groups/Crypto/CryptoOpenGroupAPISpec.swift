// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class CryptoOpenGroupAPISpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrationTargets: [
                SNUtilitiesKit.self,
                SNMessagingKit.self
            ],
            using: dependencies,
            initialData: { db in
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
            }
        )
        @TestState(singleton: .crypto, in: dependencies) var crypto: Crypto! = Crypto()
        
        // MARK: - Crypto for OpenGroupAPI
        describe("Crypto for OpenGroupAPI") {
            // MARK: -- when generating a blinded15 key pair
            context("when generating a blinded15 key pair") {
                // MARK: ---- successfully generates
                it("successfully generates") {
                    let result = crypto.generate(
                        .blinded15KeyPair(
                            serverPublicKey: TestConstants.serverPublicKey,
                            ed25519SecretKey: Data(hex: TestConstants.edSecretKey).bytes
                        )
                    )
                    
                    // Note: The first 64 characters of the secretKey are consistent but the chars after that always differ
                    expect(result?.publicKey.toHexString()).to(equal(TestConstants.blind15PublicKey))
                    expect(result?.secretKey.toHexString()).to(equal(TestConstants.blind15SecretKey))
                }
                
                // MARK: ---- fails if the edKeyPair secret key length wrong
                it("fails if the ed25519SecretKey length wrong") {
                    let result = crypto.generate(
                        .blinded15KeyPair(
                            serverPublicKey: TestConstants.serverPublicKey,
                            ed25519SecretKey: Array(Data(hex: String(TestConstants.edSecretKey.prefix(4))))
                        )
                    )
                    
                    expect(result).to(beNil())
                }
            }
            
            // MARK: -- when generating a blinded25 key pair
            context("when generating a blinded25 key pair") {
                // MARK: ---- successfully generates
                it("successfully generates") {
                    let result = crypto.generate(
                        .blinded25KeyPair(
                            serverPublicKey: TestConstants.serverPublicKey,
                            ed25519SecretKey: Data(hex: TestConstants.edSecretKey).bytes
                        )
                    )
                    
                    // Note: The first 64 characters of the secretKey are consistent but the chars after that always differ
                    expect(result?.publicKey.toHexString()).to(equal(TestConstants.blind25PublicKey))
                    expect(result?.secretKey.toHexString()).to(equal(TestConstants.blind25SecretKey))
                }
                
                // MARK: ---- fails if the edKeyPair secret key length wrong
                it("fails if the ed25519SecretKey length wrong") {
                    let result = crypto.generate(
                        .blinded25KeyPair(
                            serverPublicKey: TestConstants.serverPublicKey,
                            ed25519SecretKey: Data(hex: String(TestConstants.edSecretKey.prefix(4))).bytes
                        )
                    )
                    
                    expect(result).to(beNil())
                }
            }
            
            // MARK: -- when generating a signatureBlind15
            context("when generating a signatureBlind15") {
                // MARK: ---- generates a correct signature
                it("generates a correct signature") {
                    let result = crypto.generate(
                        .signatureBlind15(
                            message: "TestMessage".bytes,
                            serverPublicKey: TestConstants.serverPublicKey,
                            ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey))
                        )
                    )
                    
                    expect(result?.toHexString())
                        .to(equal(
                            "245003f1627ebdfc6099c32597d426ef84d1b301861a5ffbbac92dde6c608334" +
                            "ceb56a022a094a9a664fae034b50eed40bd1bfb262c7e542c979eec265ae3f07"
                        ))
                }
            }
            
            // MARK: -- when generating a signatureBlind25
            context("when generating a signatureBlind25") {
                // MARK: ---- generates a correct signature
                it("generates a correct signature") {
                    let result = crypto.generate(
                        .signatureBlind25(
                            message: "TestMessage".bytes,
                            serverPublicKey: TestConstants.serverPublicKey,
                            ed25519SecretKey: Data(hex: TestConstants.edSecretKey).bytes
                        )
                    )
                    
                    expect(result?.toHexString())
                        .to(equal(
                            "9ff9b7fb7d435c7a2c0b0b2ae64963baaf394386b9f7c7f924eeac44ec0f74c7" +
                            "fe6304c73a9b3a65491f81e44b545e54631e83e9a412eaed5fd4db2e05ec830c"
                        ))
                }
            }
            
            // MARK: -- when checking if a session id matches a blinded id
            context("when checking if a session id matches a blinded id") {
                // MARK: ---- returns true when a blind15 id matches
                it("returns true when a blind15 id matches") {
                    let result = crypto.verify(
                        .sessionId(
                            "05\(TestConstants.publicKey)",
                            matchesBlindedId: "15\(TestConstants.blind15PublicKey)",
                            serverPublicKey: TestConstants.serverPublicKey
                        )
                    )
                    
                    expect(result).to(beTrue())
                }
                
                // MARK: ---- returns true when a blind25 id matches
                it("returns true when a blind25 id matches") {
                    let result = crypto.verify(
                        .sessionId(
                            "05\(TestConstants.publicKey)",
                            matchesBlindedId: "25\(TestConstants.blind25PublicKey)",
                            serverPublicKey: TestConstants.serverPublicKey
                        )
                    )
                    
                    expect(result).to(beTrue())
                }
                
                // MARK: ---- returns false if given an invalid session id
                it("returns false if given an invalid session id") {
                    let result = crypto.verify(
                        .sessionId(
                            "AB\(TestConstants.publicKey)",
                            matchesBlindedId: "15\(TestConstants.blind15PublicKey)",
                            serverPublicKey: TestConstants.serverPublicKey
                        )
                    )
                    
                    expect(result).to(beFalse())
                }
                
                // MARK: ---- returns false if given an invalid blinded id
                it("returns false if given an invalid blinded id") {
                    let result = crypto.verify(
                        .sessionId(
                            "05\(TestConstants.publicKey)",
                            matchesBlindedId: "AB\(TestConstants.blind15PublicKey)",
                            serverPublicKey: TestConstants.serverPublicKey
                        )
                    )
                    
                    expect(result).to(beFalse())
                }
            }
            
            // MARK: -- when encrypting with the session blinding protocol
            context("when encrypting with the session blinding protocol") {
                // MARK: ---- can encrypt for a blind15 recipient correctly
                it("can encrypt for a blind15 recipient correctly") {
                    let result: Data? = mockStorage.read { db in
                        try crypto.tryGenerate(
                            .ciphertextWithSessionBlindingProtocol(
                                db,
                                plaintext: "TestMessage".data(using: .utf8)!,
                                recipientBlindedId: "15\(TestConstants.blind15PublicKey)",
                                serverPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        )
                    }
                    
                    // Note: A Nonce is used for this so we can't compare the exact value when not mocked
                    expect(result).toNot(beNil())
                    expect(result?.count).to(equal(84))
                }
                
                // MARK: ---- can encrypt for a blind25 recipient correctly
                it("can encrypt for a blind25 recipient correctly") {
                    let result: Data? = mockStorage.read { db in
                        try crypto.tryGenerate(
                            .ciphertextWithSessionBlindingProtocol(
                                db,
                                plaintext: "TestMessage".data(using: .utf8)!,
                                recipientBlindedId: "25\(TestConstants.blind25PublicKey)",
                                serverPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        )
                    }
                    
                    // Note: A Nonce is used for this so we can't compare the exact value when not mocked
                    expect(result).toNot(beNil())
                    expect(result?.count).to(equal(84))
                }
                
                // MARK: ---- includes a version at the start of the encrypted value
                it("includes a version at the start of the encrypted value") {
                    let result: Data? = mockStorage.read { db in
                        try crypto.tryGenerate(
                            .ciphertextWithSessionBlindingProtocol(
                                db,
                                plaintext: "TestMessage".data(using: .utf8)!,
                                recipientBlindedId: "15\(TestConstants.blind15PublicKey)",
                                serverPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        )
                    }
                    
                    expect(result?.toHexString().prefix(2)).to(equal("00"))
                }
                
                // MARK: ---- throws an error if the recipient isn't a blinded id
                it("throws an error if the recipient isn't a blinded id") {
                    mockStorage.read { db in
                        expect {
                            try crypto.tryGenerate(
                                .ciphertextWithSessionBlindingProtocol(
                                    db,
                                    plaintext: "TestMessage".data(using: .utf8)!,
                                    recipientBlindedId: "05\(TestConstants.publicKey)",
                                    serverPublicKey: TestConstants.serverPublicKey,
                                    using: dependencies
                                )
                            )
                        }
                        .to(throwError(MessageSenderError.encryptionFailed))
                    }
                }
                
                // MARK: ---- throws an error if there is no ed25519 keyPair
                it("throws an error if there is no ed25519 keyPair") {
                    mockStorage.write { db in
                        _ = try Identity.filter(id: .ed25519PublicKey).deleteAll(db)
                        _ = try Identity.filter(id: .ed25519SecretKey).deleteAll(db)
                    }
                    
                    mockStorage.read { db in
                        expect {
                            try crypto.tryGenerate(
                                .ciphertextWithSessionBlindingProtocol(
                                    db,
                                    plaintext: "TestMessage".data(using: .utf8)!,
                                    recipientBlindedId: "15\(TestConstants.blind15PublicKey)",
                                    serverPublicKey: TestConstants.serverPublicKey,
                                    using: dependencies
                                )
                            )
                        }
                        .to(throwError(MessageSenderError.noUserED25519KeyPair))
                    }
                }
            }
            
            // MARK: -- when decrypting with the session blinding protocol
            context("when decrypting with the session blinding protocol") {
                // MARK: ---- can decrypt a blind15 message correctly
                it("can decrypt a blind15 message correctly") {
                    let result = mockStorage.read { db in
                        try crypto.tryGenerate(
                            .plaintextWithSessionBlindingProtocol(
                                db,
                                ciphertext: Data(
                                    base64Encoded: "AMuM6E07xyYzN1/gP64v9TelMjkylHsFZznTzE7rDIykIHBHKbdkLnXo4Q1iVWdD" +
                                    "ct9F9YqIsRsqmdLl1t6nfQtWoiUSkjBChvg3J61f7rpS3/A+"
                                )!,
                                senderId: "15\(TestConstants.blind15PublicKey)",
                                recipientId: "15\(TestConstants.blind15PublicKey)",
                                serverPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        )
                    }
                    
                    expect(String(data: (result?.plaintext ?? Data()), encoding: .utf8)).to(equal("TestMessage"))
                    expect(result?.senderSessionIdHex).to(equal("05\(TestConstants.publicKey)"))
                }
                
                // MARK: ---- can decrypt a blind25 message correctly
                it("can decrypt a blind25 message correctly") {
                    let result = mockStorage.read { db in
                        try crypto.tryGenerate(
                            .plaintextWithSessionBlindingProtocol(
                                db,
                                ciphertext: Data(
                                    base64Encoded: "AMmaZncBPI7EqWW1eTg6QoZtPW255IXy+M4uoh33ZgQdJb7gmsU7wJ+wEhgNDOd6" +
                                    "4E822uYinFpZCLK81t6nfQtWoiUSkjBChvg3J61f7rpS3/A+"
                                )!,
                                senderId: "25\(TestConstants.blind25PublicKey)",
                                recipientId: "25\(TestConstants.blind25PublicKey)",
                                serverPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        )
                    }
                    
                    expect(String(data: (result?.plaintext ?? Data()), encoding: .utf8)).to(equal("TestMessage"))
                    expect(result?.senderSessionIdHex).to(equal("05\(TestConstants.publicKey)"))
                }
                
                // MARK: ---- throws an error if there is no ed25519 keyPair
                it("throws an error if there is no ed25519 keyPair") {
                    mockStorage.write { db in
                        _ = try Identity.filter(id: .ed25519PublicKey).deleteAll(db)
                        _ = try Identity.filter(id: .ed25519SecretKey).deleteAll(db)
                    }
                    
                    mockStorage.read { db in
                        expect {
                            try crypto.tryGenerate(
                                .plaintextWithSessionBlindingProtocol(
                                    db,
                                    ciphertext: Data(
                                        base64Encoded: "SRP0eBUWh4ez6ppWjUs5/Wph5fhnPRgB5zsWWnTz+FBAw/YI3oS2pDpIfyetMTbU" +
                                        "sFMhE5G4PbRtQFey1hsxLl221Qivc3ayaX2Mm/X89Dl8e45BC+Lb/KU9EdesxIK4pVgYXs9XrMtX3v8" +
                                        "dt0eBaXneOBfr7qB8pHwwMZjtkOu1ED07T9nszgbWabBphUfWXe2U9K3PTRisSCI="
                                    )!,
                                    senderId: "25\(TestConstants.blind25PublicKey)",
                                    recipientId: "25\(TestConstants.blind25PublicKey)",
                                    serverPublicKey: TestConstants.serverPublicKey,
                                    using: dependencies
                                )
                            )
                        }
                        .to(throwError(MessageSenderError.noUserED25519KeyPair))
                    }
                }
                
                // MARK: ---- throws an error if the data is too short
                it("throws an error if the data is too short") {
                    mockStorage.read { db in
                        expect {
                            try crypto.tryGenerate(
                                .plaintextWithSessionBlindingProtocol(
                                    db,
                                    ciphertext: Data([1, 2, 3]),
                                    senderId: "15\(TestConstants.blind15PublicKey)",
                                    recipientId: "15\(TestConstants.blind15PublicKey)",
                                    serverPublicKey: TestConstants.serverPublicKey,
                                    using: dependencies
                                )
                            )
                        }
                        .to(throwError(MessageReceiverError.decryptionFailed))
                    }
                }
                
                // MARK: ---- throws an error if the data version is not 0
                it("throws an error if the data version is not 0") {
                    mockStorage.read { db in
                        expect {
                            try crypto.tryGenerate(
                                .plaintextWithSessionBlindingProtocol(
                                    db,
                                    ciphertext: (
                                        Data([1]) +
                                        "TestMessage".data(using: .utf8)! +
                                        Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!
                                    ),
                                    senderId: "15\(TestConstants.blind15PublicKey)",
                                    recipientId: "15\(TestConstants.blind15PublicKey)",
                                    serverPublicKey: TestConstants.serverPublicKey,
                                    using: dependencies
                                )
                            )
                        }
                        .to(throwError(MessageReceiverError.decryptionFailed))
                    }
                }
                
                // MARK: ---- throws an error if it cannot decrypt the data
                it("throws an error if it cannot decrypt the data") {
                    mockStorage.read { db in
                        expect {
                            try crypto.tryGenerate(
                                .plaintextWithSessionBlindingProtocol(
                                    db,
                                    ciphertext: "RandomData".data(using: .utf8)!,
                                    senderId: "25\(TestConstants.blind25PublicKey)",
                                    recipientId: "25\(TestConstants.blind25PublicKey)",
                                    serverPublicKey: TestConstants.serverPublicKey,
                                    using: dependencies
                                )
                            )
                        }
                        .to(throwError(MessageReceiverError.decryptionFailed))
                    }
                }
                
                // MARK: ---- throws an error if the inner bytes are too short
                it("throws an error if the inner bytes are too short") {
                    mockStorage.read { db in
                        expect {
                            try crypto.tryGenerate(
                                .plaintextWithSessionBlindingProtocol(
                                    db,
                                    ciphertext: (
                                        Data([0]) +
                                        "TestMessage".data(using: .utf8)! +
                                        Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!
                                    ),
                                    senderId: "15\(TestConstants.blind15PublicKey)",
                                    recipientId: "15\(TestConstants.blind15PublicKey)",
                                    serverPublicKey: TestConstants.serverPublicKey,
                                    using: dependencies
                                )
                            )
                        }
                        .to(throwError(MessageReceiverError.decryptionFailed))
                    }
                }
            }
        }
    }
}
