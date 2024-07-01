// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionUtilitiesKit

class SessionIdSpec: QuickSpec {
    override class func spec() {
        // MARK: - a SessionId
        describe("a SessionId") {
            // MARK: -- when initializing
            context("when initializing") {
                // MARK: ---- with an idString
                context("with an idString") {
                    // MARK: ------ succeeds when correct
                    it("succeeds when correct") {
                        let sessionId: SessionId? = try? SessionId(from: "05\(TestConstants.publicKey)")
                        
                        expect(sessionId?.prefix).to(equal(.standard))
                        expect(sessionId?.hexString).to(equal("05\(TestConstants.publicKey)"))
                    }
                    
                    // MARK: ------ fails when too short
                    it("fails when too short") {
                        expect(try SessionId(from: "")).to(throwError(SessionIdError.invalidSessionId))
                    }
                    
                    // MARK: ------ fails with an invalid prefix
                    it("fails with an invalid prefix") {
                        expect(try SessionId(from: "AB\(TestConstants.publicKey)"))
                            .to(throwError(SessionIdError.invalidPrefix))
                    }
                }
                
                // MARK: ---- with a prefix and publicKey
                context("with a prefix and publicKey") {
                    // MARK: ------ converts the bytes into a hex string
                    it("converts the bytes into a hex string") {
                        let sessionId: SessionId? = SessionId(.standard, publicKey: [0, 1, 2, 3, 4, 5, 6, 7, 8])
                        
                        expect(sessionId?.prefix).to(equal(.standard))
                        expect(sessionId?.hexString).to(equal("05000102030405060708"))
                    }
                }
            }
            
            // MARK: -- generates the correct hex string
            it("generates the correct hex string") {
                expect(SessionId(.unblinded, publicKey: Data(hex: TestConstants.publicKey).bytes).hexString)
                    .to(equal("0088672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
                expect(SessionId(.standard, publicKey: Data(hex: TestConstants.publicKey).bytes).hexString)
                    .to(equal("0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
                expect(SessionId(.blinded15, publicKey: Data(hex: TestConstants.publicKey).bytes).hexString)
                    .to(equal("1588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
                expect(SessionId(.blinded25, publicKey: Data(hex: TestConstants.publicKey).bytes).hexString)
                    .to(equal("2588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
            }
        }
        
        // MARK: - a SessionId Prefix
        describe("a SessionId Prefix") {
            // MARK: -- when initializing
            context("when initializing") {
                // MARK: ---- with just a prefix
                context("with just a prefix") {
                    // MARK: ------ succeeds when valid
                    it("succeeds when valid") {
                        expect(try? SessionId.Prefix(from: "00")).to(equal(.unblinded))
                        expect(try? SessionId.Prefix(from: "05")).to(equal(.standard))
                        expect(try? SessionId.Prefix(from: "15")).to(equal(.blinded15))
                        expect(try? SessionId.Prefix(from: "25")).to(equal(.blinded25))
                        expect(try? SessionId.Prefix(from: "03")).to(equal(.group))
                    }
                    
                    // MARK: ------ fails when nil
                    it("fails when nil") {
                        expect(try SessionId.Prefix(from: nil)).to(throwError(SessionIdError.emptyValue))
                    }
                    
                    // MARK: ------ fails when invalid
                    it("fails when invalid") {
                        expect(try SessionId.Prefix(from: "AB")).to(throwError(SessionIdError.invalidPrefix))
                    }
                }
                
                // MARK: ---- with a longer string
                context("with a longer string") {
                    // MARK: ------ fails with invalid hex
                    it("fails with invalid hex") {
                        expect(try SessionId.Prefix(from: "05\(TestConstants.publicKey.map { _ in "Z" }.joined())"))
                            .to(throwError(SessionIdError.invalidSessionId))
                    }
                    
                    // MARK: ------ fails with the wrong length
                    it("fails with the wrong length") {
                        expect(try SessionId.Prefix(from: "0")).to(throwError(SessionIdError.invalidLength))
                    }
                    
                    // MARK: ------ fails with an invalid prefix
                    it("fails with an invalid prefix") {
                        expect(try SessionId.Prefix(from: "AB\(TestConstants.publicKey)"))
                            .to(throwError(SessionIdError.invalidPrefix))
                    }
                }
            }
        }
    }
}
