// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble
import SessionUtilitiesKit

@testable import SessionMessagingKit

class SOGSMessageSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var messageJson: String! = """
        {
            "id": 123,
            "session_id": "05\(TestConstants.publicKey)",
            "posted": 234,
            "seqno": 345,
            "whisper": false,
            "whisper_mods": false,
                    
            "data": "VGVzdERhdGE=",
            "signature": "VGVzdFNpZ25hdHVyZQ=="
        }
        """
        @TestState var messageData: Data! = messageJson.data(using: .utf8)!
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = MockCrypto()
        @TestState var decoder: JSONDecoder! = JSONDecoder(using: dependencies)
        
        // MARK: - a SOGSMessage
        describe("a SOGSMessage") {
            // MARK: -- when decoding
            context("when decoding") {
                // MARK: ---- defaults the whisper values to false
                it("defaults the whisper values to false") {
                    messageJson = """
                    {
                        "id": 123,
                        "posted": 234,
                        "seqno": 345
                    }
                    """
                    messageData = messageJson.data(using: .utf8)!
                    let result: OpenGroupAPI.Message? = try? decoder.decode(OpenGroupAPI.Message.self, from: messageData)
                    
                    expect(result).toNot(beNil())
                    expect(result?.whisper).to(beFalse())
                    expect(result?.whisperMods).to(beFalse())
                }
                
                // MARK: ---- and there is no content
                context("and there is no content") {
                    // MARK: ------ does not need a sender
                    it("does not need a sender") {
                        messageJson = """
                        {
                            "id": 123,
                            "posted": 234,
                            "seqno": 345,
                            "whisper": false,
                            "whisper_mods": false
                        }
                        """
                        messageData = messageJson.data(using: .utf8)!
                        let result: OpenGroupAPI.Message? = try? decoder.decode(OpenGroupAPI.Message.self, from: messageData)
                        
                        expect(result).toNot(beNil())
                        expect(result?.sender).to(beNil())
                        expect(result?.base64EncodedData).to(beNil())
                        expect(result?.base64EncodedSignature).to(beNil())
                    }
                }
                
                // MARK: ---- and there is content
                context("and there is content") {
                    // MARK: ------ errors if there is no sender
                    it("errors if there is no sender") {
                        messageJson = """
                        {
                            "id": 123,
                            "posted": 234,
                            "seqno": 345,
                            "whisper": false,
                            "whisper_mods": false,
                        
                            "data": "VGVzdERhdGE=",
                            "signature": "VGVzdFNpZ25hdHVyZQ=="
                        }
                        """
                        messageData = messageJson.data(using: .utf8)!
                        
                        expect {
                            try decoder.decode(OpenGroupAPI.Message.self, from: messageData)
                        }
                        .to(throwError(HTTPError.parsingFailed))
                    }
                    
                    // MARK: ------ errors if the data is not a base64 encoded string
                    it("errors if the data is not a base64 encoded string") {
                        messageJson = """
                        {
                            "id": 123,
                            "session_id": "05\(TestConstants.publicKey)",
                            "posted": 234,
                            "seqno": 345,
                            "whisper": false,
                            "whisper_mods": false,
                        
                            "data": "Test!!!",
                            "signature": "VGVzdFNpZ25hdHVyZQ=="
                        }
                        """
                        messageData = messageJson.data(using: .utf8)!
                        
                        expect {
                            try decoder.decode(OpenGroupAPI.Message.self, from: messageData)
                        }
                        .to(throwError(HTTPError.parsingFailed))
                    }
                    
                    // MARK: ------ errors if the signature is not a base64 encoded string
                    it("errors if the signature is not a base64 encoded string") {
                        messageJson = """
                        {
                            "id": 123,
                            "session_id": "05\(TestConstants.publicKey)",
                            "posted": 234,
                            "seqno": 345,
                            "whisper": false,
                            "whisper_mods": false,
                        
                            "data": "VGVzdERhdGE=",
                            "signature": "Test!!!"
                        }
                        """
                        messageData = messageJson.data(using: .utf8)!
                        
                        expect {
                            try decoder.decode(OpenGroupAPI.Message.self, from: messageData)
                        }
                        .to(throwError(HTTPError.parsingFailed))
                    }
                    
                    // MARK: ------ errors if the session_id value is not valid
                    it("errors if the session_id value is not valid") {
                        messageJson = """
                        {
                            "id": 123,
                            "session_id": "TestId",
                            "posted": 234,
                            "seqno": 345,
                            "whisper": false,
                            "whisper_mods": false,
                        
                            "data": "VGVzdERhdGE=",
                            "signature": "VGVzdFNpZ25hdHVyZQ=="
                        }
                        """
                        messageData = messageJson.data(using: .utf8)!
                        
                        expect {
                            try decoder.decode(OpenGroupAPI.Message.self, from: messageData)
                        }
                        .to(throwError(HTTPError.parsingFailed))
                    }
                    
                    // MARK: ------ that is blinded
                    context("that is blinded") {
                        beforeEach {
                            messageJson = """
                            {
                                "id": 123,
                                "session_id": "15\(TestConstants.publicKey)",
                                "posted": 234,
                                "seqno": 345,
                                "whisper": false,
                                "whisper_mods": false,
                                        
                                "data": "VGVzdERhdGE=",
                                "signature": "VGVzdFNpZ25hdHVyZQ=="
                            }
                            """
                            messageData = messageJson.data(using: .utf8)!
                        }
                        
                        // MARK: -------- succeeds if it succeeds verification
                        it("succeeds if it succeeds verification") {
                            mockCrypto
                                .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
                                .thenReturn(true)
                            
                            expect {
                                try decoder.decode(OpenGroupAPI.Message.self, from: messageData)
                            }
                            .toNot(beNil())
                        }
                        
                        // MARK: -------- provides the correct values as parameters
                        it("provides the correct values as parameters") {
                            mockCrypto
                                .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
                                .thenReturn(true)
                            
                            _ = try? decoder.decode(OpenGroupAPI.Message.self, from: messageData)
                            
                            expect(mockCrypto)
                                .to(call(matchingParameters: .all) {
                                    $0.verify(
                                        .signature(
                                            message: Data(base64Encoded: "VGVzdERhdGE=")!.bytes,
                                            publicKey: Data(hex: TestConstants.publicKey).bytes,
                                            signature: Data(base64Encoded: "VGVzdFNpZ25hdHVyZQ==")!.bytes
                                        )
                                    )
                                })
                        }
                        
                        // MARK: -------- throws if it fails verification
                        it("throws if it fails verification") {
                            mockCrypto
                                .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
                                .thenReturn(false)
                            
                            expect {
                                try decoder.decode(OpenGroupAPI.Message.self, from: messageData)
                            }
                            .to(throwError(HTTPError.parsingFailed))
                        }
                    }
                    
                    // MARK: ------ that is unblinded
                    context("that is unblinded") {
                        // MARK: -------- succeeds if it succeeds verification
                        it("succeeds if it succeeds verification") {
                            mockCrypto
                                .when { $0.verify(.signatureXed25519(.any, curve25519PublicKey: .any, data: .any)) }
                                .thenReturn(true)
                            
                            expect {
                                try decoder.decode(OpenGroupAPI.Message.self, from: messageData)
                            }
                            .toNot(beNil())
                        }
                        
                        // MARK: -------- provides the correct values as parameters
                        it("provides the correct values as parameters") {
                            mockCrypto
                                .when { $0.verify(.signatureXed25519(.any, curve25519PublicKey: .any, data: .any)) }
                                .thenReturn(true)
                            
                            _ = try? decoder.decode(OpenGroupAPI.Message.self, from: messageData)
                            
                            expect(mockCrypto)
                                .to(call(matchingParameters: .all) {
                                    $0.verify(
                                        .signatureXed25519(
                                            Data(base64Encoded: "VGVzdFNpZ25hdHVyZQ==")!,
                                            curve25519PublicKey: Array(Data(hex: TestConstants.publicKey)),
                                            data: Data(base64Encoded: "VGVzdERhdGE=")!
                                        )
                                    )
                                })
                        }
                        
                        // MARK: -------- throws if it fails verification
                        it("throws if it fails verification") {
                            mockCrypto
                                .when { $0.verify(.signatureXed25519(.any, curve25519PublicKey: .any, data: .any)) }
                                .thenReturn(false)
                            
                            expect {
                                try decoder.decode(OpenGroupAPI.Message.self, from: messageData)
                            }
                            .to(throwError(HTTPError.parsingFailed))
                        }
                    }
                }
            }
        }
    }
}
