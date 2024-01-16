// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

import Quick
import Nimble

@testable import SessionUtilitiesKit

class IdentitySpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrationTargets: [
                SNUtilitiesKit.self
            ],
            using: dependencies
        )
        
        // MARK: - an Identity
        describe("an Identity") {
            // MARK: -- correctly retrieves the user key pair
            it("correctly retrieves the user key pair") {
                mockStorage.write { db in
                    try Identity(variant: .x25519PublicKey, data: "Test3".data(using: .utf8)!).insert(db)
                    try Identity(variant: .x25519PrivateKey, data: "Test4".data(using: .utf8)!).insert(db)
                }
                
                mockStorage.read { db in
                    let keyPair = Identity.fetchUserKeyPair(db)
                    
                    expect(keyPair?.publicKey)
                        .to(equal("Test3".data(using: .utf8)?.bytes))
                    expect(keyPair?.secretKey)
                        .to(equal("Test4".data(using: .utf8)?.bytes))
                }
            }
            
            // MARK: -- correctly retrieves the user ED25519 key pair
            it("correctly retrieves the user ED25519 key pair") {
                mockStorage.write { db in
                    try Identity(variant: .ed25519PublicKey, data: "Test5".data(using: .utf8)!).insert(db)
                    try Identity(variant: .ed25519SecretKey, data: "Test6".data(using: .utf8)!).insert(db)
                }
                
                mockStorage.read { db in
                    let keyPair = Identity.fetchUserEd25519KeyPair(db)
                    
                    expect(keyPair?.publicKey)
                        .to(equal("Test5".data(using: .utf8)?.bytes))
                    expect(keyPair?.secretKey)
                        .to(equal("Test6".data(using: .utf8)?.bytes))
                }
            }
            
            // MARK: -- correctly determines if the user exists
            it("correctly determines if the user exists") {
                mockStorage.write { db in
                    try Identity(variant: .ed25519PublicKey, data: "Test3".data(using: .utf8)!).insert(db)
                    try Identity(variant: .ed25519SecretKey, data: "Test4".data(using: .utf8)!).insert(db)
                }
                
                mockStorage.read { db in
                    expect(Identity.userExists(db))
                        .to(equal(true))
                }
            }
        }
    }
}
