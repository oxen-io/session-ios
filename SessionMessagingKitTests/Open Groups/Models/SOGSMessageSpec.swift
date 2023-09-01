// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble
import SessionUtilitiesKit

@testable import SessionMessagingKit

class SOGSMessageSpec: QuickSpec {
    // MARK: - Spec

    override func spec() {
        describe("a SOGSMessage") {
            var dependencies: TestDependencies!
            var mockCrypto: MockCrypto!
            var messageJson: String!
            var messageData: Data!
            var decoder: JSONDecoder!
            
            beforeEach {
                dependencies = TestDependencies()
                mockCrypto = MockCrypto()
                
                dependencies[singleton: .crypto] = mockCrypto
                
                messageJson = """
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
                messageData = messageJson.data(using: .utf8)!
                
                decoder = JSONDecoder()
                decoder.userInfo = [ Dependencies.userInfoKey: dependencies as Any ]
            }
            
            afterEach {
                mockCrypto = nil
            }
            
            context("when decoding") {
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
                
                context("and there is no content") {
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
                
                context("and there is content") {
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
                    
                    it("errors if the dependencies are not provided to the JSONDecoder") {
                        decoder = JSONDecoder()
                        
                        expect {
                            try decoder.decode(OpenGroupAPI.Message.self, from: messageData)
                        }
                        .to(throwError(HTTPError.parsingFailed))
                    }
                    
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
                        
                        it("succeeds if it succeeds verification") {
                            mockCrypto
                                .when {
                                    $0.verify(.signature(message: anyArray(), publicKey: anyArray(), signature: anyArray()))
                                }
                                .thenReturn(true)
                            
                            expect {
                                try decoder.decode(OpenGroupAPI.Message.self, from: messageData)
                            }
                            .toNot(beNil())
                        }
                        
                        it("provides the correct values as parameters") {
                            mockCrypto
                                .when {
                                    $0.verify(.signature(message: anyArray(), publicKey: anyArray(), signature: anyArray()))
                                }
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
                        
                        it("throws if it fails verification") {
                            mockCrypto
                                .when {
                                    $0.verify(.signature(message: anyArray(), publicKey: anyArray(), signature: anyArray()))
                                }
                                .thenReturn(false)
                            
                            expect {
                                try decoder.decode(OpenGroupAPI.Message.self, from: messageData)
                            }
                            .to(throwError(HTTPError.parsingFailed))
                        }
                    }
                    
                    context("that is unblinded") {
                        it("succeeds if it succeeds verification") {
                            mockCrypto
                                .when { $0.verify(.signatureEd25519(any(), publicKey: any(), data: any())) }
                                .thenReturn(true)
                            
                            expect {
                                try decoder.decode(OpenGroupAPI.Message.self, from: messageData)
                            }
                            .toNot(beNil())
                        }
                        
                        it("provides the correct values as parameters") {
                            mockCrypto
                                .when { $0.verify(.signatureEd25519(any(), publicKey: any(), data: any())) }
                                .thenReturn(true)
                            
                            _ = try? decoder.decode(OpenGroupAPI.Message.self, from: messageData)
                            
                            expect(mockCrypto)
                                .to(call(matchingParameters: .all) {
                                    $0.verify(
                                        .signatureEd25519(
                                            Data(base64Encoded: "VGVzdFNpZ25hdHVyZQ==")!,
                                            publicKey: Data(hex: TestConstants.publicKey),
                                            data: Data(base64Encoded: "VGVzdERhdGE=")!
                                        )
                                    )
                                })
                        }
                        
                        it("throws if it fails verification") {
                            mockCrypto
                                .when { $0.verify(.signatureEd25519(any(), publicKey: any(), data: any())) }
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
