// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class MessageSenderSpec: QuickSpec {
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
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto
                    .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                    .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
                crypto
                    .when { $0.generate(.randomBytes(24)) }
                    .thenReturn(Array(Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!))
            }
        )
        
        // MARK: - a MessageSender
        describe("a MessageSender") {
            // MARK: -- when preparing to send to a contact
            context("when preparing to send to a contact") {
                beforeEach {
                    mockCrypto
                        .when {
                            $0.generate(.ciphertextWithSessionProtocol(.any, plaintext: .any, destination: .any, using: .any))
                        }
                        .thenReturn(Data([1, 2, 3]))
                    mockCrypto
                        .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                        .thenReturn(Authentication.Signature.standard(signature: []))
                }
                
                // MARK: ---- can encrypt correctly
                it("can encrypt correctly") {
                    let result: HTTP.PreparedRequest<Void>? = mockStorage.read { db in
                        try? MessageSender.preparedSend(
                            db,
                            message: VisibleMessage(
                                text: "TestMessage"
                            ),
                            to: .contact(publicKey: "05\(TestConstants.publicKey)"),
                            namespace: .default,
                            interactionId: nil,
                            fileIds: [],
                            isSyncMessage: false,
                            using: dependencies
                        )
                    }
                    
                    expect(result).toNot(beNil())
//                    expect(result?.count).to(equal(155))
                }
                
//                // MARK: ---- throws an error if there is no ed25519 keyPair
//                it("throws an error if there is no ed25519 keyPair") {
//                    mockStorage.write { db in
//                        _ = try Identity.filter(id: .ed25519PublicKey).deleteAll(db)
//                        _ = try Identity.filter(id: .ed25519SecretKey).deleteAll(db)
//                    }
//                    
//                    mockStorage.read { db in
//                        expect {
//                            try MessageSender.encryptWithSessionProtocol(
//                                db,
//                                plaintext: "TestMessage".data(using: .utf8)!,
//                                for: "05\(TestConstants.publicKey)",
//                                using: dependencies
//                            )
//                        }
//                        .to(throwError(MessageSenderError.noUserED25519KeyPair))
//                    }
//                }
//                
//                // MARK: ---- throws an error if the signature generation fails
//                it("throws an error if the signature generation fails") {
//                    mockCrypto
//                        .when { $0.generate(.signature(message: .any, secretKey: .any)) }
//                        .thenReturn(nil)
//                    
//                    mockStorage.read { db in
//                        expect {
//                            try MessageSender.encryptWithSessionProtocol(
//                                db,
//                                plaintext: "TestMessage".data(using: .utf8)!,
//                                for: "05\(TestConstants.publicKey)",
//                                using: dependencies
//                            )
//                        }
//                        .to(throwError(MessageSenderError.signingFailed))
//                    }
//                }
//                
//                // MARK: ---- throws an error if the encryption fails
//                it("throws an error if the encryption fails") {
//                    mockCrypto
//                        .when { $0.generate(.sealedBytes(message: .any, recipientPublicKey: .any)) }
//                        .thenReturn(nil)
//                    
//                    mockStorage.read { db in
//                        expect {
//                            try MessageSender.encryptWithSessionProtocol(
//                                db,
//                                plaintext: "TestMessage".data(using: .utf8)!,
//                                for: "05\(TestConstants.publicKey)",
//                                using: dependencies
//                            )
//                        }
//                        .to(throwError(MessageSenderError.encryptionFailed))
//                    }
//                }
            }
            
//            // MARK: -- when encrypting with the blinded session protocol
//            context("when encrypting with the blinded session protocol") {
//                beforeEach {
//                    mockCrypto
//                        .when { $0.generate(.blindedKeyPair(serverPublicKey: .any, edKeyPair: .any, using: .any)) }
//                        .thenReturn(
//                            KeyPair(
//                                publicKey: Data(hex: TestConstants.publicKey).bytes,
//                                secretKey: Data(hex: TestConstants.edSecretKey).bytes
//                            )
//                        )
//                    mockCrypto
//                        .when {
//                            $0.generate(
//                                .sharedBlindedEncryptionKey(
//                                    secretKey: .any,
//                                    otherBlindedPublicKey: .any,
//                                    fromBlindedPublicKey: .any,
//                                    toBlindedPublicKey: .any,
//                                    using: .any
//                                )
//                            )
//                        }
//                        .thenReturn([1, 2, 3])
//                    mockCrypto
//                        .when {
//                            $0.generate(
//                                .encryptedBytesAeadXChaCha20(
//                                    message: .any,
//                                    secretKey: .any,
//                                    nonce: .any,
//                                    additionalData: .any,
//                                    using: .any
//                                )
//                            )
//                        }
//                        .thenReturn([2, 3, 4])
//                }
//                
//                // MARK: ---- can encrypt correctly
//                it("can encrypt correctly") {
//                    let result: Data? = mockStorage.read { db in
//                        try? MessageSender.encryptWithSessionBlindingProtocol(
//                            db,
//                            plaintext: "TestMessage".data(using: .utf8)!,
//                            for: "15\(TestConstants.blindedPublicKey)",
//                            openGroupPublicKey: TestConstants.serverPublicKey,
//                            using: Dependencies()   // Don't mock
//                        )
//                    }
//                    
//                    // Note: A Nonce is used for this so we can't compare the exact value when not mocked
//                    expect(result).toNot(beNil())
//                    expect(result?.count).to(equal(84))
//                }
//                
//                // MARK: ---- returns the correct value when mocked
//                it("returns the correct value when mocked") {
//                    let result: Data? = mockStorage.read { db in
//                        try? MessageSender.encryptWithSessionBlindingProtocol(
//                            db,
//                            plaintext: "TestMessage".data(using: .utf8)!,
//                            for: "15\(TestConstants.blindedPublicKey)",
//                            openGroupPublicKey: TestConstants.serverPublicKey,
//                            using: dependencies
//                        )
//                    }
//                    
//                    expect(result?.toHexString())
//                        .to(equal("00020304a5b4d48b3ade4f4b2a2764762e5a2c7900f254bd91633b43"))
//                }
//                
//                // MARK: ---- includes a version at the start of the encrypted value
//                it("includes a version at the start of the encrypted value") {
//                    let result: Data? = mockStorage.read { db in
//                        try? MessageSender.encryptWithSessionBlindingProtocol(
//                            db,
//                            plaintext: "TestMessage".data(using: .utf8)!,
//                            for: "15\(TestConstants.blindedPublicKey)",
//                            openGroupPublicKey: TestConstants.serverPublicKey,
//                            using: dependencies
//                        )
//                    }
//                    
//                    expect(result?.toHexString().prefix(2)).to(equal("00"))
//                }
//                
//                // MARK: ---- includes the nonce at the end of the encrypted value
//                it("includes the nonce at the end of the encrypted value") {
//                    let maybeResult: Data? = mockStorage.read { db in
//                        try? MessageSender.encryptWithSessionBlindingProtocol(
//                            db,
//                            plaintext: "TestMessage".data(using: .utf8)!,
//                            for: "15\(TestConstants.blindedPublicKey)",
//                            openGroupPublicKey: TestConstants.serverPublicKey,
//                            using: dependencies
//                        )
//                    }
//                    let result: [UInt8] = (maybeResult?.bytes ?? [])
//                    let nonceBytes: [UInt8] = Array(result[max(0, (result.count - 24))..<result.count])
//                    
//                    expect(Data(nonceBytes).base64EncodedString())
//                        .to(equal("pbTUizreT0sqJ2R2LloseQDyVL2RYztD"))
//                }
//                
//                // MARK: ---- throws an error if the recipient isn't a blinded id
//                it("throws an error if the recipient isn't a blinded id") {
//                    mockStorage.read { db in
//                        expect {
//                            try MessageSender.encryptWithSessionBlindingProtocol(
//                                db,
//                                plaintext: "TestMessage".data(using: .utf8)!,
//                                for: "05\(TestConstants.publicKey)",
//                                openGroupPublicKey: TestConstants.serverPublicKey,
//                                using: dependencies
//                            )
//                        }
//                        .to(throwError(MessageSenderError.signingFailed))
//                    }
//                }
//                
//                // MARK: ---- throws an error if there is no ed25519 keyPair
//                it("throws an error if there is no ed25519 keyPair") {
//                    mockStorage.write { db in
//                        _ = try Identity.filter(id: .ed25519PublicKey).deleteAll(db)
//                        _ = try Identity.filter(id: .ed25519SecretKey).deleteAll(db)
//                    }
//                    
//                    mockStorage.read { db in
//                        expect {
//                            try MessageSender.encryptWithSessionBlindingProtocol(
//                                db,
//                                plaintext: "TestMessage".data(using: .utf8)!,
//                                for: "15\(TestConstants.blindedPublicKey)",
//                                openGroupPublicKey: TestConstants.serverPublicKey,
//                                using: dependencies
//                            )
//                        }
//                        .to(throwError(MessageSenderError.noUserED25519KeyPair))
//                    }
//                }
//                
//                // MARK: ---- throws an error if it fails to generate a blinded keyPair
//                it("throws an error if it fails to generate a blinded keyPair") {
//                    mockCrypto
//                        .when { $0.generate(.blindedKeyPair(serverPublicKey: .any, edKeyPair: .any, using: .any)) }
//                        .thenReturn(nil)
//                    
//                    mockStorage.read { db in
//                        expect {
//                            try MessageSender.encryptWithSessionBlindingProtocol(
//                                db,
//                                plaintext: "TestMessage".data(using: .utf8)!,
//                                for: "15\(TestConstants.blindedPublicKey)",
//                                openGroupPublicKey: TestConstants.serverPublicKey,
//                                using: dependencies
//                            )
//                        }
//                        .to(throwError(MessageSenderError.signingFailed))
//                    }
//                }
//                
//                // MARK: ---- throws an error if it fails to generate an encryption key
//                it("throws an error if it fails to generate an encryption key") {
//                    mockCrypto
//                        .when {
//                            $0.generate(
//                                .sharedBlindedEncryptionKey(
//                                    secretKey: .any,
//                                    otherBlindedPublicKey: .any,
//                                    fromBlindedPublicKey: .any,
//                                    toBlindedPublicKey: .any,
//                                    using: .any
//                                )
//                            )
//                        }
//                        .thenReturn(nil)
//                    
//                    mockStorage.read { db in
//                        expect {
//                            try MessageSender.encryptWithSessionBlindingProtocol(
//                                db,
//                                plaintext: "TestMessage".data(using: .utf8)!,
//                                for: "15\(TestConstants.blindedPublicKey)",
//                                openGroupPublicKey: TestConstants.serverPublicKey,
//                                using: dependencies
//                            )
//                        }
//                        .to(throwError(MessageSenderError.signingFailed))
//                    }
//                }
//                
//                // MARK: ---- throws an error if it fails to encrypt
//                it("throws an error if it fails to encrypt") {
//                    mockCrypto
//                        .when {
//                            $0.generate(
//                                .encryptedBytesAeadXChaCha20(
//                                    message: .any,
//                                    secretKey: .any,
//                                    nonce: .any,
//                                    additionalData: .any,
//                                    using: dependencies
//                                )
//                            )
//                        }
//                        .thenReturn(nil)
//                    
//                    mockStorage.read { db in
//                        expect {
//                            try MessageSender.encryptWithSessionBlindingProtocol(
//                                db,
//                                plaintext: "TestMessage".data(using: .utf8)!,
//                                for: "15\(TestConstants.blindedPublicKey)",
//                                openGroupPublicKey: TestConstants.serverPublicKey,
//                                using: dependencies
//                            )
//                        }
//                        .to(throwError(MessageSenderError.encryptionFailed))
//                    }
//                }
//            }
        }
    }
}
