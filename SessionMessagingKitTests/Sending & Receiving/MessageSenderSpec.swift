// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
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
                    let result: Network.PreparedRequest<Void>? = mockStorage.read { db in
                        try? MessageSender.preparedSend(
                            db,
                            message: VisibleMessage(
                                text: "TestMessage"
                            ),
                            to: .contact(publicKey: "05\(TestConstants.publicKey)"),
                            namespace: .default,
                            interactionId: nil,
                            fileIds: [],
                            using: dependencies
                        )
                    }
                    
                    expect(result).toNot(beNil())
                }
            }
        }
    }
}
