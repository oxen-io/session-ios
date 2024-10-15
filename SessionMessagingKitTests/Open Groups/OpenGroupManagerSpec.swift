// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class OpenGroupManagerSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
        @TestState var testInteraction1: Interaction! = Interaction(
            id: 234,
            serverHash: "TestServerHash",
            messageUuid: nil,
            threadId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
            authorId: "TestAuthorId",
            variant: .standardOutgoing,
            body: "Test",
            timestampMs: 123,
            receivedAtTimestampMs: 124,
            wasRead: false,
            hasMention: false,
            expiresInSeconds: nil,
            expiresStartedAtMs: nil,
            linkPreviewUrl: nil,
            openGroupServerMessageId: nil,
            openGroupWhisperMods: false,
            openGroupWhisperTo: nil,
            transientDependencies: nil
        )
        @TestState var testGroupThread: SessionThread! = SessionThread(
            id: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
            variant: .community,
            creationDateTimestamp: 0,
            using: dependencies
        )
        @TestState var testOpenGroup: OpenGroup! = OpenGroup(
            server: "testServer",
            roomToken: "testRoom",
            publicKey: TestConstants.publicKey,
            isActive: true,
            name: "Test",
            roomDescription: nil,
            imageId: nil,
            userCount: 0,
            infoUpdates: 10,
            sequenceNumber: 5
        )
        @TestState var testPollInfo: OpenGroupAPI.RoomPollInfo! = OpenGroupAPI.RoomPollInfo.mock.with(
            token: "testRoom",
            activeUsers: 10,
            details: .mock
        )
        @TestState var testMessage: OpenGroupAPI.Message! = OpenGroupAPI.Message(
            id: 127,
            sender: "05\(TestConstants.publicKey)",
            posted: 123,
            edited: nil,
            deleted: nil,
            seqNo: 124,
            whisper: false,
            whisperMods: false,
            whisperTo: nil,
            base64EncodedData: [
                "Cg0KC1Rlc3RNZXNzYWdlg",
                "AAAAAAAAAAAAAAAAAAAAA",
                "AAAAAAAAAAAAAAAAAAAAA",
                "AAAAAAAAAAAAAAAAAAAAA",
                "AAAAAAAAAAAAAAAAAAAAA",
                "AAAAAAAAAAAAAAAAAAAAA",
                "AAAAAAAAAAAAAAAAAAAAA",
                "AAAAAAAAAAAAAAAAAAAAA",
                "AAAAAAAAAAAAAAAAAAAAA",
                "AAAAAAAAAAAAAAAAAAAAA",
                "AA"
            ].joined(),
            base64EncodedSignature: nil,
            reactions: nil
        )
        @TestState var testDirectMessage: OpenGroupAPI.DirectMessage! = OpenGroupAPI.DirectMessage(
            id: 128,
            sender: "15\(TestConstants.blind15PublicKey)",
            recipient: "15\(TestConstants.blind15PublicKey)",
            posted: 1234567890,
            expires: 1234567990,
            base64EncodedMessage: Data(
                [UInt8](arrayLiteral: 0) +
                "TestMessage".bytes +
                Array(Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!)
            ).base64EncodedString()
        )
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrationTargets: [
                SNUtilitiesKit.self,
                SNMessagingKit.self
            ],
            using: dependencies,
            initialData: { db in
                try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
                try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).insert(db)
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
                
                try testGroupThread.insert(db)
                try testOpenGroup.insert(db)
                try Capability(openGroupServer: testOpenGroup.server, variant: .sogs, isMissing: false).insert(db)
            }
        )
        @TestState(singleton: .jobRunner, in: dependencies) var mockJobRunner: MockJobRunner! = MockJobRunner(
            initialSetup: { jobRunner in
                jobRunner
                    .when { $0.add(.any, job: .any, dependantJob: .any, canStartJob: .any) }
                    .thenReturn(nil)
                jobRunner
                    .when { $0.upsert(.any, job: .any, canStartJob: .any) }
                    .thenReturn(nil)
                jobRunner
                    .when { $0.jobInfoFor(jobs: .any, state: .any, variant: .any) }
                    .thenReturn([:])
            }
        )
        @TestState(singleton: .network, in: dependencies) var mockNetwork: MockNetwork! = MockNetwork(
            initialSetup: { network in
                network
                    .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
                    .thenReturn(MockNetwork.errorResponse())
            }
        )
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto.when { $0.generate(.hash(message: .any, length: .any)) }.thenReturn([])
                crypto
                    .when { $0.generate(.blinded15KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
                    .thenReturn(
                        KeyPair(
                            publicKey: Data(hex: TestConstants.publicKey).bytes,
                            secretKey: Data(hex: TestConstants.edSecretKey).bytes
                        )
                    )
                crypto
                    .when { $0.generate(.blinded25KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
                    .thenReturn(
                        KeyPair(
                            publicKey: Data(hex: TestConstants.publicKey).bytes,
                            secretKey: Data(hex: TestConstants.edSecretKey).bytes
                        )
                    )
                crypto
                    .when { $0.generate(.signatureBlind15(message: .any, serverPublicKey: .any, ed25519SecretKey: .any)) }
                    .thenReturn("TestSogsSignature".bytes)
                crypto
                    .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                    .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
                crypto
                    .when { $0.generate(.randomBytes(16)) }
                    .thenReturn(Array(Data(base64Encoded: "pK6YRtQApl4NhECGizF0Cg==")!))
                crypto
                    .when { $0.generate(.randomBytes(24)) }
                    .thenReturn(Array(Data(base64Encoded: "pbTUizreT0sqJ2R2LloseQDyVL2RYztD")!))
            }
        )
        @TestState(defaults: .standard, in: dependencies) var mockUserDefaults: MockUserDefaults! = MockUserDefaults(
            initialSetup: { defaults in
                defaults.when { $0.integer(forKey: .any) }.thenReturn(0)
            }
        )
        @TestState(defaults: .appGroup, in: dependencies) var mockAppGroupDefaults: MockUserDefaults! = MockUserDefaults(
            initialSetup: { defaults in
                defaults.when { $0.bool(forKey: .any) }.thenReturn(false)
            }
        )
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
            }
        )
        @TestState(cache: .openGroupManager, in: dependencies) var mockOGMCache: MockOGMCache! = MockOGMCache(
            initialSetup: { cache in
                cache.when { $0.pendingChanges }.thenReturn([])
                cache.when { $0.pendingChanges = .any }.thenReturn(())
                cache.when { $0.getTimeSinceLastOpen(using: .any) }.thenReturn(0)
                cache.when { $0.setDefaultRoomInfo(.any) }.thenReturn(())
            }
        )
        @TestState var mockPoller: MockCommunityPoller! = MockCommunityPoller(
            initialSetup: { poller in
                poller.when { $0.startIfNeeded() }.thenReturn(())
                poller.when { $0.stop() }.thenReturn(())
            }
        )
        @TestState(cache: .communityPollers, in: dependencies) var mockCommunityPollerCache: MockCommunityPollerCache! = MockCommunityPollerCache(
            initialSetup: { cache in
                cache.when { $0.serversBeingPolled }.thenReturn([])
                cache.when { $0.startAllPollers() }.thenReturn(())
                cache.when { $0.getOrCreatePoller(for: .any) }.thenReturn(mockPoller)
                cache.when { $0.stopAndRemovePoller(for: .any) }.thenReturn(())
                cache.when { $0.stopAndRemoveAllPollers() }.thenReturn(())
            }
        )
        @TestState var disposables: [AnyCancellable]! = []
        
        @TestState var cache: OpenGroupManager.Cache! = OpenGroupManager.Cache(using: dependencies)
        @TestState var openGroupManager: OpenGroupManager! = OpenGroupManager(using: dependencies)
        
        // MARK: - an OpenGroupManager
        describe("an OpenGroupManager") {
            // MARK: -- cache data
            context("cache data") {
                // MARK: ---- defaults the time since last open to greatestFiniteMagnitude
                it("defaults the time since last open to greatestFiniteMagnitude") {
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: UserDefaults.DateKey.lastOpen.rawValue)
                        }
                        .thenReturn(nil)
                    
                    expect(cache.getTimeSinceLastOpen(using: dependencies))
                        .to(beCloseTo(.greatestFiniteMagnitude))
                }
                
                // MARK: ---- returns the time since the last open
                it("returns the time since the last open") {
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: UserDefaults.DateKey.lastOpen.rawValue)
                        }
                        .thenReturn(Date(timeIntervalSince1970: 1234567880))
                    dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
                    
                    expect(cache.getTimeSinceLastOpen(using: dependencies))
                        .to(beCloseTo(10))
                }
                
                // MARK: ---- caches the time since the last open
                it("caches the time since the last open") {
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: UserDefaults.DateKey.lastOpen.rawValue)
                        }
                        .thenReturn(Date(timeIntervalSince1970: 1234567770))
                    dependencies.dateNow = Date(timeIntervalSince1970: 1234567780)
                    
                    expect(cache.getTimeSinceLastOpen(using: dependencies))
                        .to(beCloseTo(10))
                    
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: UserDefaults.DateKey.lastOpen.rawValue)
                        }
                        .thenReturn(Date(timeIntervalSince1970: 1234567890))
                 
                    // Cached value shouldn't have been updated
                    expect(cache.getTimeSinceLastOpen(using: dependencies))
                        .to(beCloseTo(10))
                }
            }
            
            // MARK: -- when checking if an open group is run by session
            context("when checking if an open group is run by session") {
                // MARK: ---- returns false when it does not match one of Sessions servers with no scheme
                it("returns false when it does not match one of Sessions servers with no scheme") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "test.test"))
                        .to(beFalse())
                }
                
                // MARK: ---- returns false when it does not match one of Sessions servers in http
                it("returns false when it does not match one of Sessions servers in http") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "http://test.test"))
                        .to(beFalse())
                }
                
                // MARK: ---- returns false when it does not match one of Sessions servers in https
                it("returns false when it does not match one of Sessions servers in https") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "https://test.test"))
                        .to(beFalse())
                }
                
                // MARK: ---- returns true when it matches Sessions SOGS IP
                it("returns true when it matches Sessions SOGS IP") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "116.203.70.33"))
                        .to(beTrue())
                }
                
                // MARK: ---- returns true when it matches Sessions SOGS IP with http
                it("returns true when it matches Sessions SOGS IP with http") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "http://116.203.70.33"))
                        .to(beTrue())
                }
                
                // MARK: ---- returns true when it matches Sessions SOGS IP with https
                it("returns true when it matches Sessions SOGS IP with https") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "https://116.203.70.33"))
                        .to(beTrue())
                }
                
                // MARK: ---- returns true when it matches Sessions SOGS IP with a port
                it("returns true when it matches Sessions SOGS IP with a port") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "116.203.70.33:80"))
                        .to(beTrue())
                }
                
                // MARK: ---- returns true when it matches Sessions SOGS domain
                it("returns true when it matches Sessions SOGS domain") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "open.getsession.org"))
                        .to(beTrue())
                }
                
                // MARK: ---- returns true when it matches Sessions SOGS domain with http
                it("returns true when it matches Sessions SOGS domain with http") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "http://open.getsession.org"))
                        .to(beTrue())
                }
                
                // MARK: ---- returns true when it matches Sessions SOGS domain with https
                it("returns true when it matches Sessions SOGS domain with https") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "https://open.getsession.org"))
                        .to(beTrue())
                }
                
                // MARK: ---- returns true when it matches Sessions SOGS domain with a port
                it("returns true when it matches Sessions SOGS domain with a port") {
                    expect(OpenGroupManager.isSessionRunOpenGroup(server: "open.getsession.org:80"))
                        .to(beTrue())
                }
            }
            
            // MARK: -- when checking it has an existing open group
            context("when checking it has an existing open group") {
                // MARK: ---- when there is a thread for the room and the cache has a poller
                context("when there is a thread for the room and the cache has a poller") {
                    beforeEach {
                        mockCommunityPollerCache.when { $0.serversBeingPolled }.thenReturn(["testserver"])
                    }
                    
                    // MARK: ------ for the no-scheme variant
                    context("for the no-scheme variant") {
                        // MARK: -------- returns true when no scheme is provided
                        it("returns true when no scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "testServer",
                                        publicKey: TestConstants.serverPublicKey
                                    )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a http scheme is provided
                        it("returns true when a http scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "http://testServer",
                                        publicKey: TestConstants.serverPublicKey
                                    )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a https scheme is provided
                        it("returns true when a https scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "https://testServer",
                                        publicKey: TestConstants.serverPublicKey
                                    )
                                }
                            ).to(beTrue())
                        }
                    }
                    
                    // MARK: ------ for the http variant
                    context("for the http variant") {
                        // MARK: -------- returns true when no scheme is provided
                        it("returns true when no scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "testServer",
                                        publicKey: TestConstants.serverPublicKey
                                    )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a http scheme is provided
                        it("returns true when a http scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "http://testServer",
                                        publicKey: TestConstants.serverPublicKey
                                    )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a https scheme is provided
                        it("returns true when a https scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "https://testServer",
                                        publicKey: TestConstants.serverPublicKey
                                    )
                                }
                            ).to(beTrue())
                        }
                    }
                    
                    // MARK: ------ for the https variant
                    context("for the https variant") {
                        // MARK: -------- returns true when no scheme is provided
                        it("returns true when no scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "testServer",
                                        publicKey: TestConstants.serverPublicKey
                                    )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a http scheme is provided
                        it("returns true when a http scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "http://testServer",
                                        publicKey: TestConstants.serverPublicKey
                                    )
                                }
                            ).to(beTrue())
                        }
                        
                        // MARK: -------- returns true when a https scheme is provided
                        it("returns true when a https scheme is provided") {
                            expect(
                                mockStorage.read { db -> Bool in
                                    openGroupManager.hasExistingOpenGroup(
                                        db,
                                        roomToken: "testRoom",
                                        server: "https://testServer",
                                        publicKey: TestConstants.serverPublicKey
                                    )
                                }
                            ).to(beTrue())
                        }
                    }
                }
                
                // MARK: ---- when given the legacy DNS host and there is a cached poller for the default server
                context("when given the legacy DNS host and there is a cached poller for the default server") {
                    // MARK: ------ returns true
                    it("returns true") {
                        mockCommunityPollerCache.when { $0.serversBeingPolled }.thenReturn(["http://116.203.70.33"])
                        mockStorage.write { db in
                            try SessionThread(
                                id: OpenGroup.idFor(roomToken: "testRoom", server: "http://116.203.70.33"),
                                variant: .community,
                                creationDateTimestamp: 0,
                                shouldBeVisible: true,
                                isPinned: false,
                                messageDraft: nil,
                                notificationSound: nil,
                                mutedUntilTimestamp: nil,
                                onlyNotifyForMentions: false,
                                using: dependencies
                            ).insert(db)
                        }
                        
                        expect(
                            mockStorage.read { db -> Bool in
                                openGroupManager.hasExistingOpenGroup(
                                    db,
                                    roomToken: "testRoom",
                                    server: "http://open.getsession.org",
                                    publicKey: TestConstants.serverPublicKey
                                )
                            }
                        ).to(beTrue())
                    }
                }
                
                // MARK: ---- when given the default server and there is a cached poller for the legacy DNS host
                context("when given the default server and there is a cached poller for the legacy DNS host") {
                    // MARK: ------ returns true
                    it("returns true") {
                        mockCommunityPollerCache.when { $0.serversBeingPolled }.thenReturn(["http://open.getsession.org"])
                        mockStorage.write { db in
                            try SessionThread(
                                id: OpenGroup.idFor(roomToken: "testRoom", server: "http://open.getsession.org"),
                                variant: .community,
                                creationDateTimestamp: 0,
                                shouldBeVisible: true,
                                isPinned: false,
                                messageDraft: nil,
                                notificationSound: nil,
                                mutedUntilTimestamp: nil,
                                onlyNotifyForMentions: false,
                                using: dependencies
                            ).insert(db)
                        }
                        
                        expect(
                            mockStorage.read { db -> Bool in
                                openGroupManager.hasExistingOpenGroup(
                                    db,
                                    roomToken: "testRoom",
                                    server: "http://116.203.70.33",
                                    publicKey: TestConstants.serverPublicKey
                                )
                            }
                        ).to(beTrue())
                    }
                }
                
                // MARK: ---- returns false when given an invalid server
                it("returns false when given an invalid server") {
                    expect(
                        mockStorage.read { db -> Bool in
                            openGroupManager.hasExistingOpenGroup(
                                db,
                                roomToken: "testRoom",
                                server: "%%%",
                                publicKey: TestConstants.serverPublicKey
                            )
                        }
                    ).to(beFalse())
                }
                
                // MARK: ---- returns false if there is not a poller for the server in the cache
                it("returns false if there is not a poller for the server in the cache") {
                    mockCommunityPollerCache.when { $0.serversBeingPolled }.thenReturn([])
                    
                    expect(
                        mockStorage.read { db -> Bool in
                            openGroupManager.hasExistingOpenGroup(
                                db,
                                roomToken: "testRoom",
                                server: "testServer",
                                publicKey: TestConstants.serverPublicKey
                            )
                        }
                    ).to(beFalse())
                }
                
                // MARK: ---- returns false if there is a poller for the server in the cache but no thread for the room
                it("returns false if there is a poller for the server in the cache but no thread for the room") {
                    mockStorage.write { db in
                        try SessionThread.deleteAll(db)
                    }
                    
                    expect(
                        mockStorage.read { db -> Bool in
                            openGroupManager.hasExistingOpenGroup(
                                db,
                                roomToken: "testRoom",
                                server: "testServer",
                                publicKey: TestConstants.serverPublicKey
                            )
                        }
                    ).to(beFalse())
                }
            }
        }
        
        // MARK: - an OpenGroupManager
        describe("an OpenGroupManager") {
            // MARK: -- when adding
            context("when adding") {
                beforeEach {
                    mockStorage.write { db in
                        try OpenGroup.deleteAll(db)
                    }
                    
                    mockNetwork
                        .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
                        .thenReturn(Network.BatchResponse.mockCapabilitiesAndRoomResponse)
                    
                    mockUserDefaults
                        .when { (defaults: inout any UserDefaultsType) -> Any? in
                            defaults.object(forKey: UserDefaults.DateKey.lastOpen.rawValue)
                        }
                        .thenReturn(Date(timeIntervalSince1970: 1234567890))
                }
                
                // MARK: ---- stores the open group server
                it("stores the open group server") {
                    mockStorage
                        .writePublisher { (db: Database) -> Bool in
                            openGroupManager.add(
                                db,
                                roomToken: "testRoom",
                                server: "testServer",
                                publicKey: TestConstants.serverPublicKey,
                                calledFromConfig: .userGroups // Don't trigger LibSession logic
                            )
                        }
                        .flatMap { successfullyAddedGroup in
                            openGroupManager.performInitialRequestsAfterAdd(
                                queue: DispatchQueue.main,
                                successfullyAddedGroup: successfullyAddedGroup,
                                roomToken: "testRoom",
                                server: "testServer",
                                publicKey: TestConstants.serverPublicKey,
                                calledFromConfig: .userGroups // Don't trigger LibSession logic
                            )
                        }
                        .sinkAndStore(in: &disposables)
                    
                    expect(
                        mockStorage
                            .read { (db: Database) in
                                try OpenGroup
                                    .select(.threadId)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                    )
                    .to(equal(OpenGroup.idFor(roomToken: "testRoom", server: "testServer")))
                }
                
                // MARK: ---- adds a poller
                it("adds a poller") {
                    mockStorage
                        .writePublisher { (db: Database) -> Bool in
                            openGroupManager.add(
                                db,
                                roomToken: "testRoom",
                                server: "testServer",
                                publicKey: TestConstants.serverPublicKey,
                                calledFromConfig: .userGroups // Don't trigger LibSession logic
                            )
                        }
                        .flatMap { successfullyAddedGroup in
                            openGroupManager.performInitialRequestsAfterAdd(
                                queue: DispatchQueue.main,
                                successfullyAddedGroup: successfullyAddedGroup,
                                roomToken: "testRoom",
                                server: "testServer",
                                publicKey: TestConstants.serverPublicKey,
                                calledFromConfig: .userGroups // Don't trigger LibSession logic
                            )
                        }
                        .sinkAndStore(in: &disposables)
                    
                    expect(mockCommunityPollerCache)
                        .to(call(matchingParameters: .all) {
                            $0.getOrCreatePoller(for: CommunityPoller.Info(server: "testserver", pollFailureCount: 0))
                        })
                    expect(mockPoller).to(call { $0.startIfNeeded() })
                }
                
                // MARK: ---- an existing room
                context("an existing room") {
                    beforeEach {
                        mockCommunityPollerCache.when { $0.serversBeingPolled }.thenReturn(["testserver"])
                        mockStorage.write { db in
                            try testOpenGroup.insert(db)
                        }
                    }
                    
                    // MARK: ------ does not reset the sequence number or update the public key
                    it("does not reset the sequence number or update the public key") {
                        mockStorage
                            .writePublisher { (db: Database) -> Bool in
                                openGroupManager.add(
                                    db,
                                    roomToken: "testRoom",
                                    server: "testServer",
                                    publicKey: TestConstants.serverPublicKey
                                        .replacingOccurrences(of: "c3", with: "00")
                                        .replacingOccurrences(of: "b3", with: "00"),
                                    calledFromConfig: .userGroups // Don't trigger LibSession logic
                                )
                            }
                            .flatMap { successfullyAddedGroup in
                                openGroupManager.performInitialRequestsAfterAdd(
                                    queue: DispatchQueue.main,
                                    successfullyAddedGroup: successfullyAddedGroup,
                                    roomToken: "testRoom",
                                    server: "testServer",
                                    publicKey: TestConstants.serverPublicKey
                                        .replacingOccurrences(of: "c3", with: "00")
                                        .replacingOccurrences(of: "b3", with: "00"),
                                    calledFromConfig: .userGroups // Don't trigger LibSession logic
                                )
                            }
                            .sinkAndStore(in: &disposables)
                        
                        expect(
                            mockStorage.read { db in
                                try OpenGroup
                                    .select(.sequenceNumber)
                                    .asRequest(of: Int64.self)
                                    .fetchOne(db)
                            }
                        ).to(equal(5))
                        expect(
                            mockStorage.read { db in
                                try OpenGroup
                                    .select(.publicKey)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).to(equal(TestConstants.publicKey))
                    }
                }
                
                // MARK: ---- with an invalid response
                context("with an invalid response") {
                    beforeEach {
                        mockNetwork
                            .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
                            .thenReturn(MockNetwork.response(data: Data()))
                        
                        mockUserDefaults
                            .when { (defaults: inout any UserDefaultsType) -> Any? in
                                defaults.object(forKey: UserDefaults.DateKey.lastOpen.rawValue)
                            }
                            .thenReturn(Date(timeIntervalSince1970: 1234567890))
                    }
                
                    // MARK: ------ fails with the error
                    it("fails with the error") {
                        var error: Error?
                        
                        mockStorage
                            .writePublisher { (db: Database) -> Bool in
                                openGroupManager.add(
                                    db,
                                    roomToken: "testRoom",
                                    server: "testServer",
                                    publicKey: TestConstants.serverPublicKey,
                                    calledFromConfig: .userGroups // Don't trigger LibSession logic
                                )
                            }
                            .flatMap { successfullyAddedGroup in
                                openGroupManager.performInitialRequestsAfterAdd(
                                    queue: DispatchQueue.main,
                                    successfullyAddedGroup: successfullyAddedGroup,
                                    roomToken: "testRoom",
                                    server: "testServer",
                                    publicKey: TestConstants.serverPublicKey,
                                    calledFromConfig: .userGroups // Don't trigger LibSession logic
                                )
                            }
                            .mapError { result -> Error in error.setting(to: result) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(error).to(matchError(NetworkError.parsingFailed))
                    }
                }
            }
            
            // MARK: -- when deleting
            context("when deleting") {
                beforeEach {
                    mockStorage.write { db in
                        try Interaction.deleteAll(db)
                        try SessionThread.deleteAll(db)
                        
                        try testGroupThread.insert(db)
                        try testOpenGroup.insert(db)
                        try testInteraction1.insert(db)
                        try Interaction
                            .updateAll(
                                db,
                                Interaction.Columns.threadId
                                    .set(to: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"))
                            )
                    }
                }
                
                // MARK: ---- removes all interactions for the thread
                it("removes all interactions for the thread") {
                    mockStorage.write { db in
                        try openGroupManager.delete(
                            db,
                            openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                            calledFromConfig: .userGroups // Don't trigger LibSession logic
                        )
                    }
                    
                    expect(mockStorage.read { db in try Interaction.fetchCount(db) })
                        .to(equal(0))
                }
                
                // MARK: ---- removes the given thread
                it("removes the given thread") {
                    mockStorage.write { db in
                        try openGroupManager.delete(
                            db,
                            openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                            calledFromConfig: .userGroups // Don't trigger LibSession logic
                        )
                    }
                    
                    expect(mockStorage.read { db -> Int in try SessionThread.fetchCount(db) })
                        .to(equal(0))
                }
                
                // MARK: ---- and there is only one open group for this server
                context("and there is only one open group for this server") {
                    // MARK: ------ stops the poller
                    it("stops the poller") {
                        mockStorage.write { db in
                            try openGroupManager.delete(
                                db,
                                openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                calledFromConfig: .userGroups // Don't trigger LibSession logic
                            )
                        }
                        
                        expect(mockCommunityPollerCache)
                            .to(call(matchingParameters: .all) { $0.stopAndRemovePoller(for: "testserver") })
                    }
                    
                    // MARK: ------ removes the open group
                    it("removes the open group") {
                        mockStorage.write { db in
                            try openGroupManager.delete(
                                db,
                                openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                calledFromConfig: .userGroups // Don't trigger LibSession logic
                            )
                        }
                        
                        expect(mockStorage.read { db in try OpenGroup.fetchCount(db) })
                            .to(equal(0))
                    }
                }
                
                // MARK: ---- and the are multiple open groups for this server
                context("and the are multiple open groups for this server") {
                    beforeEach {
                        mockStorage.write { db in
                            try OpenGroup.deleteAll(db)
                            try testOpenGroup.insert(db)
                            try OpenGroup(
                                server: "testServer",
                                roomToken: "testRoom1",
                                publicKey: TestConstants.publicKey,
                                isActive: true,
                                name: "Test1",
                                roomDescription: nil,
                                imageId: nil,
                                userCount: 0,
                                infoUpdates: 0,
                                sequenceNumber: 0,
                                inboxLatestMessageId: 0,
                                outboxLatestMessageId: 0
                            ).insert(db)
                        }
                    }
                    
                    // MARK: ------ removes the open group
                    it("removes the open group") {
                        mockStorage.write { db in
                            try openGroupManager.delete(
                                db,
                                openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                calledFromConfig: .userGroups // Don't trigger LibSession logic
                            )
                        }
                        
                        expect(mockStorage.read { db in try OpenGroup.fetchCount(db) })
                            .to(equal(1))
                    }
                }
                
                // MARK: ---- and it is the default server
                context("and it is the default server") {
                    beforeEach {
                        mockStorage.write { db in
                            try OpenGroup.deleteAll(db)
                            try OpenGroup(
                                server: OpenGroupAPI.defaultServer,
                                roomToken: "testRoom",
                                publicKey: TestConstants.publicKey,
                                isActive: true,
                                name: "Test1",
                                roomDescription: nil,
                                imageId: nil,
                                userCount: 0,
                                infoUpdates: 0,
                                sequenceNumber: 0,
                                inboxLatestMessageId: 0,
                                outboxLatestMessageId: 0
                            ).insert(db)
                            try OpenGroup(
                                server: OpenGroupAPI.defaultServer,
                                roomToken: "testRoom1",
                                publicKey: TestConstants.publicKey,
                                isActive: true,
                                name: "Test1",
                                roomDescription: nil,
                                imageId: nil,
                                userCount: 0,
                                infoUpdates: 0,
                                sequenceNumber: 0,
                                inboxLatestMessageId: 0,
                                outboxLatestMessageId: 0
                            ).insert(db)
                        }
                    }
                    
                    // MARK: ------ does not remove the open group
                    it("does not remove the open group") {
                        mockStorage.write { db in
                            try openGroupManager.delete(
                                db,
                                openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: OpenGroupAPI.defaultServer),
                                calledFromConfig: .userGroups // Don't trigger LibSession logic
                            )
                        }
                        
                        expect(mockStorage.read { db in try OpenGroup.fetchCount(db) })
                            .to(equal(2))
                    }
                    
                    // MARK: ------ deactivates the open group
                    it("deactivates the open group") {
                        mockStorage.write { db in
                            try openGroupManager.delete(
                                db,
                                openGroupId: OpenGroup.idFor(roomToken: "testRoom", server: OpenGroupAPI.defaultServer),
                                calledFromConfig: .userGroups // Don't trigger LibSession logic
                            )
                        }
                        
                        expect(
                            mockStorage.read { db in
                                try OpenGroup
                                    .select(.isActive)
                                    .filter(id: OpenGroup.idFor(roomToken: "testRoom", server: OpenGroupAPI.defaultServer))
                                    .asRequest(of: Bool.self)
                                    .fetchOne(db)
                            }
                        ).to(beFalse())
                    }
                }
            }
            
            // MARK: -- when handling capabilities
            context("when handling capabilities") {
                beforeEach {
                    mockStorage.write { db in
                        OpenGroupManager
                            .handleCapabilities(
                                db,
                                capabilities: OpenGroupAPI.Capabilities(capabilities: [.sogs], missing: []),
                                on: "testserver"
                            )
                    }
                }
                
                // MARK: ---- stores the capabilities
                it("stores the capabilities") {
                    expect(mockStorage.read { db in try Capability.fetchCount(db) })
                        .to(equal(1))
                }
            }
        }
        
        // MARK: - an OpenGroupManager
        describe("an OpenGroupManager") {
            // MARK: -- when handling room poll info
            context("when handling room poll info") {
                beforeEach {
                    mockStorage.write { db in
                        try OpenGroup.deleteAll(db)
                        
                        try testOpenGroup.insert(db)
                    }
                }
                
                // MARK: ---- saves the updated open group
                it("saves the updated open group") {
                    mockStorage.write { db in
                        try OpenGroupManager.handlePollInfo(
                            db,
                            pollInfo: testPollInfo,
                            publicKey: TestConstants.publicKey,
                            for: "testRoom",
                            on: "testServer",
                            using: dependencies
                        )
                    }
                    
                    expect(
                        mockStorage.read { db in
                            try OpenGroup
                                .select(.userCount)
                                .asRequest(of: Int64.self)
                                .fetchOne(db)
                        }
                    ).to(equal(10))
                }
                
                // MARK: ---- does not schedule the displayPictureDownload job if there is no image
                it("does not schedule the displayPictureDownload job if there is no image") {
                    mockStorage.write { db in
                        try OpenGroupManager.handlePollInfo(
                            db,
                            pollInfo: testPollInfo,
                            publicKey: TestConstants.publicKey,
                            for: "testRoom",
                            on: "testServer",
                            using: dependencies
                        )
                    }
                    
                    expect(mockJobRunner)
                        .toNot(call(matchingParameters: .all) {
                            $0.add(
                                .any,
                                job: Job(
                                    variant: .displayPictureDownload,
                                    shouldBeUnique: true,
                                    details: DisplayPictureDownloadJob.Details(
                                        target: .community(
                                            imageId: "12",
                                            roomToken: "testRoom",
                                            server: "testServer"
                                        ),
                                        timestamp: 1234567890
                                    )
                                ),
                                dependantJob: nil,
                                canStartJob: true
                            )
                        })
                }
                
                // MARK: ---- schedules the displayPictureDownload job if there is an image
                it("schedules the displayPictureDownload job if there is an image") {
                    mockStorage.write { db in
                        try OpenGroup.deleteAll(db)
                        try OpenGroup(
                            server: "testServer",
                            roomToken: "testRoom",
                            publicKey: TestConstants.publicKey,
                            isActive: true,
                            name: "Test",
                            imageId: "12",
                            userCount: 0,
                            infoUpdates: 10
                        ).insert(db)
                    }
                    
                    mockStorage.write { db in
                        try OpenGroupManager.handlePollInfo(
                            db,
                            pollInfo: testPollInfo,
                            publicKey: TestConstants.publicKey,
                            for: "testRoom",
                            on: "testServer",
                            using: dependencies
                        )
                    }
                    
                    expect(mockJobRunner)
                        .to(call(matchingParameters: .all) {
                            $0.add(
                                .any,
                                job: Job(
                                    variant: .displayPictureDownload,
                                    shouldBeUnique: true,
                                    details: DisplayPictureDownloadJob.Details(
                                        target: .community(
                                            imageId: "12",
                                            roomToken: "testRoom",
                                            server: "testServer"
                                        ),
                                        timestamp: 1234567890
                                    )
                                ),
                                dependantJob: nil,
                                canStartJob: true
                            )
                        })
                }
                
                // MARK: ---- and updating the moderator list
                context("and updating the moderator list") {
                    // MARK: ------ successfully updates
                    it("successfully updates") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mock.with(
                                moderators: ["TestMod"],
                                hiddenModerators: [],
                                admins: [],
                                hiddenAdmins: []
                            )
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> GroupMember? in
                                try GroupMember
                                    .filter(GroupMember.Columns.groupId == OpenGroup.idFor(
                                        roomToken: "testRoom",
                                        server: "testServer"
                                    ))
                                    .fetchOne(db)
                            }
                        ).to(equal(
                            GroupMember(
                                groupId: OpenGroup.idFor(
                                    roomToken: "testRoom",
                                    server: "testServer"
                                ),
                                profileId: "TestMod",
                                role: .moderator,
                                roleStatus: .accepted,
                                isHidden: false
                            )
                        ))
                    }
                    
                    // MARK: ------ updates for hidden moderators
                    it("updates for hidden moderators") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mock.with(
                                moderators: [],
                                hiddenModerators: ["TestMod2"],
                                admins: [],
                                hiddenAdmins: []
                            )
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> GroupMember? in
                                try GroupMember
                                    .filter(GroupMember.Columns.groupId == OpenGroup.idFor(
                                        roomToken: "testRoom",
                                        server: "testServer"
                                    ))
                                    .fetchOne(db)
                            }
                        ).to(equal(
                            GroupMember(
                                groupId: OpenGroup.idFor(
                                    roomToken: "testRoom",
                                    server: "testServer"
                                ),
                                profileId: "TestMod2",
                                role: .moderator,
                                roleStatus: .accepted,
                                isHidden: true
                            )
                        ))
                    }
                    
                    // MARK: ------ does not insert mods if no moderators are provided
                    it("does not insert mods if no moderators are provided") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
                            token: "testRoom",
                            activeUsers: 10
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try GroupMember.fetchCount(db) })
                            .to(equal(0))
                    }
                }
                
                // MARK: ---- and updating the admin list
                context("and updating the admin list") {
                    // MARK: ------ successfully updates
                    it("successfully updates") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mock.with(
                                moderators: [],
                                hiddenModerators: [],
                                admins: ["TestAdmin"],
                                hiddenAdmins: []
                            )
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> GroupMember? in
                                try GroupMember
                                    .filter(GroupMember.Columns.groupId == OpenGroup.idFor(
                                        roomToken: "testRoom",
                                        server: "testServer"
                                    ))
                                    .fetchOne(db)
                            }
                        ).to(equal(
                            GroupMember(
                                groupId: OpenGroup.idFor(
                                    roomToken: "testRoom",
                                    server: "testServer"
                                ),
                                profileId: "TestAdmin",
                                role: .admin,
                                roleStatus: .accepted,
                                isHidden: false
                            )
                        ))
                    }
                    
                    // MARK: ------ updates for hidden admins
                    it("updates for hidden admins") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mock.with(
                                moderators: [],
                                hiddenModerators: [],
                                admins: [],
                                hiddenAdmins: ["TestAdmin2"]
                            )
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> GroupMember? in
                                try GroupMember
                                    .filter(GroupMember.Columns.groupId == OpenGroup.idFor(
                                        roomToken: "testRoom",
                                        server: "testServer"
                                    ))
                                    .fetchOne(db)
                            }
                        ).to(equal(
                            GroupMember(
                                groupId: OpenGroup.idFor(
                                    roomToken: "testRoom",
                                    server: "testServer"
                                ),
                                profileId: "TestAdmin2",
                                role: .admin,
                                roleStatus: .accepted,
                                isHidden: true
                            )
                        ))
                    }
                    
                    // MARK: ------ does not insert an admin if no admins are provided
                    it("does not insert an admin if no admins are provided") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: nil
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try GroupMember.fetchCount(db) })
                            .to(equal(0))
                    }
                }
                
                // MARK: ---- when it cannot get the open group
                context("when it cannot get the open group") {
                    // MARK: ------ does not save the thread
                    it("does not save the thread") {
                        mockStorage.write { db in
                            try OpenGroup.deleteAll(db)
                        }
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try OpenGroup.fetchCount(db) }).to(equal(0))
                    }
                }
                
                // MARK: ---- when not given a public key
                context("when not given a public key") {
                    // MARK: ------ saves the open group with the existing public key
                    it("saves the open group with the existing public key") {
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: nil,
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> String? in
                                try OpenGroup
                                    .select(.publicKey)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).to(equal(TestConstants.publicKey))
                    }
                }
                
                // MARK: ---- when trying to get the room image
                context("when trying to get the room image") {
                    beforeEach {
                        mockStorage.write { db in
                            try OpenGroup
                                .updateAll(db, OpenGroup.Columns.displayPictureFilename.set(to: nil))
                        }
                    }
                    
                    // MARK: ------ schedules a download for the room image
                    it("schedules a download for the room image") {
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mock.with(
                                token: "test",
                                name: "test",
                                imageId: "10"
                            )
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> String? in
                                try OpenGroup
                                    .select(.imageId)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).to(equal("10"))
                        expect(mockJobRunner)
                            .to(call(.exactly(times: 1), matchingParameters: .all) {
                                $0.add(
                                    .any,
                                    job: Job(
                                        variant: .displayPictureDownload,
                                        shouldBeUnique: true,
                                        details: DisplayPictureDownloadJob.Details(
                                            target: .community(
                                                imageId: "10",
                                                roomToken: "testRoom",
                                                server: "testServer"
                                            ),
                                            timestamp: 1234567890
                                        )
                                    ),
                                    dependantJob: nil,
                                    canStartJob: true
                                )
                            })
                    }
                    
                    // MARK: ------ uses the existing room image id if none is provided
                    it("uses the existing room image id if none is provided") {
                        mockStorage.write { db in
                            try OpenGroup.deleteAll(db)
                            try OpenGroup(
                                server: "testServer",
                                roomToken: "testRoom",
                                publicKey: TestConstants.publicKey,
                                isActive: true,
                                name: "Test",
                                imageId: "12",
                                userCount: 0,
                                infoUpdates: 10,
                                displayPictureFilename: "test",
                                lastDisplayPictureUpdate: 1234567890
                            ).insert(db)
                        }
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: nil
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> String? in
                                try OpenGroup
                                    .select(.imageId)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).to(equal("12"))
                        expect(
                            mockStorage.read { db -> String? in
                                try OpenGroup
                                    .select(.displayPictureFilename)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).toNot(beNil())
                        expect(mockJobRunner).toNot(call { $0.add(.any, job: .any, dependantJob: .any, canStartJob: .any) })
                    }
                    
                    // MARK: ------ uses the new room image id if there is an existing one
                    it("uses the new room image id if there is an existing one") {
                        mockStorage.write { db in
                            try OpenGroup.deleteAll(db)
                            try OpenGroup(
                                server: "testServer",
                                roomToken: "testRoom",
                                publicKey: TestConstants.publicKey,
                                isActive: true,
                                name: "Test",
                                imageId: "12",
                                userCount: 0,
                                infoUpdates: 10,
                                displayPictureFilename: "test",
                                lastDisplayPictureUpdate: 1234567890
                            ).insert(db)
                        }
                        
                        testPollInfo = OpenGroupAPI.RoomPollInfo.mock.with(
                            token: "testRoom",
                            activeUsers: 10,
                            details: OpenGroupAPI.Room.mock.with(
                                token: "test",
                                name: "test",
                                infoUpdates: 10,
                                imageId: "10"
                            )
                        )
                        
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> String? in
                                try OpenGroup
                                    .select(.imageId)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).to(equal("10"))
                        expect(
                            mockStorage.read { db -> String? in
                                try OpenGroup
                                    .select(.displayPictureFilename)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).toNot(beNil())
                        expect(mockJobRunner)
                            .to(call(.exactly(times: 1), matchingParameters: .all) {
                                $0.add(
                                    .any,
                                    job: Job(
                                        variant: .displayPictureDownload,
                                        shouldBeUnique: true,
                                        details: DisplayPictureDownloadJob.Details(
                                            target: .community(
                                                imageId: "10",
                                                roomToken: "testRoom",
                                                server: "testServer"
                                            ),
                                            timestamp: 1234567890
                                        )
                                    ),
                                    dependantJob: nil,
                                    canStartJob: true
                                )
                            })
                    }
                    
                    // MARK: ------ does nothing if there is no room image
                    it("does nothing if there is no room image") {
                        mockStorage.write { db in
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: testPollInfo,
                                publicKey: TestConstants.publicKey,
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> String? in
                                try OpenGroup
                                    .select(.displayPictureFilename)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).to(beNil())
                    }
                }
            }
        }
        
        // MARK: - an OpenGroupManager
        describe("an OpenGroupManager") {
            // MARK: -- when handling messages
            context("when handling messages") {
                beforeEach {
                    mockStorage.write { db in
                        try testGroupThread.insert(db)
                        try testOpenGroup.insert(db)
                        try testInteraction1.insert(db)
                    }
                }
                
                // MARK: ---- updates the sequence number when there are messages
                it("updates the sequence number when there are messages") {
                    mockStorage.write { db in
                        OpenGroupManager.handleMessages(
                            db,
                            messages: [
                                OpenGroupAPI.Message(
                                    id: 1,
                                    sender: nil,
                                    posted: 123,
                                    edited: nil,
                                    deleted: nil,
                                    seqNo: 124,
                                    whisper: false,
                                    whisperMods: false,
                                    whisperTo: nil,
                                    base64EncodedData: nil,
                                    base64EncodedSignature: nil,
                                    reactions: nil
                                )
                            ],
                            for: "testRoom",
                            on: "testServer",
                            using: dependencies
                        )
                    }
                    
                    expect(
                        mockStorage.read { db -> Int64? in
                            try OpenGroup
                                .select(.sequenceNumber)
                                .asRequest(of: Int64.self)
                                .fetchOne(db)
                        }
                    ).to(equal(124))
                }
                
                // MARK: ---- does not update the sequence number if there are no messages
                it("does not update the sequence number if there are no messages") {
                    mockStorage.write { db in
                        OpenGroupManager.handleMessages(
                            db,
                            messages: [],
                            for: "testRoom",
                            on: "testServer",
                            using: dependencies
                        )
                    }
                    
                    expect(
                        mockStorage.read { db -> Int64? in
                            try OpenGroup
                                .select(.sequenceNumber)
                                .asRequest(of: Int64.self)
                                .fetchOne(db)
                        }
                    ).to(equal(5))
                }
                
                // MARK: ---- ignores a message with no sender
                it("ignores a message with no sender") {
                    mockStorage.write { db in
                        try Interaction.deleteAll(db)
                    }
                    
                    mockStorage.write { db in
                        OpenGroupManager.handleMessages(
                            db,
                            messages: [
                                OpenGroupAPI.Message(
                                    id: 1,
                                    sender: nil,
                                    posted: 123,
                                    edited: nil,
                                    deleted: nil,
                                    seqNo: 124,
                                    whisper: false,
                                    whisperMods: false,
                                    whisperTo: nil,
                                    base64EncodedData: Data([1, 2, 3]).base64EncodedString(),
                                    base64EncodedSignature: nil,
                                    reactions: nil
                                )
                            ],
                            for: "testRoom",
                            on: "testServer",
                            using: dependencies
                        )
                    }
                    
                    expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                }
                
                // MARK: ---- ignores a message with invalid data
                it("ignores a message with invalid data") {
                    mockStorage.write { db in
                        try Interaction.deleteAll(db)
                    }
                    
                    mockStorage.write { db in
                        OpenGroupManager.handleMessages(
                            db,
                            messages: [
                                OpenGroupAPI.Message(
                                    id: 1,
                                    sender: "05\(TestConstants.publicKey)",
                                    posted: 123,
                                    edited: nil,
                                    deleted: nil,
                                    seqNo: 124,
                                    whisper: false,
                                    whisperMods: false,
                                    whisperTo: nil,
                                    base64EncodedData: Data([1, 2, 3]).base64EncodedString(),
                                    base64EncodedSignature: nil,
                                    reactions: nil
                                )
                            ],
                            for: "testRoom",
                            on: "testServer",
                            using: dependencies
                        )
                    }
                    
                    expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                }
                
                // MARK: ---- processes a message with valid data
                it("processes a message with valid data") {
                    mockStorage.write { db in
                        OpenGroupManager.handleMessages(
                            db,
                            messages: [testMessage],
                            for: "testRoom",
                            on: "testServer",
                            using: dependencies
                        )
                    }
                    
                    expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(1))
                }
                
                // MARK: ---- processes valid messages when combined with invalid ones
                it("processes valid messages when combined with invalid ones") {
                    mockStorage.write { db in
                        OpenGroupManager.handleMessages(
                            db,
                            messages: [
                                OpenGroupAPI.Message(
                                    id: 2,
                                    sender: "05\(TestConstants.publicKey)",
                                    posted: 122,
                                    edited: nil,
                                    deleted: nil,
                                    seqNo: 123,
                                    whisper: false,
                                    whisperMods: false,
                                    whisperTo: nil,
                                    base64EncodedData: Data([1, 2, 3]).base64EncodedString(),
                                    base64EncodedSignature: nil,
                                    reactions: nil
                                ),
                                testMessage,
                            ],
                            for: "testRoom",
                            on: "testServer",
                            using: dependencies
                        )
                    }
                    
                    expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(1))
                }
                
                // MARK: ---- with no data
                context("with no data") {
                    // MARK: ------ deletes the message if we have the message
                    it("deletes the message if we have the message") {
                        mockStorage.write { db in
                            try Interaction
                                .updateAll(
                                    db,
                                    Interaction.Columns.openGroupServerMessageId.set(to: 127)
                                )
                        }
                        
                        mockStorage.write { db in
                            OpenGroupManager.handleMessages(
                                db,
                                messages: [
                                    OpenGroupAPI.Message(
                                        id: 127,
                                        sender: "05\(TestConstants.publicKey)",
                                        posted: 123,
                                        edited: nil,
                                        deleted: nil,
                                        seqNo: 123,
                                        whisper: false,
                                        whisperMods: false,
                                        whisperTo: nil,
                                        base64EncodedData: nil,
                                        base64EncodedSignature: nil,
                                        reactions: nil
                                    )
                                ],
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                    }
                    
                    // MARK: ------ does nothing if we do not have the message
                    it("does nothing if we do not have the message") {
                        mockStorage.write { db in
                            OpenGroupManager.handleMessages(
                                db,
                                messages: [
                                    OpenGroupAPI.Message(
                                        id: 127,
                                        sender: "05\(TestConstants.publicKey)",
                                        posted: 123,
                                        edited: nil,
                                        deleted: nil,
                                        seqNo: 123,
                                        whisper: false,
                                        whisperMods: false,
                                        whisperTo: nil,
                                        base64EncodedData: nil,
                                        base64EncodedSignature: nil,
                                        reactions: nil
                                    )
                                ],
                                for: "testRoom",
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                    }
                }
            }
            
            // MARK: -- when handling direct messages
            context("when handling direct messages") {
                beforeEach {
                    mockCrypto
                        .when {
                            $0.generate(
                                .plaintextWithSessionBlindingProtocol(
                                    .any,
                                    ciphertext: .any,
                                    senderId: .any,
                                    recipientId: .any,
                                    serverPublicKey: .any,
                                    using: .any
                                )
                            )
                        }
                        .thenReturn((
                            plaintext: Data(base64Encoded:"ChQKC1Rlc3RNZXNzYWdlONCI7I/3Iw==")! +
                            Data([0x80]) +
                            Data([UInt8](repeating: 0, count: 32)),
                            senderSessionIdHex: "05\(TestConstants.publicKey)"
                        ))
                    mockCrypto
                        .when { $0.generate(.x25519(ed25519Pubkey: .any)) }
                        .thenReturn(Data(hex: TestConstants.publicKey).bytes)
                }
                
                // MARK: ---- does nothing if there are no messages
                it("does nothing if there are no messages") {
                    mockStorage.write { db in
                        OpenGroupManager.handleDirectMessages(
                            db,
                            messages: [],
                            fromOutbox: false,
                            on: "testServer",
                            using: dependencies
                        )
                    }
                    
                    expect(
                        mockStorage.read { db -> Int64? in
                            try OpenGroup
                                .select(.inboxLatestMessageId)
                                .asRequest(of: Int64.self)
                                .fetchOne(db)
                        }
                    ).to(equal(0))
                    expect(
                        mockStorage.read { db -> Int64? in
                            try OpenGroup
                                .select(.outboxLatestMessageId)
                                .asRequest(of: Int64.self)
                                .fetchOne(db)
                        }
                    ).to(equal(0))
                }
                
                // MARK: ---- does nothing if it cannot get the open group
                it("does nothing if it cannot get the open group") {
                    mockStorage.write { db in
                        try OpenGroup.deleteAll(db)
                    }
                    
                    mockStorage.write { db in
                        OpenGroupManager.handleDirectMessages(
                            db,
                            messages: [testDirectMessage],
                            fromOutbox: false,
                            on: "testServer",
                            using: dependencies
                        )
                    }
                    
                    expect(
                        mockStorage.read { db -> Int64? in
                            try OpenGroup
                                .select(.inboxLatestMessageId)
                                .asRequest(of: Int64.self)
                                .fetchOne(db)
                        }
                    ).to(beNil())
                    expect(
                        mockStorage.read { db -> Int64? in
                            try OpenGroup
                                .select(.outboxLatestMessageId)
                                .asRequest(of: Int64.self)
                                .fetchOne(db)
                        }
                    ).to(beNil())
                }
                
                // MARK: ---- ignores messages with non base64 encoded data
                it("ignores messages with non base64 encoded data") {
                    testDirectMessage = OpenGroupAPI.DirectMessage(
                        id: testDirectMessage.id,
                        sender: testDirectMessage.sender.replacingOccurrences(of: "8", with: "9"),
                        recipient: testDirectMessage.recipient,
                        posted: testDirectMessage.posted,
                        expires: testDirectMessage.expires,
                        base64EncodedMessage: "TestMessage%%%"
                    )
                    
                    mockStorage.write { db in
                        OpenGroupManager.handleDirectMessages(
                            db,
                            messages: [testDirectMessage],
                            fromOutbox: false,
                            on: "testServer",
                            using: dependencies
                        )
                    }
                    
                    expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                }
                
                // MARK: ---- for the inbox
                context("for the inbox") {
                    beforeEach {
                        mockCrypto
                            .when { $0.verify(.sessionId(.any, matchesBlindedId: .any, serverPublicKey: .any)) }
                            .thenReturn(false)
                    }
                    
                    // MARK: ------ updates the inbox latest message id
                    it("updates the inbox latest message id") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: false,
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> Int64? in
                                try OpenGroup
                                    .select(.inboxLatestMessageId)
                                    .asRequest(of: Int64.self)
                                    .fetchOne(db)
                            }
                        ).to(equal(128))
                    }
                    
                    // MARK: ------ ignores a message with invalid data
                    it("ignores a message with invalid data") {
                        mockCrypto
                            .when {
                                $0.generate(
                                    .plaintextWithSessionBlindingProtocol(
                                        .any,
                                        ciphertext: .any,
                                        senderId: .any,
                                        recipientId: .any,
                                        serverPublicKey: .any,
                                        using: .any
                                    )
                                )
                            }
                            .thenReturn((
                                plaintext: Data("TestInvalid".bytes),
                                senderSessionIdHex: "05\(TestConstants.publicKey)"
                            ))
                        
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: false,
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(0))
                    }
                    
                    // MARK: ------ processes a message with valid data
                    it("processes a message with valid data") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: false,
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(1))
                    }
                    
                    // MARK: ------ processes valid messages when combined with invalid ones
                    it("processes valid messages when combined with invalid ones") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [
                                    OpenGroupAPI.DirectMessage(
                                        id: testDirectMessage.id,
                                        sender: testDirectMessage.sender.replacingOccurrences(of: "8", with: "9"),
                                        recipient: testDirectMessage.recipient,
                                        posted: testDirectMessage.posted,
                                        expires: testDirectMessage.expires,
                                        base64EncodedMessage: Data([1, 2, 3]).base64EncodedString()
                                    ),
                                    testDirectMessage
                                ],
                                fromOutbox: false,
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try Interaction.fetchCount(db) }).to(equal(1))
                    }
                }
                
                // MARK: ---- for the outbox
                context("for the outbox") {
                    beforeEach {
                        mockCrypto
                            .when { $0.verify(.sessionId(.any, matchesBlindedId: .any, serverPublicKey: .any)) }
                            .thenReturn(false)
                    }
                    
                    // MARK: ------ updates the outbox latest message id
                    it("updates the outbox latest message id") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: true,
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(
                            mockStorage.read { db -> Int64? in
                                try OpenGroup
                                    .select(.outboxLatestMessageId)
                                    .asRequest(of: Int64.self)
                                    .fetchOne(db)
                            }
                        ).to(equal(128))
                    }
                    
                    // MARK: ------ retrieves an existing blinded id lookup
                    it("retrieves an existing blinded id lookup") {
                        mockStorage.write { db in
                            try BlindedIdLookup(
                                blindedId: "15\(TestConstants.blind15PublicKey)",
                                sessionId: "TestSessionId",
                                openGroupServer: "testserver",
                                openGroupPublicKey: "05\(TestConstants.publicKey)"
                            ).insert(db)
                        }
                        
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: true,
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try BlindedIdLookup.fetchCount(db) }).to(equal(1))
                        expect(mockStorage.read { db -> Int in try SessionThread.fetchCount(db) }).to(equal(2))
                    }
                    
                    // MARK: ------ falls back to using the blinded id if no lookup is found
                    it("falls back to using the blinded id if no lookup is found") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: true,
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try BlindedIdLookup.fetchCount(db) }).to(equal(1))
                        expect(mockStorage
                            .read { db -> String? in
                                try BlindedIdLookup
                                    .select(.sessionId)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            }
                        ).to(beNil())
                        expect(mockStorage.read { db -> Int in try SessionThread.fetchCount(db) }).to(equal(2))
                        expect(
                            mockStorage.read { db -> SessionThread? in
                                try SessionThread.fetchOne(db, id: "15\(TestConstants.blind15PublicKey)")
                            }
                        ).toNot(beNil())
                    }
                    
                    // MARK: ------ ignores a message with invalid data
                    it("ignores a message with invalid data") {
                        mockCrypto
                            .when {
                                $0.generate(
                                    .plaintextWithSessionBlindingProtocol(
                                        .any,
                                        ciphertext: .any,
                                        senderId: .any,
                                        recipientId: .any,
                                        serverPublicKey: .any,
                                        using: .any
                                    )
                                )
                            }
                            .thenReturn((
                                plaintext: Data("TestInvalid".bytes),
                                senderSessionIdHex: "05\(TestConstants.publicKey)"
                            ))
                        
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: true,
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try SessionThread.fetchCount(db) }).to(equal(1))
                    }
                    
                    // MARK: ------ processes a message with valid data
                    it("processes a message with valid data") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [testDirectMessage],
                                fromOutbox: true,
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try SessionThread.fetchCount(db) }).to(equal(2))
                    }
                    
                    // MARK: ------ processes valid messages when combined with invalid ones
                    it("processes valid messages when combined with invalid ones") {
                        mockStorage.write { db in
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: [
                                    OpenGroupAPI.DirectMessage(
                                        id: testDirectMessage.id,
                                        sender: testDirectMessage.sender.replacingOccurrences(of: "8", with: "9"),
                                        recipient: testDirectMessage.recipient,
                                        posted: testDirectMessage.posted,
                                        expires: testDirectMessage.expires,
                                        base64EncodedMessage: Data([1, 2, 3]).base64EncodedString()
                                    ),
                                    testDirectMessage
                                ],
                                fromOutbox: true,
                                on: "testServer",
                                using: dependencies
                            )
                        }
                        
                        expect(mockStorage.read { db -> Int in try SessionThread.fetchCount(db) }).to(equal(2))
                    }
                }
            }
        }
        
        // MARK: - an OpenGroupManager
        describe("an OpenGroupManager") {
            // MARK: -- when determining if a user is a moderator or an admin
            context("when determining if a user is a moderator or an admin") {
                beforeEach {
                    mockStorage.write { db in
                        _ = try GroupMember.deleteAll(db)
                    }
                }
                
                // MARK: ---- uses an empty set for moderators by default
                it("uses an empty set for moderators by default") {
                    expect(
                        mockStorage.read { db in
                            openGroupManager.isUserModeratorOrAdmin(
                                db,
                                publicKey: "05\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer"
                            )
                        }
                    ).to(beFalse())
                }
                
                // MARK: ---- uses an empty set for admins by default
                it("uses an empty set for admins by default") {
                    expect(
                        mockStorage.read { db in
                            openGroupManager.isUserModeratorOrAdmin(
                                db,
                                publicKey: "05\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer"
                            )
                        }
                    ).to(beFalse())
                }
                
                // MARK: ---- returns true if the key is in the moderator set
                it("returns true if the key is in the moderator set") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                            profileId: "05\(TestConstants.publicKey)",
                            role: .moderator,
                            roleStatus: .accepted,
                            isHidden: false
                        ).insert(db)
                    }
                    
                    expect(
                        mockStorage.read { db in
                            openGroupManager.isUserModeratorOrAdmin(
                                db,
                                publicKey: "05\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer"
                            )
                        }
                    ).to(beTrue())
                }
                
                // MARK: ---- returns true if the key is in the admin set
                it("returns true if the key is in the admin set") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                            profileId: "05\(TestConstants.publicKey)",
                            role: .admin,
                            roleStatus: .accepted,
                            isHidden: false
                        ).insert(db)
                    }
                    
                    expect(
                        mockStorage.read { db in
                            openGroupManager.isUserModeratorOrAdmin(
                                db,
                                publicKey: "05\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer"
                            )
                        }
                    ).to(beTrue())
                }
                
                // MARK: ---- returns true if the moderator is hidden
                it("returns true if the moderator is hidden") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                            profileId: "05\(TestConstants.publicKey)",
                            role: .moderator,
                            roleStatus: .accepted,
                            isHidden: true
                        ).insert(db)
                    }
                    
                    expect(
                        mockStorage.read { db in
                            openGroupManager.isUserModeratorOrAdmin(
                                db,
                                publicKey: "05\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer"
                            )
                        }
                    ).to(beTrue())
                }
                
                // MARK: ---- returns true if the admin is hidden
                it("returns true if the admin is hidden") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                            profileId: "05\(TestConstants.publicKey)",
                            role: .admin,
                            roleStatus: .accepted,
                            isHidden: true
                        ).insert(db)
                    }
                    
                    expect(
                        mockStorage.read { db in
                            openGroupManager.isUserModeratorOrAdmin(
                                db,
                                publicKey: "05\(TestConstants.publicKey)",
                                for: "testRoom",
                                on: "testServer"
                            )
                        }
                    ).to(beTrue())
                }
                
                // MARK: ---- returns false if the key is not a valid session id
                it("returns false if the key is not a valid session id") {
                    expect(
                        mockStorage.read { db in
                            openGroupManager.isUserModeratorOrAdmin(
                                db,
                                publicKey: "InvalidValue",
                                for: "testRoom",
                                on: "testServer"
                            )
                        }
                    ).to(beFalse())
                }
                
                // MARK: ---- and the key is a standard session id
                context("and the key is a standard session id") {
                    // MARK: ------ returns false if the key is not the users session id
                    it("returns false if the key is not the users session id") {
                        mockStorage.write { db in
                            let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                            
                            try Identity(variant: .x25519PublicKey, data: Data(hex: otherKey)).upsert(db)
                            try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).upsert(db)
                        }
                        
                        expect(
                            mockStorage.read { db in
                                openGroupManager.isUserModeratorOrAdmin(
                                    db,
                                    publicKey: "05\(TestConstants.publicKey)",
                                    for: "testRoom",
                                    on: "testServer"
                                )
                            }
                        ).to(beFalse())
                    }
                    
                    // MARK: ------ returns true if the key is the current users and the users unblinded id is a moderator or admin
                    it("returns true if the key is the current users and the users unblinded id is a moderator or admin") {
                        mockStorage.write { db in
                            let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                            
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                profileId: "00\(otherKey)",
                                role: .moderator,
                                roleStatus: .accepted,
                                isHidden: false
                            ).insert(db)
                            
                            try Identity(variant: .ed25519PublicKey, data: Data(hex: otherKey)).upsert(db)
                            try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).upsert(db)
                        }
                        
                        expect(
                            mockStorage.read { db in
                                openGroupManager.isUserModeratorOrAdmin(
                                    db,
                                    publicKey: "05\(TestConstants.publicKey)",
                                    for: "testRoom",
                                    on: "testServer"
                                )
                            }
                        ).to(beTrue())
                    }
                    
                    // MARK: ------ returns true if the key is the current users and the users blinded id is a moderator or admin
                    it("returns true if the key is the current users and the users blinded id is a moderator or admin") {
                        let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                        mockCrypto
                            .when { $0.generate(.blinded15KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
                            .thenReturn(
                                KeyPair(
                                    publicKey: Data(hex: otherKey).bytes,
                                    secretKey: Data(hex: TestConstants.edSecretKey).bytes
                                )
                            )
                        mockStorage.write { db in
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                profileId: "15\(otherKey)",
                                role: .moderator,
                                roleStatus: .accepted,
                                isHidden: false
                            ).insert(db)
                        }
                        
                        expect(
                            mockStorage.read { db in
                                openGroupManager.isUserModeratorOrAdmin(
                                    db,
                                    publicKey: "05\(TestConstants.publicKey)",
                                    for: "testRoom",
                                    on: "testServer"
                                )
                            }
                        ).to(beTrue())
                    }
                }
                
                // MARK: ---- and the key is unblinded
                context("and the key is unblinded") {
                    // MARK: ------ returns false if unable to retrieve the user ed25519 key
                    it("returns false if unable to retrieve the user ed25519 key") {
                        mockStorage.write { db in
                            try Identity.filter(id: .ed25519PublicKey).deleteAll(db)
                            try Identity.filter(id: .ed25519SecretKey).deleteAll(db)
                        }
                        
                        expect(
                            mockStorage.read { db in
                                openGroupManager.isUserModeratorOrAdmin(
                                    db,
                                    publicKey: "00\(TestConstants.publicKey)",
                                    for: "testRoom",
                                    on: "testServer"
                                )
                            }
                        ).to(beFalse())
                    }
                    
                    // MARK: ------ returns false if the key is not the users unblinded id
                    it("returns false if the key is not the users unblinded id") {
                        mockStorage.write { db in
                            let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                            
                            try Identity(variant: .ed25519PublicKey, data: Data(hex: otherKey)).upsert(db)
                            try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).upsert(db)
                        }
                        
                        expect(
                            mockStorage.read { db in
                                openGroupManager.isUserModeratorOrAdmin(
                                    db,
                                    publicKey: "00\(TestConstants.publicKey)",
                                    for: "testRoom",
                                    on: "testServer"
                                )
                            }
                        ).to(beFalse())
                    }
                    
                    // MARK: ------ returns true if the key is the current users and the users session id is a moderator or admin
                    it("returns true if the key is the current users and the users session id is a moderator or admin") {
                        let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                        mockGeneralCache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: otherKey))
                        mockStorage.write { db in
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                profileId: "05\(otherKey)",
                                role: .moderator,
                                roleStatus: .accepted,
                                isHidden: false
                            ).insert(db)
                            
                            try Identity(variant: .x25519PublicKey, data: Data(hex: otherKey)).upsert(db)
                            try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).upsert(db)
                            try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.publicKey)).upsert(db)
                            try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).upsert(db)
                        }
                        
                        expect(
                            mockStorage.read { db in
                                openGroupManager.isUserModeratorOrAdmin(
                                    db,
                                    publicKey: "00\(TestConstants.publicKey)",
                                    for: "testRoom",
                                    on: "testServer"
                                )
                            }
                        ).to(beTrue())
                    }
                    
                    // MARK: ------ returns true if the key is the current users and the users blinded id is a moderator or admin
                    it("returns true if the key is the current users and the users blinded id is a moderator or admin") {
                        let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                        mockCrypto
                            .when { $0.generate(.blinded15KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
                            .thenReturn(
                                KeyPair(
                                    publicKey: Data(hex: otherKey).bytes,
                                    secretKey: Data(hex: TestConstants.edSecretKey).bytes
                                )
                            )
                        mockStorage.write { db in
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                profileId: "15\(otherKey)",
                                role: .moderator,
                                roleStatus: .accepted,
                                isHidden: false
                            ).insert(db)
                            
                            try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).upsert(db)
                            try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).upsert(db)
                            try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.publicKey)).upsert(db)
                            try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).upsert(db)
                        }
                        
                        expect(
                            mockStorage.read { db in
                                openGroupManager.isUserModeratorOrAdmin(
                                    db,
                                    publicKey: "00\(TestConstants.publicKey)",
                                    for: "testRoom",
                                    on: "testServer"
                                )
                            }
                        ).to(beTrue())
                    }
                }
                
                // MARK: ---- and the key is blinded
                context("and the key is blinded") {
                    // MARK: ------ returns false if unable to retrieve the user ed25519 key
                    it("returns false if unable to retrieve the user ed25519 key") {
                        mockStorage.write { db in
                            try Identity.filter(id: .ed25519PublicKey).deleteAll(db)
                            try Identity.filter(id: .ed25519SecretKey).deleteAll(db)
                        }
                        
                        expect(
                            mockStorage.read { db in
                                openGroupManager.isUserModeratorOrAdmin(
                                    db,
                                    publicKey: "15\(TestConstants.publicKey)",
                                    for: "testRoom",
                                    on: "testServer"
                                )
                            }
                        ).to(beFalse())
                    }
                    
                    // MARK: ------ returns false if unable generate a blinded key
                    it("returns false if unable generate a blinded key") {
                        mockCrypto
                            .when { $0.generate(.blinded15KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
                            .thenReturn(nil)
                        
                        expect(
                            mockStorage.read { db in
                                openGroupManager.isUserModeratorOrAdmin(
                                    db,
                                    publicKey: "15\(TestConstants.publicKey)",
                                    for: "testRoom",
                                    on: "testServer"
                                )
                            }
                        ).to(beFalse())
                    }
                    
                    // MARK: ------ returns false if the key is not the users blinded id
                    it("returns false if the key is not the users blinded id") {
                        let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                        mockCrypto
                            .when { $0.generate(.blinded15KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
                            .thenReturn(
                                KeyPair(
                                    publicKey: Data(hex: otherKey).bytes,
                                    secretKey: Data(hex: TestConstants.edSecretKey).bytes
                                )
                            )
                        
                        expect(
                            mockStorage.read { db in
                                openGroupManager.isUserModeratorOrAdmin(
                                    db,
                                    publicKey: "15\(TestConstants.publicKey)",
                                    for: "testRoom",
                                    on: "testServer"
                                )
                            }
                        ).to(beFalse())
                    }
                    
                    // MARK: ------ returns true if the key is the current users and the users session id is a moderator or admin
                    it("returns true if the key is the current users and the users session id is a moderator or admin") {
                        let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                        mockGeneralCache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: otherKey))
                        mockCrypto
                            .when { $0.generate(.blinded15KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
                            .thenReturn(
                                KeyPair(
                                    publicKey: Data(hex: TestConstants.publicKey).bytes,
                                    secretKey: Data(hex: TestConstants.edSecretKey).bytes
                                )
                            )
                        mockStorage.write { db in
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                profileId: "05\(otherKey)",
                                role: .moderator,
                                roleStatus: .accepted,
                                isHidden: false
                            ).insert(db)
                            
                            try Identity(variant: .x25519PublicKey, data: Data(hex: otherKey)).upsert(db)
                            try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).upsert(db)
                            try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.publicKey)).upsert(db)
                            try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).upsert(db)
                        }
                        
                        expect(
                            mockStorage.read { db in
                                openGroupManager.isUserModeratorOrAdmin(
                                    db,
                                    publicKey: "15\(TestConstants.publicKey)",
                                    for: "testRoom",
                                    on: "testServer"
                                )
                            }
                        ).to(beTrue())
                    }
                    
                    // MARK: ------ returns true if the key is the current users and the users unblinded id is a moderator or admin
                    it("returns true if the key is the current users and the users unblinded id is a moderator or admin") {
                        mockCrypto
                            .when { $0.generate(.blinded15KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
                            .thenReturn(
                                KeyPair(
                                    publicKey: Data(hex: TestConstants.publicKey).bytes,
                                    secretKey: Data(hex: TestConstants.edSecretKey).bytes
                                )
                            )
                        mockStorage.write { db in
                            let otherKey: String = TestConstants.publicKey.replacingOccurrences(of: "7", with: "6")
                            
                            try GroupMember(
                                groupId: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                profileId: "00\(otherKey)",
                                role: .moderator,
                                roleStatus: .accepted,
                                isHidden: false
                            ).insert(db)
                            
                            try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).upsert(db)
                            try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).upsert(db)
                            try Identity(variant: .ed25519PublicKey, data: Data(hex: otherKey)).upsert(db)
                            try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).upsert(db)
                        }
                        
                        expect(
                            mockStorage.read { db in
                                openGroupManager.isUserModeratorOrAdmin(
                                    db,
                                    publicKey: "15\(TestConstants.publicKey)",
                                    for: "testRoom",
                                    on: "testServer"
                                )
                            }
                        ).to(beTrue())
                    }
                }
            }
            
            // MARK: -- when accessing the default rooms publisher
            context("when accessing the default rooms publisher") {
                // MARK: ---- starts a job to retrieve the default rooms if we have none
                it("starts a job to retrieve the default rooms if we have none") {
                    mockAppGroupDefaults.when { $0.bool(forKey: UserDefaults.BoolKey.isMainAppActive.rawValue) }.thenReturn(true)
                    mockStorage.write { db in
                        try OpenGroup(
                            server: OpenGroupAPI.defaultServer,
                            roomToken: "",
                            publicKey: OpenGroupAPI.defaultServerPublicKey,
                            isActive: false,
                            name: "TestExisting",
                            userCount: 0,
                            infoUpdates: 0
                        )
                        .insert(db)
                    }
                    let expectedRequest: Network.PreparedRequest<OpenGroupAPI.CapabilitiesAndRoomsResponse>! = mockStorage.read { db in
                        try OpenGroupAPI.preparedCapabilitiesAndRooms(
                            db,
                            on: OpenGroupAPI.defaultServer,
                            using: dependencies
                        )
                    }
                    cache.defaultRoomsPublisher.sinkUntilComplete()
                    
                    expect(mockNetwork)
                        .to(call { network in
                            network.send(
                                expectedRequest.body,
                                to: expectedRequest.destination,
                                requestTimeout: expectedRequest.requestTimeout,
                                requestAndPathBuildTimeout: expectedRequest.requestAndPathBuildTimeout
                            )
                        })
                }
                
                // MARK: ---- does not start a job to retrieve the default rooms if we already have rooms
                it("does not start a job to retrieve the default rooms if we already have rooms") {
                    mockAppGroupDefaults.when { $0.bool(forKey: UserDefaults.BoolKey.isMainAppActive.rawValue) }.thenReturn(true)
                    cache.setDefaultRoomInfo([(room: OpenGroupAPI.Room.mock, openGroup: OpenGroup.mock)])
                    cache.defaultRoomsPublisher.sinkUntilComplete()
                    
                    expect(mockNetwork)
                        .toNot(call { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) })
                }
            }
        }
    }
}

// MARK: - Convenience Extensions

extension OpenGroupAPI.Room {
    func with(
        token: String? = nil,
        name: String? = nil,
        infoUpdates: Int64? = nil,
        imageId: String? = nil,
        moderators: [String]? = nil,
        hiddenModerators: [String]? = nil,
        admins: [String]? = nil,
        hiddenAdmins: [String]? = nil
    ) -> OpenGroupAPI.Room {
        return OpenGroupAPI.Room(
            token: (token ?? self.token),
            name: (name ?? self.name),
            roomDescription: self.roomDescription,
            infoUpdates: (infoUpdates ?? self.infoUpdates),
            messageSequence: self.messageSequence,
            created: self.created,
            activeUsers: self.activeUsers,
            activeUsersCutoff: self.activeUsersCutoff,
            imageId: (imageId ?? self.imageId),
            pinnedMessages: self.pinnedMessages,
            admin: self.admin,
            globalAdmin: self.globalAdmin,
            admins: (admins ?? self.admins),
            hiddenAdmins: (hiddenAdmins ?? self.hiddenAdmins),
            moderator: self.moderator,
            globalModerator: self.globalModerator,
            moderators: (moderators ?? self.moderators),
            hiddenModerators: (hiddenModerators ?? self.hiddenModerators),
            read: self.read,
            defaultRead: self.defaultRead,
            defaultAccessible: self.defaultAccessible,
            write: self.write,
            defaultWrite: self.defaultWrite,
            upload: self.upload,
            defaultUpload: self.defaultUpload
        )
    }
}

extension OpenGroupAPI.RoomPollInfo {
    func with(
        token: String? = nil,
        activeUsers: Int64? = nil,
        details: OpenGroupAPI.Room? = .mock
    ) -> OpenGroupAPI.RoomPollInfo {
        return OpenGroupAPI.RoomPollInfo(
            token: (token ?? self.token),
            activeUsers: (activeUsers ?? self.activeUsers),
            admin: self.admin,
            globalAdmin: self.globalAdmin,
            moderator: self.moderator,
            globalModerator: self.globalModerator,
            read: self.read,
            defaultRead: self.defaultRead,
            defaultAccessible: self.defaultAccessible,
            write: self.write,
            defaultWrite: self.defaultWrite,
            upload: self.upload,
            defaultUpload: self.defaultUpload,
            details: details
        )
    }
}

// MARK: - Mock Types

extension OpenGroup: Mocked {
    static var mock: OpenGroup = OpenGroup(
        server: "testserver",
        roomToken: "testRoom",
        publicKey: TestConstants.serverPublicKey,
        isActive: true,
        name: "testRoom",
        userCount: 0,
        infoUpdates: 0
    )
}

extension OpenGroupAPI.Capabilities: Mocked {
    static var mock: OpenGroupAPI.Capabilities = OpenGroupAPI.Capabilities(capabilities: [], missing: nil)
}

extension OpenGroupAPI.Room: Mocked {
    static var mock: OpenGroupAPI.Room = OpenGroupAPI.Room(
        token: "test",
        name: "testRoom",
        roomDescription: nil,
        infoUpdates: 1,
        messageSequence: 1,
        created: 1,
        activeUsers: 1,
        activeUsersCutoff: 1,
        imageId: nil,
        pinnedMessages: nil,
        admin: false,
        globalAdmin: false,
        admins: [],
        hiddenAdmins: nil,
        moderator: false,
        globalModerator: false,
        moderators: [],
        hiddenModerators: nil,
        read: true,
        defaultRead: nil,
        defaultAccessible: nil,
        write: true,
        defaultWrite: nil,
        upload: true,
        defaultUpload: nil
    )
}

extension OpenGroupAPI.RoomPollInfo: Mocked {
    static var mock: OpenGroupAPI.RoomPollInfo = OpenGroupAPI.RoomPollInfo(
        token: "test",
        activeUsers: 1,
        admin: false,
        globalAdmin: false,
        moderator: false,
        globalModerator: false,
        read: true,
        defaultRead: nil,
        defaultAccessible: nil,
        write: true,
        defaultWrite: nil,
        upload: true,
        defaultUpload: false,
        details: .mock
    )
}

extension OpenGroupAPI.Message: Mocked {
    static var mock: OpenGroupAPI.Message = OpenGroupAPI.Message(
        id: 100,
        sender: TestConstants.blind15PublicKey,
        posted: 1,
        edited: nil,
        deleted: nil,
        seqNo: 1,
        whisper: false,
        whisperMods: false,
        whisperTo: nil,
        base64EncodedData: nil,
        base64EncodedSignature: nil,
        reactions: nil
    )
}

extension OpenGroupAPI.SendDirectMessageResponse: Mocked {
    static var mock: OpenGroupAPI.SendDirectMessageResponse = OpenGroupAPI.SendDirectMessageResponse(
        id: 1,
        sender: TestConstants.blind15PublicKey,
        recipient: "testRecipient",
        posted: 1122,
        expires: 2233
    )
}

extension OpenGroupAPI.DirectMessage: Mocked {
    static var mock: OpenGroupAPI.DirectMessage = OpenGroupAPI.DirectMessage(
        id: 101,
        sender: TestConstants.blind15PublicKey,
        recipient: "testRecipient",
        posted: 1212,
        expires: 2323,
        base64EncodedMessage: "TestMessage".data(using: .utf8)!.base64EncodedString()
    )
}
                        
extension Network.BatchResponse {
    static let mockUnblindedPollResponse: AnyPublisher<(ResponseInfoType, Data?), Error> = MockNetwork.batchResponseData(
        with: [
            (OpenGroupAPI.Endpoint.capabilities, OpenGroupAPI.Capabilities.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.roomPollInfo("testRoom", 0), OpenGroupAPI.RoomPollInfo.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.roomMessagesRecent("testRoom"), [OpenGroupAPI.Message].mockBatchSubResponse())
        ]
    )
    
    static let mockBlindedPollResponse: AnyPublisher<(ResponseInfoType, Data?), Error> = MockNetwork.batchResponseData(
        with: [
            (OpenGroupAPI.Endpoint.capabilities, OpenGroupAPI.Capabilities.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.roomPollInfo("testRoom", 0), OpenGroupAPI.RoomPollInfo.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.roomMessagesRecent("testRoom"), OpenGroupAPI.Message.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.inboxSince(id: 0), OpenGroupAPI.DirectMessage.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.outboxSince(id: 0), OpenGroupAPI.DirectMessage.self.mockBatchSubResponse())
        ]
    )
    
    static let mockCapabilitiesResponse: AnyPublisher<(ResponseInfoType, Data?), Error> = MockNetwork.batchResponseData(
        with: [
            (OpenGroupAPI.Endpoint.capabilities, OpenGroupAPI.Capabilities.mockBatchSubResponse())
        ]
    )
    
    static let mockRoomResponse: AnyPublisher<(ResponseInfoType, Data?), Error> = MockNetwork.batchResponseData(
        with: [
            (OpenGroupAPI.Endpoint.capabilities, OpenGroupAPI.Room.mockBatchSubResponse())
        ]
    )
    
    static let mockBanAndDeleteAllResponse: AnyPublisher<(ResponseInfoType, Data?), Error> = MockNetwork.batchResponseData(
        with: [
            (OpenGroupAPI.Endpoint.userBan(""), NoResponse.mockBatchSubResponse()),
            (OpenGroupAPI.Endpoint.roomDeleteMessages("testRoon", sessionId: ""), NoResponse.mockBatchSubResponse())
        ]
    )
}
