// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Sodium
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class MessageSenderEncryptionSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
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
        
        // MARK: - a MessageSender
        describe("a MessageSender") {
            // MARK: -- when encrypting with the session protocol
            context("when encrypting with the session protocol") {
                beforeEach {
                    mockCrypto
                        .when { try $0.perform(.seal(message: anyArray(), recipientPublicKey: anyArray())) }
                        .thenReturn([1, 2, 3])
                    mockCrypto
                        .when { try $0.perform(.signature(message: anyArray(), secretKey: anyArray())) }
                        .thenReturn([])
                }
                
                // MARK: ---- can encrypt correctly
                it("can encrypt correctly") {
                    let result: Data? = mockStorage.read { db in
                        try? MessageSender.encryptWithSessionProtocol(
                            db,
                            plaintext: "TestMessage".data(using: .utf8)!,
                            for: "05\(TestConstants.publicKey)",
                            using: Dependencies()   // Don't mock
                        )
                    }
                    
                    // Note: A Nonce is used for this so we can't compare the exact value when not mocked
                    expect(result).toNot(beNil())
                    expect(result?.count).to(equal(155))
                }
                
                // MARK: ---- returns the correct value when mocked
                it("returns the correct value when mocked") {
                    let result: Data? = mockStorage.read { db in
                        try? MessageSender.encryptWithSessionProtocol(
                            db,
                            plaintext: "TestMessage".data(using: .utf8)!,
                            for: "05\(TestConstants.publicKey)",
                            using: dependencies
                        )
                    }
                    
                    expect(result?.bytes).to(equal([1, 2, 3]))
                }
                
                // MARK: ---- throws an error if there is no ed25519 keyPair
                it("throws an error if there is no ed25519 keyPair") {
                    mockStorage.write { db in
                        _ = try Identity.filter(id: .ed25519PublicKey).deleteAll(db)
                        _ = try Identity.filter(id: .ed25519SecretKey).deleteAll(db)
                    }
                    
                    mockStorage.read { db in
                        expect {
                            try MessageSender.encryptWithSessionProtocol(
                                db,
                                plaintext: "TestMessage".data(using: .utf8)!,
                                for: "05\(TestConstants.publicKey)",
                                using: dependencies
                            )
                        }
                        .to(throwError(MessageSenderError.noUserED25519KeyPair))
                    }
                }
                
                // MARK: ---- throws an error if the signature generation fails
                it("throws an error if the signature generation fails") {
                    mockCrypto
                        .when { try $0.perform(.signature(message: anyArray(), secretKey: anyArray())) }
                        .thenReturn(nil)
                    
                    mockStorage.read { db in
                        expect {
                            try MessageSender.encryptWithSessionProtocol(
                                db,
                                plaintext: "TestMessage".data(using: .utf8)!,
                                for: "05\(TestConstants.publicKey)",
                                using: dependencies
                            )
                        }
                        .to(throwError(MessageSenderError.signingFailed))
                    }
                }
                
                // MARK: ---- throws an error if the encryption fails
                it("throws an error if the encryption fails") {
                    mockCrypto
                        .when { try $0.perform(.seal(message: anyArray(), recipientPublicKey: anyArray())) }
                        .thenReturn(nil)
                    
                    mockStorage.read { db in
                        expect {
                            try MessageSender.encryptWithSessionProtocol(
                                db,
                                plaintext: "TestMessage".data(using: .utf8)!,
                                for: "05\(TestConstants.publicKey)",
                                using: dependencies
                            )
                        }
                        .to(throwError(MessageSenderError.encryptionFailed))
                    }
                }
            }
            
            // MARK: -- when encrypting with the blinded session protocol
            context("when encrypting with the blinded session protocol") {
                beforeEach {
                    mockCrypto
                        .when { [dependencies = dependencies!] crypto in
                            crypto.generate(.blindedKeyPair(serverPublicKey: any(), edKeyPair: any(), using: dependencies))
                        }
                        .thenReturn(
                            KeyPair(
                                publicKey: Data.data(fromHex: TestConstants.publicKey)!.bytes,
                                secretKey: Data.data(fromHex: TestConstants.edSecretKey)!.bytes
                            )
                        )
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
                        .thenReturn([1, 2, 3])
                    mockCrypto
                        .when { [dependencies = dependencies!] crypto in
                            try crypto.perform(
                                .encryptAeadXChaCha20(
                                    message: anyArray(),
                                    secretKey: anyArray(),
                                    nonce: anyArray(),
                                    additionalData: anyArray(),
                                    using: dependencies
                                )
                            )
                        }
                        .thenReturn([2, 3, 4])
                }
                
                // MARK: ---- can encrypt correctly
                it("can encrypt correctly") {
                    let result: Data? = mockStorage.read { db in
                        try? MessageSender.encryptWithSessionBlindingProtocol(
                            db,
                            plaintext: "TestMessage".data(using: .utf8)!,
                            for: "15\(TestConstants.blindedPublicKey)",
                            openGroupPublicKey: TestConstants.serverPublicKey,
                            using: Dependencies()   // Don't mock
                        )
                    }
                    
                    // Note: A Nonce is used for this so we can't compare the exact value when not mocked
                    expect(result).toNot(beNil())
                    expect(result?.count).to(equal(84))
                }
                
                // MARK: ---- returns the correct value when mocked
                it("returns the correct value when mocked") {
                    let result: Data? = mockStorage.read { db in
                        try? MessageSender.encryptWithSessionBlindingProtocol(
                            db,
                            plaintext: "TestMessage".data(using: .utf8)!,
                            for: "15\(TestConstants.blindedPublicKey)",
                            openGroupPublicKey: TestConstants.serverPublicKey,
                            using: dependencies
                        )
                    }
                    
                    expect(result?.toHexString())
                        .to(equal("00020304a5b4d48b3ade4f4b2a2764762e5a2c7900f254bd91633b43"))
                }
                
                // MARK: ---- includes a version at the start of the encrypted value
                it("includes a version at the start of the encrypted value") {
                    let result: Data? = mockStorage.read { db in
                        try? MessageSender.encryptWithSessionBlindingProtocol(
                            db,
                            plaintext: "TestMessage".data(using: .utf8)!,
                            for: "15\(TestConstants.blindedPublicKey)",
                            openGroupPublicKey: TestConstants.serverPublicKey,
                            using: dependencies
                        )
                    }
                    
                    expect(result?.toHexString().prefix(2)).to(equal("00"))
                }
                
                // MARK: ---- includes the nonce at the end of the encrypted value
                it("includes the nonce at the end of the encrypted value") {
                    let maybeResult: Data? = mockStorage.read { db in
                        try? MessageSender.encryptWithSessionBlindingProtocol(
                            db,
                            plaintext: "TestMessage".data(using: .utf8)!,
                            for: "15\(TestConstants.blindedPublicKey)",
                            openGroupPublicKey: TestConstants.serverPublicKey,
                            using: dependencies
                        )
                    }
                    let result: [UInt8] = (maybeResult?.bytes ?? [])
                    let nonceBytes: [UInt8] = Array(result[max(0, (result.count - 24))..<result.count])
                    
                    expect(Data(nonceBytes).base64EncodedString())
                        .to(equal("pbTUizreT0sqJ2R2LloseQDyVL2RYztD"))
                }
                
                // MARK: ---- throws an error if the recipient isn't a blinded id
                it("throws an error if the recipient isn't a blinded id") {
                    mockStorage.read { db in
                        expect {
                            try MessageSender.encryptWithSessionBlindingProtocol(
                                db,
                                plaintext: "TestMessage".data(using: .utf8)!,
                                for: "05\(TestConstants.publicKey)",
                                openGroupPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        }
                        .to(throwError(MessageSenderError.signingFailed))
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
                            try MessageSender.encryptWithSessionBlindingProtocol(
                                db,
                                plaintext: "TestMessage".data(using: .utf8)!,
                                for: "15\(TestConstants.blindedPublicKey)",
                                openGroupPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        }
                        .to(throwError(MessageSenderError.noUserED25519KeyPair))
                    }
                }
                
                // MARK: ---- throws an error if it fails to generate a blinded keyPair
                it("throws an error if it fails to generate a blinded keyPair") {
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
                    
                    mockStorage.read { db in
                        expect {
                            try MessageSender.encryptWithSessionBlindingProtocol(
                                db,
                                plaintext: "TestMessage".data(using: .utf8)!,
                                for: "15\(TestConstants.blindedPublicKey)",
                                openGroupPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        }
                        .to(throwError(MessageSenderError.signingFailed))
                    }
                }
                
                // MARK: ---- throws an error if it fails to generate an encryption key
                it("throws an error if it fails to generate an encryption key") {
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
                    
                    mockStorage.read { db in
                        expect {
                            try MessageSender.encryptWithSessionBlindingProtocol(
                                db,
                                plaintext: "TestMessage".data(using: .utf8)!,
                                for: "15\(TestConstants.blindedPublicKey)",
                                openGroupPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        }
                        .to(throwError(MessageSenderError.signingFailed))
                    }
                }
                
                // MARK: ---- throws an error if it fails to encrypt
                it("throws an error if it fails to encrypt") {
                    mockCrypto
                        .when {
                            try $0.perform(
                                .encryptAeadXChaCha20(
                                    message: anyArray(),
                                    secretKey: anyArray(),
                                    nonce: anyArray(),
                                    additionalData: anyArray(),
                                    using: dependencies
                                )
                            )
                        }
                        .thenReturn(nil)
                    
                    mockStorage.read { db in
                        expect {
                            try MessageSender.encryptWithSessionBlindingProtocol(
                                db,
                                plaintext: "TestMessage".data(using: .utf8)!,
                                for: "15\(TestConstants.blindedPublicKey)",
                                openGroupPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        }
                        .to(throwError(MessageSenderError.encryptionFailed))
                    }
                }
            }
        }
    }
}
