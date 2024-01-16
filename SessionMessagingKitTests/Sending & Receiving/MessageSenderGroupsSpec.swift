// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtil
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit
@testable import SessionSnodeKit

class MessageSenderGroupsSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        let groupSeed: Data = Data(hex: "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210")
        let groupKeyPair: KeyPair = Crypto().generate(.ed25519KeyPair(seed: Array(groupSeed)))!
        @TestState var groupId: SessionId! = SessionId(.group, hex: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece")
        @TestState var groupSecretKey: Data! = Data(hex:
            "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210" +
            "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
        )
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
            dependencies.setMockableValue(JSONEncoder.OutputFormatting.sortedKeys)  // Deterministic ordering
        }
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
                
                try Profile(
                    id: "05\(TestConstants.publicKey)",
                    name: "TestCurrentUser"
                ).insert(db)
            }
        )
        @TestState(defaults: .standard, in: dependencies) var mockUserDefaults: MockUserDefaults! = MockUserDefaults(
            initialSetup: { userDefaults in
                userDefaults.when { $0.string(forKey: .any) }.thenReturn(nil)
            }
        )
        @TestState(singleton: .jobRunner, in: dependencies) var mockJobRunner: MockJobRunner! = MockJobRunner(
            initialSetup: { jobRunner in
                jobRunner
                    .when { $0.jobInfoFor(jobs: .any, state: .any, variant: .any) }
                    .thenReturn([:])
                jobRunner
                    .when { $0.add(.any, job: .any, dependantJob: .any, canStartJob: .any, using: .any) }
                    .thenReturn(nil)
            }
        )
        @TestState(singleton: .network, in: dependencies) var mockNetwork: MockNetwork! = MockNetwork(
            initialSetup: { network in
                network
                    .when { $0.send(.selectedNetworkRequest(.any, to: .any, timeout: .any, using: .any)) }
                    .thenReturn(HTTP.BatchResponse.mockConfigSyncResponse)
                network
                    .when { $0.send(.selectedNetworkRequest(.any, to: .any, with: .any, timeout: .any, using: .any)) }
                    .thenReturn(MockNetwork.response(with: FileUploadResponse(id: "1")))
            }
        )
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto
                    .when { $0.generate(.ed25519KeyPair()) }
                    .thenReturn(
                        KeyPair(
                            publicKey: Data(hex: groupId.hexString).bytes,
                            secretKey: groupSecretKey.bytes
                        )
                    )
                crypto
                    .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                    .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
                crypto
                    .when { $0.generate(.memberAuthData(config: .any, groupSessionId: .any, memberId: .any)) }
                    .thenReturn(Authentication.Info.groupMember(
                        groupSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                        authData: "TestAuthData".data(using: .utf8)!
                    ))
                crypto
                    .when { $0.generate(.tokenSubaccount(config: .any, groupSessionId: .any, memberId: .any)) }
                    .thenReturn(Array("TestSubAccountToken".data(using: .utf8)!))
                crypto
                    .when { $0.generate(.randomBytes(.any)) }
                    .thenReturn(Data((0..<DisplayPictureManager.aes256KeyByteLength).map { _ in 1 }))
                crypto
                    .when { $0.generate(.uuid()) }
                    .thenReturn(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
                crypto
                    .when { $0.generate(.encryptedDataDisplayPicture(data: .any, key: .any, using: .any)) }
                    .thenReturn(TestConstants.validImageData)
            }
        )
        @TestState(singleton: .keychain, in: dependencies) var mockKeychain: MockKeychain! = MockKeychain(
            initialSetup: { keychain in
                keychain
                    .when { try $0.data(forService: .pushNotificationAPI, key: .pushNotificationEncryptionKey) }
                    .thenReturn(Data((0..<PushNotificationAPI.encryptionKeyLength).map { _ in 1 }))
            }
        )
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
            }
        )
        @TestState var secretKey: [UInt8]! = Array(Data(hex: TestConstants.edSecretKey))
        @TestState var groupEdPK: [UInt8]! = groupKeyPair.publicKey
        @TestState var groupEdSK: [UInt8]! = groupKeyPair.secretKey
        @TestState var userGroupsConfig: LibSession.Config! = {
            var userGroupsConf: UnsafeMutablePointer<config_object>!
            _ = user_groups_init(&userGroupsConf, &secretKey, nil, 0, nil)
            
            return .object(userGroupsConf)
        }()
        @TestState var groupInfoConf: UnsafeMutablePointer<config_object>! = {
            var groupInfoConf: UnsafeMutablePointer<config_object>!
            _ = groups_info_init(&groupInfoConf, &groupEdPK, &groupEdSK, nil, 0, nil)
            
            return groupInfoConf
        }()
        @TestState var groupMembersConf: UnsafeMutablePointer<config_object>! = {
            var groupMembersConf: UnsafeMutablePointer<config_object>!
            _ = groups_members_init(&groupMembersConf, &groupEdPK, &groupEdSK, nil, 0, nil)
            
            return groupMembersConf
        }()
        @TestState var groupKeysConf: UnsafeMutablePointer<config_group_keys>! = {
            var groupKeysConf: UnsafeMutablePointer<config_group_keys>!
            _ = groups_keys_init(&groupKeysConf, &secretKey, &groupEdPK, &groupEdSK, groupInfoConf, groupMembersConf, nil, 0, nil)
            
            return groupKeysConf
        }()
        @TestState var groupInfoConfig: LibSession.Config! = .object(groupInfoConf)
        @TestState var groupMembersConfig: LibSession.Config! = .object(groupMembersConf)
        @TestState var groupKeysConfig: LibSession.Config! = {
            return .groupKeys(groupKeysConf, info: groupInfoConf, members: groupMembersConf)
        }()
        @TestState(cache: .libSession, in: dependencies) var mockLibSessionCache: MockLibSessionCache! = MockLibSessionCache(
            initialSetup: { cache in
                let userSessionId: SessionId = SessionId(.standard, hex: TestConstants.publicKey)
                
                cache
                    .when { $0.setConfig(for: .any, sessionId: .any, to: .any) }
                    .thenReturn(())
                cache
                    .when { $0.config(for: .userGroups, sessionId: userSessionId) }
                    .thenReturn(Atomic(userGroupsConfig))
                cache
                    .when { $0.config(for: .groupInfo, sessionId: groupId) }
                    .thenReturn(Atomic(groupInfoConfig))
                cache
                    .when { $0.config(for: .groupMembers, sessionId: groupId) }
                    .thenReturn(Atomic(groupMembersConfig))
                cache
                    .when { $0.config(for: .groupKeys, sessionId: groupId) }
                    .thenReturn(Atomic(groupKeysConfig))
            }
        )
        @TestState var mockSwarmCache: Set<Snode>! = [
            Snode(
                address: "test",
                port: 0,
                ed25519PublicKey: TestConstants.edPublicKey,
                x25519PublicKey: TestConstants.publicKey
            ),
            Snode(
                address: "test",
                port: 1,
                ed25519PublicKey: TestConstants.edPublicKey,
                x25519PublicKey: TestConstants.publicKey
            ),
            Snode(
                address: "test",
                port: 2,
                ed25519PublicKey: TestConstants.edPublicKey,
                x25519PublicKey: TestConstants.publicKey
            )
        ]
        @TestState(cache: .snodeAPI, in: dependencies) var mockSnodeAPICache: MockSnodeAPICache! = MockSnodeAPICache(
            initialSetup: { cache in
                cache.when { $0.clockOffsetMs }.thenReturn(0)
                cache.when { $0.loadedSwarms }.thenReturn([groupId.hexString])
                cache.when { $0.swarmCache }.thenReturn([groupId.hexString: mockSwarmCache])
            }
        )
        @TestState(singleton: .groupsPoller, in: dependencies) var mockGroupsPoller: MockPoller! = MockPoller(
            initialSetup: { poller in
                poller
                    .when { $0.startIfNeeded(for: .any, using: .any) }
                    .thenReturn(())
            }
        )
        @TestState var disposables: [AnyCancellable]! = []
        @TestState var error: Error?
        @TestState var thread: SessionThread?
        
        // MARK: - a MessageSender dealing with Groups
        describe("a MessageSender dealing with Groups") {
            // MARK: -- when creating a group
            context("when creating a group") {
                // MARK: ---- loads the state into the cache
                it("loads the state into the cache") {
                    MessageSender
                        .createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPictureData: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .sinkAndStore(in: &disposables)
                    
                    expect(mockLibSessionCache)
                        .to(call(.exactly(times: 1), matchingParameters: .atLeast(2)) { cache in
                            cache.setConfig(for: .groupInfo, sessionId: groupId, to: .any)
                        })
                    expect(mockLibSessionCache)
                        .to(call(.exactly(times: 1), matchingParameters: .atLeast(2)) { cache in
                            cache.setConfig(for: .groupMembers, sessionId: groupId, to: .any)
                        })
                    expect(mockLibSessionCache)
                        .to(call(.exactly(times: 1), matchingParameters: .atLeast(2)) { cache in
                            cache.setConfig(for: .groupKeys, sessionId: groupId, to: .any)
                        })
                }
                
                // MARK: ---- returns the created thread
                it("returns the created thread") {
                    MessageSender
                        .createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPictureData: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .handleEvents(receiveOutput: { result in thread = result })
                        .mapError { error.setting(to: $0) }
                        .sinkAndStore(in: &disposables)
                    
                    expect(error).to(beNil())
                    expect(thread).toNot(beNil())
                    expect(thread?.id).to(equal(groupId.hexString))
                    expect(thread?.variant).to(equal(.group))
                    expect(thread?.creationDateTimestamp).to(equal(1234567890))
                    expect(thread?.shouldBeVisible).to(beTrue())
                    expect(thread?.messageDraft).to(beNil())
                    expect(thread?.markedAsUnread).to(beFalse())
                    expect(thread?.pinnedPriority).to(equal(0))
                }
                
                // MARK: ---- stores the thread in the db
                it("stores the thread in the db") {
                    MessageSender
                        .createGroup(
                            name: "Test",
                            description: nil,
                            displayPictureData: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .handleEvents(receiveOutput: { result in thread = result })
                        .sinkAndStore(in: &disposables)
                    
                    let dbValue: SessionThread? = mockStorage.read { db in try SessionThread.fetchOne(db) }
                    expect(dbValue).to(equal(thread))
                    expect(dbValue?.id).to(equal(groupId.hexString))
                    expect(dbValue?.variant).to(equal(.group))
                    expect(dbValue?.creationDateTimestamp).to(equal(1234567890))
                    expect(dbValue?.shouldBeVisible).to(beTrue())
                    expect(dbValue?.notificationSound).to(beNil())
                    expect(dbValue?.mutedUntilTimestamp).to(beNil())
                    expect(dbValue?.onlyNotifyForMentions).to(beFalse())
                    expect(dbValue?.pinnedPriority).to(equal(0))
                }
                
                // MARK: ---- stores the group in the db
                it("stores the group in the db") {
                    MessageSender
                        .createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPictureData: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .sinkAndStore(in: &disposables)
                    
                    let dbValue: ClosedGroup? = mockStorage.read { db in try ClosedGroup.fetchOne(db) }
                    expect(dbValue?.id).to(equal(groupId.hexString))
                    expect(dbValue?.name).to(equal("TestGroupName"))
                    expect(dbValue?.formationTimestamp).to(equal(1234567890))
                    expect(dbValue?.displayPictureUrl).to(beNil())
                    expect(dbValue?.displayPictureFilename).to(beNil())
                    expect(dbValue?.displayPictureEncryptionKey).to(beNil())
                    expect(dbValue?.lastDisplayPictureUpdate).to(equal(1234567890))
                    expect(dbValue?.groupIdentityPrivateKey?.toHexString()).to(equal(groupSecretKey.toHexString()))
                    expect(dbValue?.authData).to(beNil())
                    expect(dbValue?.invited).to(beFalse())
                }
                
                // MARK: ---- stores the group members in the db
                it("stores the group members in the db") {
                    MessageSender
                        .createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPictureData: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .sinkAndStore(in: &disposables)
                    
                    expect(mockStorage.read { db in try GroupMember.fetchSet(db) })
                        .to(equal([
                            GroupMember(
                                groupId: groupId.hexString,
                                profileId: "051111111111111111111111111111111111111111111111111111111111111111",
                                role: .standard,
                                roleStatus: .pending,
                                isHidden: false
                            ),
                            GroupMember(
                                groupId: groupId.hexString,
                                profileId: "05\(TestConstants.publicKey)",
                                role: .admin,
                                roleStatus: .accepted,
                                isHidden: false
                            )
                        ]))
                }
                
                // MARK: ---- starts the group poller
                it("starts the group poller") {
                    MessageSender
                        .createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPictureData: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .sinkAndStore(in: &disposables)
                    
                    expect(mockGroupsPoller)
                        .to(call(.exactly(times: 1), matchingParameters: .all) { poller in
                            poller.startIfNeeded(for: groupId.hexString, using: .any)
                        })
                }
                
                // MARK: ---- syncs the group configuration messages
                it("syncs the group configuration messages") {
                    let expectedRequest: URLRequest = mockStorage
                        .write(using: dependencies) { db in
                            // Need the auth data to exist in the database to prepare the request
                            _ = try SessionThread.fetchOrCreate(
                                db,
                                id: groupId.hexString,
                                variant: .group,
                                shouldBeVisible: nil,
                                calledFromConfigHandling: false,
                                using: dependencies
                            )
                            try ClosedGroup(
                                threadId: groupId.hexString,
                                name: "Test",
                                formationTimestamp: 0,
                                shouldPoll: nil,
                                groupIdentityPrivateKey: groupSecretKey,
                                invited: nil
                            ).upsert(db)
                            
                            let preparedRequest: HTTP.PreparedRequest<HTTP.BatchResponse> = try SnodeAPI.preparedSequence(
                                requests: try LibSession
                                    .pendingChanges(db, sessionIdHexString: groupId.hexString, using: dependencies)
                                    .map { pushData -> ErasedPreparedRequest in
                                        try SnodeAPI
                                            .preparedSendMessage(
                                                message: SnodeMessage(
                                                    recipient: groupId.hexString,
                                                    data: pushData.data.base64EncodedString(),
                                                    ttl: pushData.variant.ttl,
                                                    timestampMs: 1234567890
                                                ),
                                                in: pushData.variant.namespace,
                                                authMethod: try Authentication.with(
                                                    db,
                                                    sessionIdHexString: groupId.hexString,
                                                    using: dependencies
                                                ),
                                                using: dependencies
                                            )
                                    },
                                requireAllBatchResponses: false,
                                associatedWith: groupId.hexString,
                                using: dependencies
                            )
                            
                            // Remove the debug group so it can be created during the actual test
                            try ClosedGroup.filter(id: groupId.hexString).deleteAll(db)
                            try SessionThread.filter(id: groupId.hexString).deleteAll(db)
                            
                            return preparedRequest
                        }!.request
                    
                    MessageSender
                        .createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPictureData: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .sinkAndStore(in: &disposables)
                    
                    expect(mockNetwork)
                        .to(call(.exactly(times: 1), matchingParameters: .all) { network in
                            network.send(
                                .selectedNetworkRequest(
                                    expectedRequest.httpBody!,
                                    to: dependencies.randomElement(mockSwarmCache)!,
                                    timeout: HTTP.defaultTimeout,
                                    using: .any
                                )
                            )
                        })
                }
                
                // MARK: ---- and the group configuration sync fails
                context("and the group configuration sync fails") {
                    beforeEach {
                        mockNetwork
                            .when { $0.send(.selectedNetworkRequest(.any, to: .any, timeout: .any, using: .any)) }
                            .thenReturn(MockNetwork.errorResponse())
                    }
                    
                    // MARK: ------ throws an error
                    it("throws an error") {
                        MessageSender
                            .createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureData: nil,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(error).to(matchError(SnodeAPIError.generic))
                    }
                    
                    // MARK: ------ removes the config state
                    it("removes the config state") {
                        MessageSender
                            .createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureData: nil,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(mockLibSessionCache)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { cache in
                                cache.setConfig(for: .groupInfo, sessionId: groupId, to: nil)
                            })
                        expect(mockLibSessionCache)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { cache in
                                cache.setConfig(for: .groupMembers, sessionId: groupId, to: nil)
                            })
                        expect(mockLibSessionCache)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { cache in
                                cache.setConfig(for: .groupKeys, sessionId: groupId, to: nil)
                            })
                    }
                    
                    // MARK: ------ removes the data from the database
                    it("removes the data from the database") {
                        MessageSender
                            .createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureData: nil,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        let threads: [SessionThread]? = mockStorage.read { db in try SessionThread.fetchAll(db) }
                        let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                        let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                        
                        expect(threads).to(beEmpty())
                        expect(groups).to(beEmpty())
                        expect(members).to(beEmpty())
                    }
                }
                
                // MARK: ------ does not upload an image if none is provided
                it("does not upload an image if none is provided") {
                    MessageSender
                        .createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPictureData: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .mapError { error.setting(to: $0) }
                        .sinkAndStore(in: &disposables)
                    
                    let expectedRequest: URLRequest = try FileServerAPI
                        .preparedUpload(TestConstants.validImageData, using: dependencies)
                        .request
                    
                    expect(mockNetwork)
                        .toNot(call { network in
                            network.send(
                                .selectedNetworkRequest(
                                    expectedRequest,
                                    to: FileServerAPI.server,
                                    with: FileServerAPI.serverPublicKey,
                                    timeout: FileServerAPI.fileUploadTimeout,
                                    using: .any
                                )
                            )
                        })
                }
                
                // MARK: ------ with an image
                context("with an image") {
                    // MARK: ------ uploads the image
                    it("uploads the image") {
                        MessageSender
                            .createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureData: TestConstants.validImageData,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        let expectedRequest: URLRequest = try FileServerAPI
                            .preparedUpload(TestConstants.validImageData, using: dependencies)
                            .request
                        
                        expect(mockNetwork)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { network in
                                network.send(
                                    .selectedNetworkRequest(
                                        expectedRequest,
                                        to: FileServerAPI.server,
                                        with: FileServerAPI.serverPublicKey,
                                        timeout: FileServerAPI.fileUploadTimeout,
                                        using: .any
                                    )
                                )
                            })
                    }
                    
                    // MARK: ------ saves the image info to the group
                    it("saves the image info to the group") {
                        MessageSender
                            .createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureData: TestConstants.validImageData,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                        
                        expect(groups?.first?.displayPictureUrl).to(equal("http://filev2.getsession.org/file/1"))
                        expect(groups?.first?.displayPictureFilename)
                            .to(equal("00000000-0000-0000-0000-000000000000.jpg"))
                        expect(groups?.first?.displayPictureEncryptionKey)
                            .to(equal(Data((0..<DisplayPictureManager.aes256KeyByteLength).map { _ in 1 })))
                    }
                    
                    // MARK: ------ fails if the image fails to upload
                    it("fails if the image fails to upload") {
                        mockNetwork
                            .when { $0.send(.selectedNetworkRequest(.any, to: .any, with: .any, timeout: .any, using: .any)) }
                            .thenReturn(Fail(error: HTTPError.generic).eraseToAnyPublisher())
                        
                        MessageSender
                            .createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureData: TestConstants.validImageData,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(error).to(matchError(DisplayPictureError.uploadFailed))
                    }
                }
                
                // MARK: ---- schedules member invite jobs
                it("schedules member invite jobs") {
                    MessageSender
                        .createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPictureData: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .sinkAndStore(in: &disposables)
                    
                    expect(mockJobRunner)
                        .to(call(.exactly(times: 1), matchingParameters: .all) { jobRunner in
                            jobRunner.add(
                                .any,
                                job: Job(
                                    variant: .groupInviteMember,
                                    threadId: groupId.hexString,
                                    details: try? GroupInviteMemberJob.Details(
                                        memberSessionIdHexString: "051111111111111111111111111111111111111111111111111111111111111111",
                                        authInfo: .groupMember(
                                            groupSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                            authData: "TestAuthData".data(using: .utf8)!
                                        )
                                    )
                                ),
                                dependantJob: nil,
                                canStartJob: true,
                                using: .any
                            )
                        })
                }
                
                // MARK: ------ and trying to subscribe for push notifications
                context("and trying to subscribe for push notifications") {
                    // MARK: ---- subscribes when they are enabled
                    it("subscribes when they are enabled") {
                        mockUserDefaults
                            .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                            .thenReturn(Data([5, 4, 3, 2, 1]).toHexString())
                        mockUserDefaults
                            .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                            .thenReturn(true)
                        
                        MessageSender
                            .createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureData: nil,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                            .sinkAndStore(in: &disposables)
                        
                        let expectedRequest: URLRequest = mockStorage.read(using: dependencies) { db in
                            try PushNotificationAPI
                                .preparedSubscribe(
                                    db,
                                    token: Data([5, 4, 3, 2, 1]),
                                    sessionIds: [groupId],
                                    using: dependencies
                                )
                                .request
                        }!
                        
                        expect(mockNetwork)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { network in
                                network.send(
                                    .selectedNetworkRequest(
                                        expectedRequest,
                                        to: PushNotificationAPI.server.value(using: dependencies),
                                        with: PushNotificationAPI.serverPublicKey,
                                        timeout: HTTP.defaultTimeout,
                                        using: .any
                                    )
                                )
                            })
                    }
                    
                    // MARK: ---- does not subscribe if push notifications are disabled
                    it("does not subscribe if push notifications are disabled") {
                        mockUserDefaults
                            .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                            .thenReturn(Data([5, 4, 3, 2, 1]).toHexString())
                        mockUserDefaults
                            .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                            .thenReturn(false)
                        
                        MessageSender
                            .createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureData: nil,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                            .sinkAndStore(in: &disposables)
                        
                        expect(mockNetwork)
                            .toNot(call { network in
                                network.send(
                                    .selectedNetworkRequest(
                                        .any,
                                        to: PushNotificationAPI.server.value(using: dependencies),
                                        with: PushNotificationAPI.serverPublicKey,
                                        timeout: HTTP.defaultTimeout,
                                        using: .any
                                    )
                                )
                            })
                    }
                    
                    // MARK: ---- does not subscribe if there is no push token
                    it("does not subscribe if there is no push token") {
                        mockUserDefaults
                            .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                            .thenReturn(nil)
                        mockUserDefaults
                            .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                            .thenReturn(true)
                        
                        MessageSender
                            .createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureData: nil,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                            .sinkAndStore(in: &disposables)
                        
                        expect(mockNetwork)
                            .toNot(call { network in
                                network.send(
                                    .selectedNetworkRequest(
                                        .any,
                                        to: PushNotificationAPI.server.value(using: dependencies),
                                        with: PushNotificationAPI.serverPublicKey,
                                        timeout: HTTP.defaultTimeout,
                                        using: .any
                                    )
                                )
                            })
                    }
                }
                
                // MARK: -- when adding members to a group
                context("when adding members to a group") {
                    beforeEach {
                        // Rekey a couple of times to increase the key generation to 1
                        var fakeHash1: [CChar] = "fakehash1".cArray.nullTerminated()
                        var fakeHash2: [CChar] = "fakehash2".cArray.nullTerminated()
                        var pushResult: UnsafePointer<UInt8>? = nil
                        var pushResultLen: Int = 0
                        _ = groups_keys_rekey(groupKeysConf, groupInfoConf, groupMembersConf, &pushResult, &pushResultLen)
                        _ = groups_keys_load_message(groupKeysConf, &fakeHash1, pushResult, pushResultLen, 1234567890, groupInfoConf, groupMembersConf)
                        _ = groups_keys_rekey(groupKeysConf, groupInfoConf, groupMembersConf, &pushResult, &pushResultLen)
                        _ = groups_keys_load_message(groupKeysConf, &fakeHash2, pushResult, pushResultLen, 1234567890, groupInfoConf, groupMembersConf)
                        
                        mockStorage.write { db in
                            try SessionThread.fetchOrCreate(
                                db,
                                id: groupId.hexString,
                                variant: .group,
                                shouldBeVisible: true,
                                calledFromConfigHandling: false,
                                using: dependencies
                            )
                            
                            try ClosedGroup(
                                threadId: groupId.hexString,
                                name: "TestGroup",
                                formationTimestamp: 1234567890,
                                shouldPoll: true,
                                groupIdentityPrivateKey: groupSecretKey,
                                authData: nil,
                                invited: false
                            ).upsert(db)
                        }
                    }
                    
                    // MARK: ---- does nothing if the current user is not an admin
                    it("does nothing if the current user is not an admin") {
                        mockStorage.write { db in
                            try ClosedGroup
                                .updateAll(
                                    db,
                                    ClosedGroup.Columns.groupIdentityPrivateKey.set(to: nil)
                                )
                        }
                        
                        MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: false,
                            using: dependencies
                        )
                        
                        let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                        expect(groups_members_size(groupMembersConf)).to(equal(0))
                        expect(members?.count).to(equal(0))
                    }
                    
                    // MARK: ---- adds the member to the database in the sending state
                    it("adds the member to the database in the sending state") {
                        MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: false,
                            using: dependencies
                        )
                        
                        let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                        expect(members?.count).to(equal(1))
                        expect(members?.first?.profileId)
                            .to(equal("051111111111111111111111111111111111111111111111111111111111111112"))
                        expect(members?.first?.role).to(equal(.standard))
                        expect(members?.first?.roleStatus).to(equal(.sending))
                    }
                    
                    // MARK: ---- adds the member to GROUP_MEMBERS
                    it("adds the member to GROUP_MEMBERS") {
                        MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: false,
                            using: dependencies
                        )
                        
                        expect(groups_members_size(groupMembersConf)).to(equal(1))
                        
                        let members: Set<GroupMember>? = try? LibSession.extractMembers(
                            from: groupMembersConf,
                            groupSessionId: groupId
                        )
                        expect(members?.count).to(equal(1))
                        expect(members?.first?.profileId)
                            .to(equal("051111111111111111111111111111111111111111111111111111111111111112"))
                        expect(members?.first?.role).to(equal(.standard))
                        expect(members?.first?.roleStatus).to(equal(.pending))
                    }
                    
                    // MARK: ---- and granting access to historic messages
                    context("and granting access to historic messages") {
                        // MARK: ---- performs a supplemental key rotation
                        it("performs a supplemental key rotation") {
                            let initialKeyRotation: Int = try LibSession.currentGeneration(
                                groupSessionId: groupId,
                                using: dependencies
                            )
                            
                            MessageSender.addGroupMembers(
                                groupSessionId: groupId.hexString,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                                ],
                                allowAccessToHistoricMessages: true,
                                using: dependencies
                            )
                            
                            // Can't actually detect a supplemental rotation directly but can check that the
                            // keys generation didn't increase
                            let result: Int = try LibSession.currentGeneration(
                                groupSessionId: groupId,
                                using: dependencies
                            )
                            expect(result).to(equal(initialKeyRotation))
                        }
                        
                        // MARK: ---- sends the supplemental key rotation data
                        it("sends the supplemental key rotation data") {
                            let requestDataString: String = "ZDE6IzI0OhOKDnbpLN3QJVbKzR8mOmjn6gXmeUFdTDE6K" +
                                "2wxNDA669s6Q2aETGZ5agGXfVVrC8Q9JA4bIoqv5iWyQWjttPhqDK2IZHXGVDZ/Kaz9tEq2Rl" +
                                "r2B9/neDBUFPtH3haJFN/zkIq1dAIwkgQQ4xJK00zWvZt6HejV1Fy6W9eI1oRJJny0++5+hxp" +
                                "LPczVOFKOPs+rrB3aUpMsNUnJHOEhW9g6zi/UPjuCWTnnvpxlMTpHaTFlMTp+NjQ6dKi86jZJ" +
                                "l3oiJEA5h5pBE5oOJHQNvtF8GOcsYwrIFTZKnI7AGkBSu1TxP0xLWwTUzjOGMgmKvlIgkQ6e9" +
                                "r3JBmU="
                            let expectedRequest: URLRequest = try SnodeAPI
                                .preparedSendMessage(
                                    message: SnodeMessage(
                                        recipient: groupId.hexString,
                                        data: requestDataString,
                                        ttl: ConfigDump.Variant.groupKeys.ttl,
                                        timestampMs: UInt64(1234567890000)
                                    ),
                                    in: .configGroupKeys,
                                    authMethod: Authentication.groupAdmin(
                                        groupSessionId: groupId,
                                        ed25519SecretKey: Array(groupSecretKey)
                                    ),
                                    using: dependencies
                                )
                                .request
                            
                            MessageSender.addGroupMembers(
                                groupSessionId: groupId.hexString,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                                ],
                                allowAccessToHistoricMessages: true,
                                using: dependencies
                            )
                            
                            // If there is a pending keys config then merge it to complete the process
                            var pushResult: UnsafePointer<UInt8>? = nil
                            var pushResultLen: Int = 0
                            
                            if groups_keys_pending_config(groupKeysConf, &pushResult, &pushResultLen) {
                                // Rekey a couple of times to increase the key generation to 1
                                var fakeHash3: [CChar] = "fakehash3".cArray.nullTerminated()
                                _ = groups_keys_load_message(groupKeysConf, &fakeHash3, pushResult, pushResultLen, 1234567890, groupInfoConf, groupMembersConf)
                            }
                            
                            expect(mockNetwork)
                                .to(call(.exactly(times: 1), matchingParameters: .all) { network in
                                    network.send(
                                        .selectedNetworkRequest(
                                            expectedRequest.httpBody!,
                                            to: dependencies.randomElement(mockSwarmCache)!,
                                            timeout: HTTP.defaultTimeout,
                                            using: .any
                                        )
                                    )
                                })
                        }
                    }
                    
                    // MARK: ---- and not granting access to historic messages
                    context("and not granting access to historic messages") {
                        // MARK: ---- performs a full key rotation
                        it("performs a full key rotation") {
                            let initialKeyRotation: Int = try LibSession.currentGeneration(
                                groupSessionId: groupId,
                                using: dependencies
                            )
                            
                            MessageSender.addGroupMembers(
                                groupSessionId: groupId.hexString,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                                ],
                                allowAccessToHistoricMessages: false,
                                using: dependencies
                            )
                            
                            // If there is a pending keys config then merge it to complete the process
                            var pushResult: UnsafePointer<UInt8>? = nil
                            var pushResultLen: Int = 0
                            
                            if groups_keys_pending_config(groupKeysConf, &pushResult, &pushResultLen) {
                                // Rekey a couple of times to increase the key generation to 1
                                var fakeHash3: [CChar] = "fakehash3".cArray.nullTerminated()
                                _ = groups_keys_load_message(groupKeysConf, &fakeHash3, pushResult, pushResultLen, 1234567890, groupInfoConf, groupMembersConf)
                            }
                            
                            let result: Int = try LibSession.currentGeneration(
                                groupSessionId: groupId,
                                using: dependencies
                            )
                            expect(result).to(beGreaterThan(initialKeyRotation))
                        }
                    }
                    
                    // MARK: ---- calls the unrevoke subaccounts endpoint
                    it("calls the unrevoke subaccounts endpoint") {
                        let expectedRequest: URLRequest = try SnodeAPI
                            .preparedUnrevokeSubaccounts(
                                subaccountsToUnrevoke: [Array("TestSubAccountToken".data(using: .utf8)!)],
                                authMethod: Authentication.groupAdmin(
                                    groupSessionId: groupId,
                                    ed25519SecretKey: Array(groupSecretKey)
                                ),
                                using: dependencies
                            )
                            .request
                        
                        MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: true,
                            using: dependencies
                        )
                        
                        expect(mockNetwork)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { network in
                                network.send(
                                    .selectedNetworkRequest(
                                        expectedRequest.httpBody!,
                                        to: dependencies.randomElement(mockSwarmCache)!,
                                        timeout: HTTP.defaultTimeout,
                                        using: .any
                                    )
                                )
                            })
                    }
                    
                    // MARK: ---- schedules member invite jobs
                    it("schedules member invite jobs") {
                        MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: true,
                            using: dependencies
                        )
                        
                        expect(mockJobRunner)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { jobRunner in
                                jobRunner.add(
                                    .any,
                                    job: Job(
                                        variant: .groupInviteMember,
                                        threadId: groupId.hexString,
                                        details: try? GroupInviteMemberJob.Details(
                                            memberSessionIdHexString: "051111111111111111111111111111111111111111111111111111111111111112",
                                            authInfo: .groupMember(
                                                groupSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                                authData: "TestAuthData".data(using: .utf8)!
                                            )
                                        )
                                    ),
                                    dependantJob: nil,
                                    canStartJob: true,
                                    using: .any
                                )
                            })
                    }
                    
                    // MARK: ---- adds a member change control message
                    it("adds a member change control message") {
                        MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: true,
                            using: dependencies
                        )
                        
                        let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                        expect(interactions?.count).to(equal(1))
                        expect(interactions?.first?.variant).to(equal(.infoGroupMembersUpdated))
                        expect(interactions?.first?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .addedUsers(names: ["0511...1112"])
                                .infoString(using: dependencies)
                        ))
                    }
                    
                    // MARK: ---- schedules sending of the member change message
                    it("schedules sending of the member change message") {
                        MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: true,
                            using: dependencies
                        )
                        
                        expect(mockJobRunner)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { jobRunner in
                                jobRunner.add(
                                    .any,
                                    job: Job(
                                        variant: .messageSend,
                                        threadId: groupId.hexString,
                                        interactionId: nil,
                                        details: MessageSendJob.Details(
                                            destination: .closedGroup(groupPublicKey: groupId.hexString),
                                            message: try! GroupUpdateMemberChangeMessage(
                                                changeType: .added,
                                                memberSessionIds: [
                                                    "051111111111111111111111111111111111111111111111111111111111111112"
                                                ],
                                                sentTimestamp: 1234567890000,
                                                authMethod: Authentication.groupAdmin(
                                                    groupSessionId: groupId,
                                                    ed25519SecretKey: Array(groupSecretKey)
                                                ),
                                                using: dependencies
                                            ),
                                            isSyncMessage: false
                                        )
                                    ),
                                    dependantJob: nil,
                                    canStartJob: true,
                                    using: .any
                                )
                            })
                    }
                }
            }
        }
    }
}

// MARK: - Mock Types

extension SendMessagesResponse: Mocked {
    static var mock: SendMessagesResponse = SendMessagesResponse(
        hash: "hash",
        swarm: [:],
        hardFork: [1, 2],
        timeOffset: 0
    )
}

// MARK: - Mock Batch Responses
                        
extension HTTP.BatchResponse {
    // MARK: - Valid Responses
    
    fileprivate static let mockConfigSyncResponse: AnyPublisher<(ResponseInfoType, Data?), Error> = MockNetwork.batchResponseData(
        with: [
            (SnodeAPI.Endpoint.sendMessage, SendMessagesResponse.mockBatchSubResponse()),
            (SnodeAPI.Endpoint.sendMessage, SendMessagesResponse.mockBatchSubResponse()),
            (SnodeAPI.Endpoint.sendMessage, SendMessagesResponse.mockBatchSubResponse())
        ]
    )
}
