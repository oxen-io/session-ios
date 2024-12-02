// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import Quick
import Nimble
import SessionUtil
import SessionUtilitiesKit
import SessionUIKit

@testable import SessionSnodeKit
@testable import SessionMessagingKit

class MessageReceiverGroupsSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        let groupSeed: Data = Data(hex: "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210")
        @TestState var groupKeyPair: KeyPair! = Crypto(using: .any).generate(.ed25519KeyPair(seed: Array(groupSeed)))
        @TestState var groupId: SessionId! = SessionId(.group, hex: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece")
        @TestState var groupSecretKey: Data! = Data(hex:
            "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210" +
            "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
        )
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrationTargets: [
                SNUtilitiesKit.self,
                SNSnodeKit.self,
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
                    .when { $0.add(.any, job: .any, dependantJob: .any, canStartJob: .any) }
                    .thenReturn(nil)
                jobRunner
                    .when { $0.upsert(.any, job: .any, canStartJob: .any) }
                    .thenReturn(nil)
                jobRunner
                    .when { $0.manuallyTriggerResult(.any, result: .any) }
                    .thenReturn(())
            }
        )
        @TestState(singleton: .network, in: dependencies) var mockNetwork: MockNetwork! = MockNetwork(
            initialSetup: { network in
                network
                    .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
                    .thenReturn(MockNetwork.response(with: FileUploadResponse(id: "1")))
                network
                    .when { $0.getSwarm(for: .any) }
                    .thenReturn([
                        LibSession.Snode(
                            ip: "1.1.1.1",
                            quicPort: 1,
                            ed25519PubkeyHex: TestConstants.edPublicKey
                        ),
                        LibSession.Snode(
                            ip: "1.1.1.1",
                            quicPort: 2,
                            ed25519PubkeyHex: TestConstants.edPublicKey
                        ),
                        LibSession.Snode(
                            ip: "1.1.1.1",
                            quicPort: 3,
                            ed25519PubkeyHex: TestConstants.edPublicKey
                        )
                    ])
            }
        )
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto
                    .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                    .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
                crypto
                    .when { $0.generate(.signatureSubaccount(config: .any, verificationBytes: .any, memberAuthData: .any)) }
                    .thenReturn(Authentication.Signature.subaccount(
                        subaccount: "TestSubAccount".bytes,
                        subaccountSig: "TestSubAccountSignature".bytes,
                        signature: "TestSignature".bytes
                    ))
                crypto
                    .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
                    .thenReturn(true)
                crypto.when { $0.generate(.ed25519KeyPair(seed: .any)) }.thenReturn(groupKeyPair)
                crypto
                    .when { $0.verify(.memberAuthData(groupSessionId: .any, ed25519SecretKey: .any, memberAuthData: .any)) }
                    .thenReturn(true)
                crypto
                    .when { $0.generate(.hash(message: .any, key: .any, length: .any)) }
                    .thenReturn("TestHash".bytes)
            }
        )
        @TestState(singleton: .keychain, in: dependencies) var mockKeychain: MockKeychain! = MockKeychain(
            initialSetup: { keychain in
                keychain
                    .when {
                        try $0.migrateLegacyKeyIfNeeded(
                            legacyKey: .any,
                            legacyService: .any,
                            toKey: .pushNotificationEncryptionKey
                        )
                    }
                    .thenReturn(())
                keychain
                    .when { try $0.data(forKey: .pushNotificationEncryptionKey) }
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
            var conf: UnsafeMutablePointer<config_object>!
            _ = user_groups_init(&conf, &secretKey, nil, 0, nil)
            
            return .object(conf)
        }()
        @TestState var convoInfoVolatileConfig: LibSession.Config! = {
            var conf: UnsafeMutablePointer<config_object>!
            _ = convo_info_volatile_init(&conf, &secretKey, nil, 0, nil)
            
            return .object(conf)
        }()
        @TestState var groupInfoConf: UnsafeMutablePointer<config_object>! = {
            var conf: UnsafeMutablePointer<config_object>!
            _ = groups_info_init(&conf, &groupEdPK, &groupEdSK, nil, 0, nil)
            
            return conf
        }()
        @TestState var groupMembersConf: UnsafeMutablePointer<config_object>! = {
            var conf: UnsafeMutablePointer<config_object>!
            _ = groups_members_init(&conf, &groupEdPK, &groupEdSK, nil, 0, nil)
            
            return conf
        }()
        @TestState var groupKeysConf: UnsafeMutablePointer<config_group_keys>! = {
            var conf: UnsafeMutablePointer<config_group_keys>!
            _ = groups_keys_init(&conf, &secretKey, &groupEdPK, &groupEdSK, groupInfoConf, groupMembersConf, nil, 0, nil)
            
            return conf
        }()
        @TestState var groupInfoConfig: LibSession.Config! = .object(groupInfoConf)
        @TestState var groupMembersConfig: LibSession.Config! = .object(groupMembersConf)
        @TestState var groupKeysConfig: LibSession.Config! = .groupKeys(
            groupKeysConf,
            info: groupInfoConf,
            members: groupMembersConf
        )
        @TestState(cache: .libSession, in: dependencies) var mockLibSessionCache: MockLibSessionCache! = MockLibSessionCache(
            initialSetup: { cache in
                let userSessionId: SessionId = SessionId(.standard, hex: TestConstants.publicKey)
                
                cache.when { $0.setConfig(for: .any, sessionId: .any, to: .any) }.thenReturn(())
                cache.when { $0.removeConfigs(for: .any) }.thenReturn(())
                cache.when { $0.hasConfig(for: .any, sessionId: .any) }.thenReturn(true)
                cache
                    .when { $0.config(for: .userGroups, sessionId: userSessionId) }
                    .thenReturn(userGroupsConfig)
                cache
                    .when { $0.config(for: .convoInfoVolatile, sessionId: userSessionId) }
                    .thenReturn(convoInfoVolatileConfig)
                cache
                    .when { $0.config(for: .groupInfo, sessionId: groupId) }
                    .thenReturn(groupInfoConfig)
                cache
                    .when { $0.config(for: .groupMembers, sessionId: groupId) }
                    .thenReturn(groupMembersConfig)
                cache
                    .when { $0.config(for: .groupKeys, sessionId: groupId) }
                    .thenReturn(groupKeysConfig)
                cache.when { $0.configNeedsDump(.any) }.thenReturn(false)
                cache
                    .when { try $0.performAndPushChange(.any, for: .any, sessionId: .any, change: { _ in }) }
                    .then { args, untrackedArgs in
                        let callback: ((LibSession.Config?) throws -> Void)? = (untrackedArgs[test: 1] as? (LibSession.Config?) throws -> Void)
                        
                        switch args[test: 0] as? ConfigDump.Variant {
                            case .userGroups: try? callback?(userGroupsConfig)
                            case .convoInfoVolatile: try? callback?(convoInfoVolatileConfig)
                            case .groupInfo: try? callback?(groupInfoConfig)
                            case .groupMembers: try? callback?(groupMembersConfig)
                            case .groupKeys: try? callback?(groupKeysConfig)
                            default: break
                        }
                    }
                    .thenReturn(())
                cache.when { $0.isAdmin(groupSessionId: .any) }.thenReturn(true)
            }
        )
        @TestState(cache: .snodeAPI, in: dependencies) var mockSnodeAPICache: MockSnodeAPICache! = MockSnodeAPICache(
            initialSetup: { cache in
                cache.when { $0.clockOffsetMs }.thenReturn(0)
                cache.when { $0.currentOffsetTimestampMs() }.thenReturn(1234567890000)
            }
        )
        @TestState var mockSwarmPoller: MockSwarmPoller! = MockSwarmPoller(
            initialSetup: { cache in
                cache.when { $0.startIfNeeded() }.thenReturn(())
                cache.when { $0.receivedPollResponse }.thenReturn(Just([]).eraseToAnyPublisher())
            }
        )
        @TestState(cache: .groupPollers, in: dependencies) var mockGroupPollersCache: MockGroupPollerCache! = MockGroupPollerCache(
            initialSetup: { cache in
                cache.when { $0.startAllPollers() }.thenReturn(())
                cache.when { $0.getOrCreatePoller(for: .any) }.thenReturn(mockSwarmPoller)
                cache.when { $0.stopAndRemovePoller(for: .any) }.thenReturn(())
                cache.when { $0.stopAndRemoveAllPollers() }.thenReturn(())
            }
        )
        @TestState(singleton: .notificationsManager, in: dependencies) var mockNotificationsManager: MockNotificationsManager! = MockNotificationsManager(
            initialSetup: { notificationsManager in
                notificationsManager
                    .when { $0.notifyUser(.any, for: .any, in: .any, applicationState: .any) }
                    .thenReturn(())
                notificationsManager
                    .when { $0.cancelNotifications(identifiers: .any) }
                    .thenReturn(())
            }
        )
        @TestState(singleton: .appContext, in: dependencies) var mockAppContext: MockAppContext! = MockAppContext(
            initialSetup: { appContext in
                appContext.when { $0.isMainApp }.thenReturn(false)
            }
        )
        
        // MARK: -- Messages
        @TestState var inviteMessage: GroupUpdateInviteMessage! = {
            let result: GroupUpdateInviteMessage = GroupUpdateInviteMessage(
                inviteeSessionIdHexString: "TestId",
                groupSessionId: groupId,
                groupName: "TestGroup",
                memberAuthData: Data([1, 2, 3]),
                profile: nil,
                adminSignature: .standard(signature: "TestSignature".bytes)
            )
            result.sender = "051111111111111111111111111111111111111111111111111111111111111111"
            result.sentTimestampMs = 1234567890000
            
            return result
        }()
        @TestState var promoteMessage: GroupUpdatePromoteMessage! = {
            let result: GroupUpdatePromoteMessage = GroupUpdatePromoteMessage(
                groupIdentitySeed: groupSeed,
                groupName: "TestGroup",
                sentTimestampMs: 1234567890000
            )
            result.sender = "051111111111111111111111111111111111111111111111111111111111111111"
            
            return result
        }()
        @TestState var infoChangedMessage: GroupUpdateInfoChangeMessage! = {
            let result: GroupUpdateInfoChangeMessage = GroupUpdateInfoChangeMessage(
                changeType: .name,
                updatedName: "TestGroup Rename",
                updatedExpiration: nil,
                adminSignature: .standard(signature: "TestSignature".bytes)
            )
            result.sender = "051111111111111111111111111111111111111111111111111111111111111111"
            result.sentTimestampMs = 1234567800000
            
            return result
        }()
        @TestState var memberChangedMessage: GroupUpdateMemberChangeMessage! = {
            let result: GroupUpdateMemberChangeMessage = GroupUpdateMemberChangeMessage(
                changeType: .added,
                memberSessionIds: ["051111111111111111111111111111111111111111111111111111111111111112"],
                historyShared: false,
                adminSignature: .standard(signature: "TestSignature".bytes)
            )
            result.sender = "051111111111111111111111111111111111111111111111111111111111111111"
            result.sentTimestampMs = 1234567800000
            
            return result
        }()
        @TestState var memberLeftMessage: GroupUpdateMemberLeftMessage! = {
            let result: GroupUpdateMemberLeftMessage = GroupUpdateMemberLeftMessage()
            result.sender = "051111111111111111111111111111111111111111111111111111111111111112"
            result.sentTimestampMs = 1234567800000
            
            return result
        }()
        @TestState var memberLeftNotificationMessage: GroupUpdateMemberLeftNotificationMessage! = {
            let result: GroupUpdateMemberLeftNotificationMessage = GroupUpdateMemberLeftNotificationMessage()
            result.sender = "051111111111111111111111111111111111111111111111111111111111111112"
            result.sentTimestampMs = 1234567800000
            
            return result
        }()
        @TestState var inviteResponseMessage: GroupUpdateInviteResponseMessage! = {
            let result: GroupUpdateInviteResponseMessage = GroupUpdateInviteResponseMessage(
                isApproved: true,
                profile: VisibleMessage.VMProfile(displayName: "TestOtherMember"),
                sentTimestampMs: 1234567800000
            )
            result.sender = "051111111111111111111111111111111111111111111111111111111111111112"
            
            return result
        }()
        @TestState var deleteMessage: Data! = try! LibSessionMessage.groupKicked(
            memberId: "05\(TestConstants.publicKey)",
            groupKeysGen: 1
        ).1
        @TestState var deleteContentMessage: GroupUpdateDeleteMemberContentMessage! = {
            let result: GroupUpdateDeleteMemberContentMessage = GroupUpdateDeleteMemberContentMessage(
                memberSessionIds: ["051111111111111111111111111111111111111111111111111111111111111112"],
                messageHashes: [],
                adminSignature: .standard(signature: "TestSignature".bytes)
            )
            result.sender = "051111111111111111111111111111111111111111111111111111111111111112"
            result.sentTimestampMs = 1234567800000
            
            return result
        }()
        @TestState var visibleMessageProto: SNProtoContent! = {
            let proto = SNProtoContent.builder()
            let dataMessage = SNProtoDataMessage.builder()
            dataMessage.setBody("Test")
            proto.setDataMessage(try! dataMessage.build())
            return try? proto.build()
        }()
        @TestState var visibleMessage: VisibleMessage! = {
            let result = VisibleMessage(
                sender: "051111111111111111111111111111111111111111111111111111111111111112",
                sentTimestampMs: ((1234568890 - (60 * 10)) * 1000),
                text: "Test"
            )
            result.receivedTimestampMs = (1234568890 * 1000)
            return result
        }()
        
        // MARK: - a MessageReceiver dealing with Groups
        describe("a MessageReceiver dealing with Groups") {
            // MARK: -- when receiving a group invitation
            context("when receiving a group invitation") {
                // MARK: ---- throws if the admin signature fails to verify
                it("throws if the admin signature fails to verify") {
                    mockCrypto
                        .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
                        .thenReturn(false)
                    
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: inviteMessage,
                            using: dependencies
                        )
                    }
                    
                    let threads: [SessionThread]? = mockStorage.read { db in try SessionThread.fetchAll(db) }
                    expect(threads).to(beEmpty())
                }
                
                // MARK: ---- with profile information
                context("with profile information") {
                    // MARK: ------ updates the profile name
                    it("updates the profile name") {
                        inviteMessage.profile = VisibleMessage.VMProfile(displayName: "TestName")
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteMessage,
                                using: dependencies
                            )
                        }
                        
                        let profiles: [Profile]? = mockStorage.read { db in try Profile.fetchAll(db) }
                        expect(profiles?.map { $0.name }.sorted()).to(equal(["TestCurrentUser", "TestName"]))
                    }
                    
                    // MARK: ------ with a profile picture
                    context("with a profile picture") {
                        // MARK: ------ schedules and starts a displayPictureDownload job if running the main app
                        it("schedules and starts a displayPictureDownload job if running the main app") {
                            mockAppContext.when { $0.isMainApp }.thenReturn(true)
                            
                            inviteMessage.profile = VisibleMessage.VMProfile(
                                displayName: "TestName",
                                profileKey: Data((0..<DisplayPictureManager.aes256KeyByteLength)
                                    .map { _ in 1 }),
                                profilePictureUrl: "https://www.oxen.io/1234"
                            )
                            
                            mockStorage.write { db in
                                try MessageReceiver.handleGroupUpdateMessage(
                                    db,
                                    threadId: groupId.hexString,
                                    threadVariant: .group,
                                    message: inviteMessage,
                                    using: dependencies
                                )
                            }
                            
                            expect(mockJobRunner)
                                .to(call(.exactly(times: 1), matchingParameters: .all) {
                                    $0.add(
                                        .any,
                                        job: Job(
                                            variant: .displayPictureDownload,
                                            shouldBeUnique: true,
                                            details: DisplayPictureDownloadJob.Details(
                                                target: .profile(
                                                    id: "051111111111111111111111111111111" + "111111111111111111111111111111111",
                                                    url: "https://www.oxen.io/1234",
                                                    encryptionKey: Data((0..<DisplayPictureManager.aes256KeyByteLength)
                                                        .map { _ in 1 })
                                                ),
                                                timestamp: 1234567890
                                            )
                                        ),
                                        canStartJob: true
                                    )
                                })
                        }
                        
                        // MARK: ------ schedules but does not start a displayPictureDownload job when not the main app
                        it("schedules but does not start a displayPictureDownload job when not the main app") {
                            inviteMessage.profile = VisibleMessage.VMProfile(
                                displayName: "TestName",
                                profileKey: Data((0..<DisplayPictureManager.aes256KeyByteLength)
                                    .map { _ in 1 }),
                                profilePictureUrl: "https://www.oxen.io/1234"
                            )
                            
                            mockStorage.write { db in
                                try MessageReceiver.handleGroupUpdateMessage(
                                    db,
                                    threadId: groupId.hexString,
                                    threadVariant: .group,
                                    message: inviteMessage,
                                    using: dependencies
                                )
                            }
                            //dependencies[singleton: .appContext].isMainApp
                            expect(mockJobRunner)
                                .to(call(.exactly(times: 1), matchingParameters: .all) {
                                    $0.add(
                                        .any,
                                        job: Job(
                                            variant: .displayPictureDownload,
                                            shouldBeUnique: true,
                                            details: DisplayPictureDownloadJob.Details(
                                                target: .profile(
                                                    id: "051111111111111111111111111111111" + "111111111111111111111111111111111",
                                                    url: "https://www.oxen.io/1234",
                                                    encryptionKey: Data((0..<DisplayPictureManager.aes256KeyByteLength)
                                                        .map { _ in 1 })
                                                ),
                                                timestamp: 1234567890
                                            )
                                        ),
                                        canStartJob: false
                                    )
                                })
                        }
                    }
                }
                
                // MARK: ---- creates the thread
                it("creates the thread") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: inviteMessage,
                            using: dependencies
                        )
                    }
                    
                    let threads: [SessionThread]? = mockStorage.read { db in try SessionThread.fetchAll(db) }
                    expect(threads?.count).to(equal(1))
                    expect(threads?.first?.id).to(equal(groupId.hexString))
                }
                
                // MARK: ---- creates the group
                it("creates the group") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: inviteMessage,
                            using: dependencies
                        )
                    }
                    
                    let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                    expect(groups?.count).to(equal(1))
                    expect(groups?.first?.id).to(equal(groupId.hexString))
                    expect(groups?.first?.name).to(equal("TestGroup"))
                }
                
                // MARK: ---- adds the group to USER_GROUPS
                it("adds the group to USER_GROUPS") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: inviteMessage,
                            using: dependencies
                        )
                    }
                    
                    expect(user_groups_size(userGroupsConfig.conf)).to(equal(1))
                }
                
                // MARK: ---- from a sender that is not approved
                context("from a sender that is not approved") {
                    beforeEach {
                        mockStorage.write { db in
                            try Contact(
                                id: "051111111111111111111111111111111111111111111111111111111111111111",
                                isApproved: false,
                                using: dependencies
                            ).insert(db)
                        }
                    }
                    
                    // MARK: ------ adds the group as a pending group invitation
                    it("adds the group as a pending group invitation") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteMessage,
                                using: dependencies
                            )
                        }
                        
                        let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                        expect(groups?.count).to(equal(1))
                        expect(groups?.first?.id).to(equal(groupId.hexString))
                        expect(groups?.first?.invited).to(beTrue())
                    }
                    
                    // MARK: ------ adds the group to USER_GROUPS with the invited flag set to true
                    it("adds the group to USER_GROUPS with the invited flag set to true") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteMessage,
                                using: dependencies
                            )
                        }
                        
                        var cGroupId: [CChar] = groupId.hexString.cString(using: .utf8)!
                        var userGroup: ugroups_group_info = ugroups_group_info()
                        
                        expect(user_groups_get_group(userGroupsConfig.conf, &userGroup, &cGroupId)).to(beTrue())
                        expect(userGroup.invited).to(beTrue())
                    }
                    
                    // MARK: ------ does not start the poller
                    it("does not start the poller") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteMessage,
                                using: dependencies
                            )
                        }
                        
                        let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                        expect(groups?.count).to(equal(1))
                        expect(groups?.first?.id).to(equal(groupId.hexString))
                        expect(groups?.first?.shouldPoll).to(beFalse())
                        
                        expect(mockSwarmPoller).toNot(call { $0.startIfNeeded() })
                    }
                    
                    // MARK: ------ sends a local notification about the group invite
                    it("sends a local notification about the group invite") {
                        mockUserDefaults
                            .when { $0.bool(forKey: UserDefaults.BoolKey.isMainAppActive.rawValue) }
                            .thenReturn(true)
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteMessage,
                                using: dependencies
                            )
                        }
                        
                        expect(mockNotificationsManager)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { notificationsManager in
                                notificationsManager.notifyUser(
                                    .any,
                                    for: Interaction(
                                        id: 1,
                                        serverHash: nil,
                                        messageUuid: nil,
                                        threadId: groupId.hexString,
                                        authorId: "051111111111111111111111111111111" + "111111111111111111111111111111111",
                                        variant: .infoGroupInfoInvited,
                                        body: ClosedGroup.MessageInfo
                                            .invited("0511...1111", "TestGroup")
                                            .infoString(using: dependencies),
                                        timestampMs: 1234567890000,
                                        receivedAtTimestampMs: 1234567890000,
                                        wasRead: false,
                                        hasMention: false,
                                        expiresInSeconds: nil,
                                        expiresStartedAtMs: nil,
                                        linkPreviewUrl: nil,
                                        openGroupServerMessageId: nil,
                                        openGroupWhisper: false,
                                        openGroupWhisperMods: false,
                                        openGroupWhisperTo: nil,
                                        state: .sent,
                                        recipientReadTimestampMs: nil,
                                        mostRecentFailureText: nil,
                                        transientDependencies: EquatableIgnoring(value: dependencies)
                                    ),
                                    in: SessionThread(
                                        id: groupId.hexString,
                                        variant: .group,
                                        creationDateTimestamp: 1234567890,
                                        shouldBeVisible: true,
                                        using: dependencies
                                    ),
                                    applicationState: .active
                                )
                            })
                    }
                }
                
                // MARK: ---- from a sender that is approved
                context("from a sender that is approved") {
                    beforeEach {
                        mockStorage.write { db in
                            try Contact(
                                id: "051111111111111111111111111111111111111111111111111111111111111111",
                                isApproved: true,
                                using: dependencies
                            ).insert(db)
                        }
                    }
                    
                    // MARK: ------ adds the group as a full group
                    it("adds the group as a full group") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteMessage,
                                using: dependencies
                            )
                        }
                        
                        let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                        expect(groups?.count).to(equal(1))
                        expect(groups?.first?.id).to(equal(groupId.hexString))
                        expect(groups?.first?.invited).to(beFalse())
                    }
                    
                    // MARK: ------ creates the group state
                    it("creates the group state") {
                        mockLibSessionCache
                            .when { $0.hasConfig(for: .any, sessionId: .any) }
                            .thenReturn(false)
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteMessage,
                                using: dependencies
                            )
                        }
                        
                        expect(mockLibSessionCache)
                            .to(call(.exactly(times: 1), matchingParameters: .atLeast(2)) {
                                $0.setConfig(for: .groupInfo, sessionId: groupId, to: .any)
                            })
                        expect(mockLibSessionCache)
                            .to(call(.exactly(times: 1), matchingParameters: .atLeast(2)) {
                                $0.setConfig(for: .groupMembers, sessionId: groupId, to: .any)
                            })
                        expect(mockLibSessionCache)
                            .to(call(.exactly(times: 1), matchingParameters: .atLeast(2)) {
                                $0.setConfig(for: .groupKeys, sessionId: groupId, to: .any)
                            })
                    }
                    
                    // MARK: ------ adds the group to USER_GROUPS with the invited flag set to false
                    it("adds the group to USER_GROUPS with the invited flag set to false") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteMessage,
                                using: dependencies
                            )
                        }
                        
                        var cGroupId: [CChar] = groupId.hexString.cString(using: .utf8)!
                        var userGroup: ugroups_group_info = ugroups_group_info()
                        
                        expect(user_groups_get_group(userGroupsConfig.conf, &userGroup, &cGroupId)).to(beTrue())
                        expect(userGroup.invited).to(beFalse())
                    }
                    
                    // MARK: ------ starts the poller
                    it("starts the poller") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteMessage,
                                using: dependencies
                            )
                        }
                        
                        let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                        expect(groups?.count).to(equal(1))
                        expect(groups?.first?.id).to(equal(groupId.hexString))
                        expect(groups?.first?.shouldPoll).to(beTrue())
                        
                        expect(mockGroupPollersCache).to(call(.exactly(times: 1), matchingParameters: .all) {
                            $0.getOrCreatePoller(for: groupId.hexString)
                        })
                        expect(mockSwarmPoller).to(call(.exactly(times: 1)) { $0.startIfNeeded() })
                    }
                    
                    // MARK: ------ does not send a local notification about the group invite
                    it("does not send a local notification about the group invite") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteMessage,
                                using: dependencies
                            )
                        }
                        
                        expect(mockNotificationsManager)
                            .toNot(call { notificationsManager in
                                notificationsManager.notifyUser(
                                    .any,
                                    for: .any,
                                    in: .any,
                                    applicationState: .any
                                )
                            })
                    }
                    
                    // MARK: ------ and push notifications are disabled
                    context("and push notifications are disabled") {
                        beforeEach {
                            mockUserDefaults
                                .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                                .thenReturn(nil)
                            mockUserDefaults
                                .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                                .thenReturn(false)
                        }
                        
                        // MARK: -------- does not subscribe for push notifications
                        it("does not subscribe for push notifications") {
                            // Need to set `isUsingFullAPNs` to true to generate the `expectedRequest`
                            mockUserDefaults
                                .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                                .thenReturn(true)
                            let expectedRequest: Network.PreparedRequest<PushNotificationAPI.SubscribeResponse> = mockStorage.write { db in
                                _ = try SessionThread.fetchOrCreate(
                                    db,
                                    id: groupId.hexString,
                                    variant: .group,
                                    creationDateTimestamp: 0,
                                    shouldBeVisible: nil,
                                    calledFromConfig: nil,
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
                                let result = try PushNotificationAPI.preparedSubscribe(
                                    db,
                                    token: Data([5, 4, 3, 2, 1]),
                                    sessionIds: [groupId],
                                    using: dependencies
                                )
                                
                                // Remove the debug group so it can be created during the actual test
                                try ClosedGroup.filter(id: groupId.hexString).deleteAll(db)
                                try SessionThread.filter(id: groupId.hexString).deleteAll(db)
                                
                                return result
                            }!
                            mockUserDefaults
                                .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                                .thenReturn(false)
                            
                            mockStorage.write { db in
                                try MessageReceiver.handleGroupUpdateMessage(
                                    db,
                                    threadId: groupId.hexString,
                                    threadVariant: .group,
                                    message: inviteMessage,
                                    using: dependencies
                                )
                            }
                            
                            expect(mockNetwork)
                                .toNot(call { network in
                                    network.send(
                                        expectedRequest.body,
                                        to: expectedRequest.destination,
                                        requestTimeout: expectedRequest.requestTimeout,
                                        requestAndPathBuildTimeout: expectedRequest.requestAndPathBuildTimeout
                                    )
                                })
                        }
                    }
                    
                    // MARK: ------ and push notifications are enabled
                    context("and push notifications are enabled") {
                        beforeEach {
                            mockUserDefaults
                                .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                                .thenReturn(Data([5, 4, 3, 2, 1]).toHexString())
                            mockUserDefaults
                                .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                                .thenReturn(true)
                        }
                        
                        // MARK: -------- subscribes for push notifications
                        it("subscribes for push notifications") {
                            let expectedRequest: Network.PreparedRequest<PushNotificationAPI.SubscribeResponse> = mockStorage.read { db in
                                _ = try SessionThread.fetchOrCreate(
                                    db,
                                    id: groupId.hexString,
                                    variant: .group,
                                    creationDateTimestamp: 0,
                                    shouldBeVisible: nil,
                                    calledFromConfig: nil,
                                    using: dependencies
                                )
                                try ClosedGroup(
                                    threadId: groupId.hexString,
                                    name: "Test",
                                    formationTimestamp: 0,
                                    shouldPoll: nil,
                                    authData: inviteMessage.memberAuthData,
                                    invited: nil
                                ).upsert(db)
                                let result = try PushNotificationAPI.preparedSubscribe(
                                    db,
                                    token: Data(hex: Data([5, 4, 3, 2, 1]).toHexString()),
                                    sessionIds: [groupId],
                                    using: dependencies
                                )
                                
                                // Remove the debug group so it can be created during the actual test
                                try ClosedGroup.filter(id: groupId.hexString).deleteAll(db)
                                try SessionThread.filter(id: groupId.hexString).deleteAll(db)
                                
                                return result
                            }!
                            
                            mockStorage.write { db in
                                try MessageReceiver.handleGroupUpdateMessage(
                                    db,
                                    threadId: groupId.hexString,
                                    threadVariant: .group,
                                    message: inviteMessage,
                                    using: dependencies
                                )
                            }
                            
                            expect(mockNetwork)
                                .to(call(.exactly(times: 1), matchingParameters: .all) { network in
                                    network.send(
                                        expectedRequest.body,
                                        to: expectedRequest.destination,
                                        requestTimeout: expectedRequest.requestTimeout,
                                        requestAndPathBuildTimeout: expectedRequest.requestAndPathBuildTimeout
                                    )
                                })
                        }
                    }
                }
                
                // MARK: ---- adds the invited control message if the thread does not exist
                it("adds the invited control message if the thread does not exist") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: inviteMessage,
                            using: dependencies
                        )
                    }
                    
                    let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                    expect(interactions?.count).to(equal(1))
                    expect(interactions?.first?.body)
                        .to(equal("{\"invited\":{\"_0\":\"0511...1111\",\"_1\":\"TestGroup\"}}"))
                }
                
                // MARK: ---- does not add the invited control message if the thread already exists
                it("does not add the invited control message if the thread already exists") {
                    mockStorage.write { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            creationDateTimestamp: 1234567890,
                            shouldBeVisible: true,
                            calledFromConfig: nil,
                            using: dependencies
                        )
                    }
                    
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: inviteMessage,
                            using: dependencies
                        )
                    }
                    
                    let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                    expect(interactions?.count).to(equal(0))
                }
            }
            
            // MARK: -- when receiving a group promotion
            context("when receiving a group promotion") {
                @TestState var result: Result<Void, Error>!
                
                beforeEach {
                    var cMemberId: [CChar] = "05\(TestConstants.publicKey)".cString(using: .utf8)!
                    var member: config_group_member = config_group_member()
                    _ = groups_members_get_or_construct(groupMembersConf, &member, &cMemberId)
                    member.set(\.name, to: "TestName")
                    groups_members_set(groupMembersConf, &member)
                    
                    mockStorage.write { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            creationDateTimestamp: 1234567890,
                            shouldBeVisible: true,
                            calledFromConfig: nil,
                            using: dependencies
                        )
                        
                        try ClosedGroup(
                            threadId: groupId.hexString,
                            name: "TestGroup",
                            formationTimestamp: 1234567890,
                            shouldPoll: true,
                            groupIdentityPrivateKey: nil,
                            authData: Data([1, 2, 3]),
                            invited: false
                        ).upsert(db)
                    }
                }
                
                // MARK: ---- fails if it cannot convert the group seed to a groupIdentityKeyPair
                it("fails if it cannot convert the group seed to a groupIdentityKeyPair") {
                    mockCrypto.when { $0.generate(.ed25519KeyPair(seed: .any)) }.thenReturn(nil)
                    
                    mockStorage.write { db in
                        result = Result(catching: {
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: promoteMessage,
                                using: dependencies
                            )
                        })
                    }
                    
                    expect(result.failure).to(matchError(MessageReceiverError.invalidMessage))
                }
                
                // MARK: ---- updates the GROUP_KEYS state correctly
                it("updates the GROUP_KEYS state correctly") {
                    mockCrypto
                        .when { $0.generate(.ed25519KeyPair(seed: .any)) }
                        .thenReturn(KeyPair(publicKey: [1, 2, 3], secretKey: [4, 5, 6]))
                    
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: promoteMessage,
                            using: dependencies
                        )
                    }
                    
                    expect(LibSession.isAdmin(groupSessionId: groupId, using: dependencies))
                        .to(beTrue())
                }
                
                // MARK: ---- replaces the memberAuthData with the admin key in the database
                it("replaces the memberAuthData with the admin key in the database") {
                    mockStorage.write { db in
                        try ClosedGroup(
                            threadId: groupId.hexString,
                            name: "TestGroup",
                            formationTimestamp: 1234567890,
                            shouldPoll: true,
                            groupIdentityPrivateKey: nil,
                            authData: Data([1, 2, 3]),
                            invited: false
                        ).upsert(db)
                    }
                    
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: promoteMessage,
                            using: dependencies
                        )
                    }
                    
                    let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                    expect(groups?.count).to(equal(1))
                    expect(groups?.first?.groupIdentityPrivateKey).to(equal(Data(groupKeyPair.secretKey)))
                    expect(groups?.first?.authData).to(beNil())
                }
            }
            
            // MARK: -- when receiving an info changed message
            context("when receiving an info changed message") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            creationDateTimestamp: 1234567890,
                            shouldBeVisible: true,
                            calledFromConfig: nil,
                            using: dependencies
                        )
                    }
                }
                
                // MARK: ---- throws if there is no sender
                it("throws if there is no sender") {
                    infoChangedMessage.sender = nil
                    
                    mockStorage.write { db in
                        expect {
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: infoChangedMessage,
                                using: dependencies
                            )
                        }.to(throwError(MessageReceiverError.invalidMessage))
                    }
                }
                
                // MARK: ---- throws if there is no timestamp
                it("throws if there is no timestamp") {
                    infoChangedMessage.sentTimestampMs = nil
                    
                    mockStorage.write { db in
                        expect {
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: infoChangedMessage,
                                using: dependencies
                            )
                        }.to(throwError(MessageReceiverError.invalidMessage))
                    }
                }
                
                // MARK: ---- throws if the admin signature fails to verify
                it("throws if the admin signature fails to verify") {
                    mockCrypto
                        .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
                        .thenReturn(false)
                    
                    mockStorage.write { db in
                        expect {
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: infoChangedMessage,
                                using: dependencies
                            )
                        }.to(throwError(MessageReceiverError.invalidMessage))
                    }
                }
                
                // MARK: ---- for a name change
                context("for a name change") {
                    // MARK: ------ creates the correct control message
                    it("creates the correct control message") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: infoChangedMessage,
                                using: dependencies
                            )
                        }
                        
                        let interaction: Interaction? = mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .updatedName("TestGroup Rename")
                                .infoString(using: dependencies)
                        ))
                    }
                }
                
                // MARK: ---- for a display picture change
                context("for a display picture change") {
                    beforeEach {
                        infoChangedMessage = GroupUpdateInfoChangeMessage(
                            changeType: .avatar,
                            updatedName: nil,
                            updatedExpiration: nil,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        infoChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        infoChangedMessage.sentTimestampMs = 1234567800000
                    }
                    
                    // MARK: ------ creates the correct control message
                    it("creates the correct control message") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: infoChangedMessage,
                                using: dependencies
                            )
                        }
                        
                        let interaction: Interaction? = mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .updatedDisplayPicture
                                .infoString(using: dependencies)
                        ))
                    }
                }
                
                // MARK: ---- for a disappearing message setting change
                context("for a disappearing message setting change") {
                    beforeEach {
                        infoChangedMessage = GroupUpdateInfoChangeMessage(
                            changeType: .disappearingMessages,
                            updatedName: nil,
                            updatedExpiration: 3600,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        infoChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        infoChangedMessage.sentTimestampMs = 1234567800000
                    }
                    
                    // MARK: ------ creates the correct control message
                    it("creates the correct control message") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: infoChangedMessage,
                                using: dependencies
                            )
                        }
                        
                        let interaction: Interaction? = mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            DisappearingMessagesConfiguration(
                                threadId: groupId.hexString,
                                isEnabled: true,
                                durationSeconds: 3600,
                                type: .disappearAfterSend
                            ).messageInfoString(
                                threadVariant: .group,
                                senderName: infoChangedMessage.sender,
                                using: dependencies
                            )
                        ))
                        expect(interaction?.expiresInSeconds).to(beNil())
                    }
                }
            }
            
            // MARK: -- when receiving a member changed message
            context("when receiving a member changed message") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            creationDateTimestamp: 1234567890,
                            shouldBeVisible: true,
                            calledFromConfig: nil,
                            using: dependencies
                        )
                    }
                }
                
                // MARK: ---- throws if there is no sender
                it("throws if there is no sender") {
                    memberChangedMessage.sender = nil
                    
                    mockStorage.write { db in
                        expect {
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberChangedMessage,
                                using: dependencies
                            )
                        }.to(throwError(MessageReceiverError.invalidMessage))
                    }
                }
                
                // MARK: ---- throws if there is no timestamp
                it("throws if there is no timestamp") {
                    memberChangedMessage.sentTimestampMs = nil
                    
                    mockStorage.write { db in
                        expect {
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberChangedMessage,
                                using: dependencies
                            )
                        }.to(throwError(MessageReceiverError.invalidMessage))
                    }
                }
                
                // MARK: ---- throws if the admin signature fails to verify
                it("throws if the admin signature fails to verify") {
                    mockCrypto
                        .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
                        .thenReturn(false)
                    
                    mockStorage.write { db in
                        expect {
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberChangedMessage,
                                using: dependencies
                            )
                        }.to(throwError(MessageReceiverError.invalidMessage))
                    }
                }
                
                // MARK: ---- correctly retrieves the member name if present
                it("correctly retrieves the member name if present") {
                    mockStorage.write { db in
                        try Profile(
                            id: "051111111111111111111111111111111111111111111111111111111111111112",
                            name: "TestOtherProfile"
                        ).insert(db)
                    }
                    
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: memberChangedMessage,
                            using: dependencies
                        )
                    }
                    
                    let interaction: Interaction? = mockStorage.read { db in try Interaction.fetchOne(db) }
                    expect(interaction?.timestampMs).to(equal(1234567800000))
                    expect(interaction?.body).to(equal(
                        ClosedGroup.MessageInfo
                            .addedUsers(hasCurrentUser: false, names: ["TestOtherProfile"], historyShared: false)
                            .infoString(using: dependencies)
                    ))
                }
                
                // MARK: ---- for adding members
                context("for adding members") {
                    // MARK: ------ creates the correct control message for a single member
                    it("creates the correct control message for a single member") {
                        memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .added,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberChangedMessage,
                                using: dependencies
                            )
                        }
                        
                        let interaction: Interaction? = mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .addedUsers(
                                    hasCurrentUser: false,
                                    names: ["0511...1112"],
                                    historyShared: false
                                )
                                .infoString(using: dependencies)
                        ))
                    }
                    
                    // MARK: ------ creates the correct control message for two members
                    it("creates the correct control message for two members") {
                        memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .added,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112",
                                "051111111111111111111111111111111111111111111111111111111111111113"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberChangedMessage,
                                using: dependencies
                            )
                        }
                        
                        let interaction: Interaction? = mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .addedUsers(
                                    hasCurrentUser: false,
                                    names: ["0511...1112", "0511...1113"],
                                    historyShared: false
                                )
                                .infoString(using: dependencies)
                        ))
                    }
                    
                    // MARK: ------ creates the correct control message for many members
                    it("creates the correct control message for many members") {
                        memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .added,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112",
                                "051111111111111111111111111111111111111111111111111111111111111113",
                                "051111111111111111111111111111111111111111111111111111111111111114"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberChangedMessage,
                                using: dependencies
                            )
                        }
                        
                        let interaction: Interaction? = mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .addedUsers(
                                    hasCurrentUser: false,
                                    names: ["0511...1112", "0511...1113", "0511...1114"],
                                    historyShared: false
                                )
                                .infoString(using: dependencies)
                        ))
                    }
                }
                
                // MARK: ---- for removing members
                context("for removing members") {
                    // MARK: ------ creates the correct control message for a single member
                    it("creates the correct control message for a single member") {
                        memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .removed,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberChangedMessage,
                                using: dependencies
                            )
                        }
                        
                        let interaction: Interaction? = mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .removedUsers(hasCurrentUser: false, names: ["0511...1112"])
                                .infoString(using: dependencies)
                        ))
                    }
                    
                    // MARK: ------ creates the correct control message for two members
                    it("creates the correct control message for two members") {
                        memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .removed,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112",
                                "051111111111111111111111111111111111111111111111111111111111111113"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberChangedMessage,
                                using: dependencies
                            )
                        }
                        
                        let interaction: Interaction? = mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .removedUsers(hasCurrentUser: false, names: ["0511...1112", "0511...1113"])
                                .infoString(using: dependencies)
                        ))
                    }
                    
                    // MARK: ------ creates the correct control message for many members
                    it("creates the correct control message for many members") {
                        memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .removed,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112",
                                "051111111111111111111111111111111111111111111111111111111111111113",
                                "051111111111111111111111111111111111111111111111111111111111111114"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberChangedMessage,
                                using: dependencies
                            )
                        }
                        
                        let interaction: Interaction? = mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .removedUsers(hasCurrentUser: false, names: ["0511...1112", "0511...1113", "0511...1114"])
                                .infoString(using: dependencies)
                        ))
                    }
                }
                
                // MARK: ---- for promoting members
                context("for promoting members") {
                    // MARK: ------ creates the correct control message for a single member
                    it("creates the correct control message for a single member") {
                        memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .promoted,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberChangedMessage,
                                using: dependencies
                            )
                        }
                        
                        let interaction: Interaction? = mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .promotedUsers(hasCurrentUser: false, names: ["0511...1112"])
                                .infoString(using: dependencies)
                        ))
                    }
                    
                    // MARK: ------ creates the correct control message for two members
                    it("creates the correct control message for two members") {
                        memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .promoted,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112",
                                "051111111111111111111111111111111111111111111111111111111111111113"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberChangedMessage,
                                using: dependencies
                            )
                        }
                        
                        let interaction: Interaction? = mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .promotedUsers(hasCurrentUser: false, names: ["0511...1112", "0511...1113"])
                                .infoString(using: dependencies)
                        ))
                    }
                    
                    // MARK: ------ creates the correct control message for many members
                    it("creates the correct control message for many members") {
                        memberChangedMessage = GroupUpdateMemberChangeMessage(
                            changeType: .promoted,
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112",
                                "051111111111111111111111111111111111111111111111111111111111111113",
                                "051111111111111111111111111111111111111111111111111111111111111114"
                            ],
                            historyShared: false,
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberChangedMessage,
                                using: dependencies
                            )
                        }
                        
                        let interaction: Interaction? = mockStorage.read { db in try Interaction.fetchOne(db) }
                        expect(interaction?.timestampMs).to(equal(1234567800000))
                        expect(interaction?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .promotedUsers(hasCurrentUser: false, names: ["0511...1112", "0511...1113", "0511...1114"])
                                .infoString(using: dependencies)
                        ))
                    }
                }
            }
            
            // MARK: -- when receiving a member left message
            context("when receiving a member left message") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            creationDateTimestamp: 1234567890,
                            shouldBeVisible: true,
                            calledFromConfig: nil,
                            using: dependencies
                        )
                    }
                }
                
                // MARK: ---- does not create a control message
                it("does not create a control message") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: memberLeftMessage,
                            using: dependencies
                        )
                    }
                    
                    let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                    expect(interactions).to(beEmpty())
                }
                
                // MARK: ---- throws if there is no sender
                it("throws if there is no sender") {
                    memberLeftMessage.sender = nil
                    
                    mockStorage.write { db in
                        expect {
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberLeftMessage,
                                using: dependencies
                            )
                        }.to(throwError(MessageReceiverError.invalidMessage))
                    }
                }
                
                // MARK: ---- throws if there is no timestamp
                it("throws if there is no timestamp") {
                    memberLeftMessage.sentTimestampMs = nil
                    
                    mockStorage.write { db in
                        expect {
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberLeftMessage,
                                using: dependencies
                            )
                        }.to(throwError(MessageReceiverError.invalidMessage))
                    }
                }
                
                // MARK: ---- when the current user is a group admin
                context("when the current user is a group admin") {
                    beforeEach {
                        // Only update members if they already exist in the group
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                        var groupMember: config_group_member = config_group_member()
                        _ = groups_members_get_or_construct(groupMembersConf, &groupMember, &cMemberId)
                        groupMember.set(\.name, to: "TestOtherName")
                        groups_members_set(groupMembersConf, &groupMember)
                        
                        mockStorage.write { db in
                            try ClosedGroup(
                                threadId: groupId.hexString,
                                name: "TestGroup",
                                formationTimestamp: 1234567890,
                                shouldPoll: true,
                                groupIdentityPrivateKey: groupSecretKey,
                                authData: nil,
                                invited: false
                            ).upsert(db)
                            
                            try GroupMember(
                                groupId: groupId.hexString,
                                profileId: "051111111111111111111111111111111111111111111111111111111111111112",
                                role: .standard,
                                roleStatus: .accepted,
                                isHidden: false
                            ).upsert(db)
                        }
                    }
                    
                    // MARK: ------ flags the member for removal keeping their messages
                    it("flags the member for removal keeping their messages") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberLeftMessage,
                                using: dependencies
                            )
                        }
                        
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                        var groupMember: config_group_member = config_group_member()
                        expect(groups_members_get(groupMembersConf, &groupMember, &cMemberId)).to(beTrue())
                        expect(groupMember.removed).to(equal(1))
                    }
                    
                    // MARK: ------ removes the GroupMember
                    it("removes the GroupMember") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberLeftMessage,
                                using: dependencies
                            )
                        }
                        
                        let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                        expect(members).to(beEmpty())
                    }
                    
                    // MARK: ------ schedules a job to process the pending removal
                    it("schedules a job to process the pending removal") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberLeftMessage,
                                using: dependencies
                            )
                        }
                        
                        expect(mockJobRunner)
                            .to(call(matchingParameters: .all) {
                                $0.add(
                                    .any,
                                    job: Job(
                                        variant: .processPendingGroupMemberRemovals,
                                        threadId: groupId.hexString,
                                        details: ProcessPendingGroupMemberRemovalsJob.Details(
                                            changeTimestampMs: 1234567800000
                                        )
                                    ),
                                    canStartJob: true
                                )
                            })
                    }
                    
                    // MARK: ------ does not schedule a member change control message to be sent
                    it("does not schedule a member change control message to be sent") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: memberLeftMessage,
                                using: dependencies
                            )
                        }
                        
                        expect(mockJobRunner)
                            .toNot(call(.exactly(times: 1), matchingParameters: .all) {
                                $0.add(
                                    .any,
                                    job: Job(
                                        variant: .messageSend,
                                        threadId: groupId.hexString,
                                        interactionId: nil,
                                        details: MessageSendJob.Details(
                                            destination: .closedGroup(groupPublicKey: groupId.hexString),
                                            message: try! GroupUpdateMemberChangeMessage(
                                                changeType: .removed,
                                                memberSessionIds: [
                                                    "051111111111111111111111111111111111111111111111111111111111111112"
                                                ],
                                                historyShared: false,
                                                sentTimestampMs: 1234567800000,
                                                authMethod: Authentication.groupAdmin(
                                                    groupSessionId: groupId,
                                                    ed25519SecretKey: Array(groupSecretKey)
                                                ),
                                                using: dependencies
                                            )
                                        )
                                    ),
                                    canStartJob: true
                                )
                            })
                    }
                }
            }
            
            // MARK: -- when receiving a member left notification message
            context("when receiving a member left notification message") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            creationDateTimestamp: 1234567890,
                            shouldBeVisible: true,
                            calledFromConfig: nil,
                            using: dependencies
                        )
                    }
                }
                
                // MARK: ---- creates the correct control message
                it("creates the correct control message") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: memberLeftNotificationMessage,
                            using: dependencies
                        )
                    }
                    
                    let interaction: Interaction? = mockStorage.read { db in try Interaction.fetchOne(db) }
                    expect(interaction?.timestampMs).to(equal(1234567800000))
                    expect(interaction?.body).to(equal(
                        ClosedGroup.MessageInfo
                            .memberLeft(wasCurrentUser: false, name: "0511...1112")
                            .infoString(using: dependencies)
                    ))
                }
                
                // MARK: ---- correctly retrieves the member name if present
                it("correctly retrieves the member name if present") {
                    mockStorage.write { db in
                        try Profile(
                            id: "051111111111111111111111111111111111111111111111111111111111111112",
                            name: "TestOtherProfile"
                        ).insert(db)
                    }
                    
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: memberLeftNotificationMessage,
                            using: dependencies
                        )
                    }
                    
                    let interaction: Interaction? = mockStorage.read { db in try Interaction.fetchOne(db) }
                    expect(interaction?.timestampMs).to(equal(1234567800000))
                    expect(interaction?.body).to(equal(
                        ClosedGroup.MessageInfo
                            .memberLeft(wasCurrentUser: false, name: "TestOtherProfile")
                            .infoString(using: dependencies)
                    ))
                }
            }
            
            // MARK: -- when receiving an invite response message
            context("when receiving an invite response message") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            creationDateTimestamp: 1234567890,
                            shouldBeVisible: true,
                            calledFromConfig: nil,
                            using: dependencies
                        )
                    }
                }
                
                // MARK: ---- throws if there is no sender
                it("throws if there is no sender") {
                    inviteResponseMessage.sender = nil
                    
                    mockStorage.write { db in
                        expect {
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteResponseMessage,
                                using: dependencies
                            )
                        }.to(throwError(MessageReceiverError.invalidMessage))
                    }
                }
                
                // MARK: ---- throws if there is no timestamp
                it("throws if there is no timestamp") {
                    inviteResponseMessage.sentTimestampMs = nil
                    
                    mockStorage.write { db in
                        expect {
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteResponseMessage,
                                using: dependencies
                            )
                        }.to(throwError(MessageReceiverError.invalidMessage))
                    }
                }
                
                // MARK: ---- updates the profile information in the database if provided
                it("updates the profile information in the database if provided") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: inviteResponseMessage,
                            using: dependencies
                        )
                    }
                    
                    let profiles: [Profile]? = mockStorage.read { db in try Profile.fetchAll(db) }
                    expect(profiles?.map { $0.id }).to(equal([
                        "05\(TestConstants.publicKey)",
                        "051111111111111111111111111111111111111111111111111111111111111112"
                    ]))
                    expect(profiles?.map { $0.name }).to(equal(["TestCurrentUser", "TestOtherMember"]))
                }
                
                // MARK: ---- and the current user is a group admin
                context("and the current user is a group admin") {
                    beforeEach {
                        // Only update members if they already exist in the group
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                        var groupMember: config_group_member = config_group_member()
                        _ = groups_members_get_or_construct(groupMembersConf, &groupMember, &cMemberId)
                        groupMember.set(\.name, to: "TestOtherMember")
                        groupMember.invited = 1
                        groups_members_set(groupMembersConf, &groupMember)
                        
                        mockStorage.write { db in
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
                    
                    // MARK: ------ updates a pending member entry to an accepted member
                    it("updates a pending member entry to an accepted member") {
                        mockStorage.write { db in
                            try GroupMember(
                                groupId: groupId.hexString,
                                profileId: "051111111111111111111111111111111111111111111111111111111111111112",
                                role: .standard,
                                roleStatus: .pending,
                                isHidden: false
                            ).upsert(db)
                        }
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteResponseMessage,
                                using: dependencies
                            )
                        }
                        
                        let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                        expect(members?.count).to(equal(1))
                        expect(members?.first?.profileId).to(equal(
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ))
                        expect(members?.first?.role).to(equal(.standard))
                        expect(members?.first?.roleStatus).to(equal(.accepted))
                        
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                        var groupMember: config_group_member = config_group_member()
                        expect(groups_members_get(groupMembersConf, &groupMember, &cMemberId)).to(beTrue())
                        expect(groupMember.invited).to(equal(0))
                    }
                    
                    // MARK: ------ updates a failed member entry to an accepted member
                    it("updates a failed member entry to an accepted member") {
                        var cMemberId1: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                        var groupMember1: config_group_member = config_group_member()
                        _ = groups_members_get(groupMembersConf, &groupMember1, &cMemberId1)
                        groupMember1.invited = 2
                        groups_members_set(groupMembersConf, &groupMember1)
                        
                        mockStorage.write { db in
                            try GroupMember(
                                groupId: groupId.hexString,
                                profileId: "051111111111111111111111111111111111111111111111111111111111111112",
                                role: .standard,
                                roleStatus: .failed,
                                isHidden: false
                            ).upsert(db)
                        }
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteResponseMessage,
                                using: dependencies
                            )
                        }
                        
                        let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                        expect(members?.count).to(equal(1))
                        expect(members?.first?.profileId).to(equal(
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ))
                        expect(members?.first?.role).to(equal(.standard))
                        expect(members?.first?.roleStatus).to(equal(.accepted))
                        
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                        var groupMember: config_group_member = config_group_member()
                        expect(groups_members_get(groupMembersConf, &groupMember, &cMemberId)).to(beTrue())
                        expect(groupMember.invited).to(equal(0))
                    }
                    
                    // MARK: ------ updates the entry in libSession directly if there is no database value
                    it("updates the entry in libSession directly if there is no database value") {
                        mockStorage.write { db in
                            _ = try GroupMember.deleteAll(db)
                        }
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteResponseMessage,
                                using: dependencies
                            )
                        }
                        
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                        var groupMember: config_group_member = config_group_member()
                        expect(groups_members_get(groupMembersConf, &groupMember, &cMemberId)).to(beTrue())
                        expect(groupMember.invited).to(equal(0))
                    }
                    
                    // MARK: ---- updates the config member entry with profile information if provided
                    it("updates the config member entry with profile information if provided") {
                        mockStorage.write { db in
                            _ = try GroupMember.deleteAll(db)
                        }
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: inviteResponseMessage,
                                using: dependencies
                            )
                        }
                        
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                        var groupMember: config_group_member = config_group_member()
                        expect(groups_members_get(groupMembersConf, &groupMember, &cMemberId)).to(beTrue())
                        expect(groupMember.get(\.name)).to(equal("TestOtherMember"))
                    }
                }
            }
            
            // MARK: -- when receiving a delete content message
            context("when receiving a delete content message") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            creationDateTimestamp: 1234567890,
                            shouldBeVisible: true,
                            calledFromConfig: nil,
                            using: dependencies
                        )
                        
                        _ = try Interaction(
                            id: 1,
                            serverHash: "TestMessageHash1",
                            messageUuid: nil,
                            threadId: groupId.hexString,
                            authorId: "051111111111111111111111111111111111111111111111111111111111111111",
                            variant: .standardIncoming,
                            body: "Test1",
                            timestampMs: 1234560000001,
                            receivedAtTimestampMs: 1234560000001,
                            wasRead: false,
                            hasMention: false,
                            expiresInSeconds: 0,
                            expiresStartedAtMs: nil,
                            linkPreviewUrl: nil,
                            openGroupServerMessageId: nil,
                            openGroupWhisper: false,
                            openGroupWhisperMods: false,
                            openGroupWhisperTo: nil,
                            state: .sent,
                            recipientReadTimestampMs: nil,
                            mostRecentFailureText: nil,
                            transientDependencies: EquatableIgnoring(value: dependencies)
                        ).inserted(db)
                        
                        _ = try Interaction(
                            id: 2,
                            serverHash: "TestMessageHash2",
                            messageUuid: nil,
                            threadId: groupId.hexString,
                            authorId: "051111111111111111111111111111111111111111111111111111111111111111",
                            variant: .standardIncoming,
                            body: "Test2",
                            timestampMs: 1234567890002,
                            receivedAtTimestampMs: 1234567890002,
                            wasRead: false,
                            hasMention: false,
                            expiresInSeconds: 0,
                            expiresStartedAtMs: nil,
                            linkPreviewUrl: nil,
                            openGroupServerMessageId: nil,
                            openGroupWhisper: false,
                            openGroupWhisperMods: false,
                            openGroupWhisperTo: nil,
                            state: .sent,
                            recipientReadTimestampMs: nil,
                            mostRecentFailureText: nil,
                            transientDependencies: EquatableIgnoring(value: dependencies)
                        ).inserted(db)
                        
                        _ = try Interaction(
                            id: 3,
                            serverHash: "TestMessageHash3",
                            messageUuid: nil,
                            threadId: groupId.hexString,
                            authorId: "051111111111111111111111111111111111111111111111111111111111111112",
                            variant: .standardIncoming,
                            body: "Test3",
                            timestampMs: 1234560000003,
                            receivedAtTimestampMs: 1234560000003,
                            wasRead: false,
                            hasMention: false,
                            expiresInSeconds: 0,
                            expiresStartedAtMs: nil,
                            linkPreviewUrl: nil,
                            openGroupServerMessageId: nil,
                            openGroupWhisper: false,
                            openGroupWhisperMods: false,
                            openGroupWhisperTo: nil,
                            state: .sent,
                            recipientReadTimestampMs: nil,
                            mostRecentFailureText: nil,
                            transientDependencies: EquatableIgnoring(value: dependencies)
                        ).inserted(db)
                        
                        _ = try Interaction(
                            id: 4,
                            serverHash: "TestMessageHash4",
                            messageUuid: nil,
                            threadId: groupId.hexString,
                            authorId: "051111111111111111111111111111111111111111111111111111111111111112",
                            variant: .standardIncoming,
                            body: "Test4",
                            timestampMs: 1234567890004,
                            receivedAtTimestampMs: 1234567890004,
                            wasRead: false,
                            hasMention: false,
                            expiresInSeconds: 0,
                            expiresStartedAtMs: nil,
                            linkPreviewUrl: nil,
                            openGroupServerMessageId: nil,
                            openGroupWhisper: false,
                            openGroupWhisperMods: false,
                            openGroupWhisperTo: nil,
                            state: .sent,
                            recipientReadTimestampMs: nil,
                            mostRecentFailureText: nil,
                            transientDependencies: EquatableIgnoring(value: dependencies)
                        ).inserted(db)
                    }
                }
                
                // MARK: ---- throws if there is no sender and no admin signature
                it("throws if there is no sender and no admin signature") {
                    deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                        memberSessionIds: ["051111111111111111111111111111111111111111111111111111111111111112"],
                        messageHashes: [],
                        adminSignature: nil
                    )
                    deleteContentMessage.sentTimestampMs = 1234567800000
                    
                    mockStorage.write { db in
                        expect {
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: deleteContentMessage,
                                using: dependencies
                            )
                        }.to(throwError(MessageReceiverError.invalidMessage))
                    }
                }
                
                // MARK: ---- throws if there is no timestamp
                it("throws if there is no timestamp") {
                    deleteContentMessage.sentTimestampMs = nil
                    
                    mockStorage.write { db in
                        expect {
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: deleteContentMessage,
                                using: dependencies
                            )
                        }.to(throwError(MessageReceiverError.invalidMessage))
                    }
                }
                
                // MARK: ---- throws if the admin signature fails to verify
                it("throws if the admin signature fails to verify") {
                    mockCrypto
                        .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
                        .thenReturn(false)
                    
                    mockStorage.write { db in
                        expect {
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: deleteContentMessage,
                                using: dependencies
                            )
                        }.to(throwError(MessageReceiverError.invalidMessage))
                    }
                }
                
                // MARK: ---- and there is no admin signature
                context("and there is no admin signature") {
                    // MARK: ------ removes content for specific messages from the database
                    it("removes content for specific messages from the database") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash3"],
                            adminSignature: nil
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        deleteContentMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: deleteContentMessage,
                                using: dependencies
                            )
                        }
                        
                        let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                        expect(interactions?.count).to(equal(4))    // Message isn't deleted, just content
                        expect(interactions?.map { $0.serverHash }).toNot(contain("TestMessageHash3"))
                        expect(interactions?.map { $0.body }).toNot(contain("Test3"))
                    }
                    
                    // MARK: ------ removes content for all messages from the sender from the database
                    it("removes content for all messages from the sender from the database") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112"
                            ],
                            messageHashes: [],
                            adminSignature: nil
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        deleteContentMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: deleteContentMessage,
                                using: dependencies
                            )
                        }
                        
                        let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                        expect(interactions?.count).to(equal(4))    // Message isn't deleted, just content
                        expect(interactions?.map { $0.serverHash }).toNot(contain("TestMessageHash3"))
                        expect(interactions?.map { $0.body }).toNot(contain("Test3"))
                    }
                    
                    // MARK: ------ ignores messages not sent by the sender
                    it("ignores messages not sent by the sender") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash1", "TestMessageHash3"],
                            adminSignature: nil
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        deleteContentMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: deleteContentMessage,
                                using: dependencies
                            )
                        }
                        
                        let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                        expect(interactions?.count).to(equal(4))
                        expect(interactions?.map { $0.serverHash }).to(equal([
                            "TestMessageHash1", "TestMessageHash2", nil, "TestMessageHash4"
                        ]))
                        expect(interactions?.map { $0.body }).to(equal([
                            "Test1",
                            "Test2",
                            nil,
                            "Test4"
                        ]))
                        expect(interactions?.map { $0.authorId }).to(equal([
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111112",
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ]))
                        expect(interactions?.map { $0.timestampMs }).to(equal([
                            1234560000001,
                            1234567890002,
                            1234560000003,
                            1234567890004
                        ]))
                    }
                    
                    // MARK: ------ ignores messages sent after the delete content message was sent
                    it("ignores messages sent after the delete content message was sent") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash3", "TestMessageHash4"],
                            adminSignature: nil
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        deleteContentMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: deleteContentMessage,
                                using: dependencies
                            )
                        }
                        
                        let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                        expect(interactions?.count).to(equal(4))
                        expect(interactions?.map { $0.serverHash }).to(equal([
                            "TestMessageHash1", "TestMessageHash2", nil, "TestMessageHash4"
                        ]))
                        expect(interactions?.map { $0.body }).to(equal([
                            "Test1",
                            "Test2",
                            nil,
                            "Test4"
                        ]))
                        expect(interactions?.map { $0.authorId }).to(equal([
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111112",
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ]))
                        expect(interactions?.map { $0.timestampMs }).to(equal([
                            1234560000001,
                            1234567890002,
                            1234560000003,
                            1234567890004
                        ]))
                    }
                }
                
                // MARK: ---- and there is no admin signature
                context("and there is no admin signature") {
                    // MARK: ------ removes content for specific messages from the database
                    it("removes content for specific messages from the database") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash3"],
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        deleteContentMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: deleteContentMessage,
                                using: dependencies
                            )
                        }
                        
                        let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                        expect(interactions?.count).to(equal(4))
                        expect(interactions?.map { $0.serverHash }).toNot(contain("TestMessageHash3"))
                        expect(interactions?.map { $0.body }).toNot(contain("Test3"))
                    }
                    
                    // MARK: ------ removes content for all messages for a given id from the database
                    it("removes content for all messages for a given id from the database") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112"
                            ],
                            messageHashes: [],
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        deleteContentMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: deleteContentMessage,
                                using: dependencies
                            )
                        }
                        
                        let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                        expect(interactions?.count).to(equal(4))
                        expect(interactions?.map { $0.serverHash }).toNot(contain("TestMessageHash3"))
                        expect(interactions?.map { $0.body }).toNot(contain("Test3"))
                    }
                    
                    // MARK: ------ removes content for specific messages sent from a user that is not the sender from the database
                    it("removes content for specific messages sent from a user that is not the sender from the database") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash3"],
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        deleteContentMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: deleteContentMessage,
                                using: dependencies
                            )
                        }
                        
                        let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                        expect(interactions?.count).to(equal(4))
                        expect(interactions?.map { $0.serverHash }).toNot(contain("TestMessageHash3"))
                        expect(interactions?.map { $0.body }).toNot(contain("Test3"))
                    }
                    
                    // MARK: ------ removes content for all messages for a given id that is not the sender from the database
                    it("removes content for all messages for a given id that is not the sender from the database") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112"
                            ],
                            messageHashes: [],
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        deleteContentMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: deleteContentMessage,
                                using: dependencies
                            )
                        }
                        
                        let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                        expect(interactions?.count).to(equal(4))
                        expect(interactions?.map { $0.serverHash }).toNot(contain("TestMessageHash3"))
                        expect(interactions?.map { $0.body }).toNot(contain("Test3"))
                    }
                    
                    // MARK: ------ ignores messages sent after the delete content message was sent
                    it("ignores messages sent after the delete content message was sent") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111111",
                                "051111111111111111111111111111111111111111111111111111111111111112"
                            ],
                            messageHashes: [],
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        deleteContentMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: deleteContentMessage,
                                using: dependencies
                            )
                        }
                        
                        let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                        expect(interactions?.count).to(equal(4))
                        expect(interactions?.map { $0.serverHash }).to(equal([
                            nil, "TestMessageHash2", nil, "TestMessageHash4"
                        ]))
                        expect(interactions?.map { $0.authorId }).to(equal([
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111112",
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ]))
                        expect(interactions?.map { $0.timestampMs }).to(equal([
                            1234560000001,
                            1234567890002,
                            1234560000003,
                            1234567890004
                        ]))
                    }
                }
                
                // MARK: ---- and the current user is an admin
                context("and the current user is an admin") {
                    beforeEach {
                        mockStorage.write { db in
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
                    
                    // MARK: ------ deletes the messages from the swarm
                    it("deletes the messages from the swarm") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash3"],
                            adminSignature: nil
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        deleteContentMessage.sentTimestampMs = 1234567800000
                        
                        let preparedRequest: Network.PreparedRequest<[String: Bool]> = try! SnodeAPI
                            .preparedDeleteMessages(
                                serverHashes: ["TestMessageHash3"],
                                requireSuccessfulDeletion: false,
                                authMethod: Authentication.groupAdmin(
                                    groupSessionId: groupId,
                                    ed25519SecretKey: Array(groupSecretKey)
                                ),
                                using: dependencies
                            )
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: deleteContentMessage,
                                using: dependencies
                            )
                        }
                        
                        expect(mockNetwork)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { network in
                                network.send(
                                    preparedRequest.body,
                                    to: preparedRequest.destination,
                                    requestTimeout: preparedRequest.requestTimeout,
                                    requestAndPathBuildTimeout: preparedRequest.requestAndPathBuildTimeout
                                )
                            })
                    }
                }
                
                // MARK: ---- and the current user is not an admin
                context("and the current user is not an admin") {
                    // MARK: ------ does not delete the messages from the swarm
                    it("does not delete the messages from the swarm") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash3"],
                            adminSignature: nil
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        deleteContentMessage.sentTimestampMs = 1234567800000
                        
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupUpdateMessage(
                                db,
                                threadId: groupId.hexString,
                                threadVariant: .group,
                                message: deleteContentMessage,
                                using: dependencies
                            )
                        }
                        
                        expect(mockNetwork)
                            .toNot(call { network in
                                network.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any)
                            })
                    }
                }
            }
            
            // MARK: -- when receiving a delete message
            context("when receiving a delete message") {
                beforeEach {
                    var cGroupId: [CChar] = groupId.hexString.cString(using: .utf8)!
                    var userGroup: ugroups_group_info = ugroups_group_info()
                    user_groups_get_or_construct_group(userGroupsConfig.conf, &userGroup, &cGroupId)
                    userGroup.set(\.name, to: "TestName")
                    user_groups_set_group(userGroupsConfig.conf, &userGroup)
                    
                    // Rekey a couple of times to increase the key generation to 1
                    var fakeHash1: [CChar] = "fakehash1".cString(using: .utf8)!
                    var fakeHash2: [CChar] = "fakehash2".cString(using: .utf8)!
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
                            creationDateTimestamp: 1234567890,
                            shouldBeVisible: true,
                            calledFromConfig: nil,
                            using: dependencies
                        )
                        
                        try ClosedGroup(
                            threadId: groupId.hexString,
                            name: "TestGroup",
                            formationTimestamp: 1234567890,
                            shouldPoll: true,
                            groupIdentityPrivateKey: nil,
                            authData: Data([1, 2, 3]),
                            invited: false
                        ).upsert(db)
                        
                        try GroupMember(
                            groupId: groupId.hexString,
                            profileId: "05\(TestConstants.publicKey)",
                            role: .standard,
                            roleStatus: .accepted,
                            isHidden: false
                        ).insert(db)
                        
                        _ = try Interaction(
                            id: 1,
                            serverHash: nil,
                            messageUuid: nil,
                            threadId: groupId.hexString,
                            authorId: "051111111111111111111111111111111111111111111111111111111111111111",
                            variant: .standardIncoming,
                            body: "Test",
                            timestampMs: 1234567890,
                            receivedAtTimestampMs: 1234567890,
                            wasRead: false,
                            hasMention: false,
                            expiresInSeconds: 0,
                            expiresStartedAtMs: nil,
                            linkPreviewUrl: nil,
                            openGroupServerMessageId: nil,
                            openGroupWhisper: false,
                            openGroupWhisperMods: false,
                            openGroupWhisperTo: nil,
                            state: .sent,
                            recipientReadTimestampMs: nil,
                            mostRecentFailureText: nil,
                            transientDependencies: EquatableIgnoring(value: dependencies)
                        ).inserted(db)
                        
                        try ConfigDump(
                            variant: .groupKeys,
                            sessionId: groupId.hexString,
                            data: Data([1, 2, 3]),
                            timestampMs: 1234567890
                        ).insert(db)
                        
                        try ConfigDump(
                            variant: .groupInfo,
                            sessionId: groupId.hexString,
                            data: Data([1, 2, 3]),
                            timestampMs: 1234567890
                        ).insert(db)
                        
                        try ConfigDump(
                            variant: .groupMembers,
                            sessionId: groupId.hexString,
                            data: Data([1, 2, 3]),
                            timestampMs: 1234567890
                        ).insert(db)
                    }
                }
                    
                // MARK: ---- deletes any interactions from the conversation
                it("deletes any interactions from the conversation") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupDelete(
                            db,
                            groupSessionId: groupId,
                            plaintext: deleteMessage,
                            using: dependencies
                        )
                    }
                    
                    let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                    expect(interactions).to(beEmpty())
                }
                
                // MARK: ---- deletes the group auth data
                it("deletes the group auth data") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupDelete(
                            db,
                            groupSessionId: groupId,
                            plaintext: deleteMessage,
                            using: dependencies
                        )
                    }
                    
                    let authData: [Data?]? = mockStorage.read { db in
                        try ClosedGroup
                            .select(ClosedGroup.Columns.authData)
                            .asRequest(of: Data?.self)
                            .fetchAll(db)
                    }
                    let privateKeyData: [Data?]? = mockStorage.read { db in
                        try ClosedGroup
                            .select(ClosedGroup.Columns.groupIdentityPrivateKey)
                            .asRequest(of: Data?.self)
                            .fetchAll(db)
                    }
                    expect(authData).to(equal([nil]))
                    expect(privateKeyData).to(equal([nil]))
                }
                
                // MARK: ---- deletes the group members
                it("deletes the group members") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupDelete(
                            db,
                            groupSessionId: groupId,
                            plaintext: deleteMessage,
                            using: dependencies
                        )
                    }
                    
                    let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(members).to(beEmpty())
                }
                
                // MARK: ---- removes the group libSession state
                it("removes the group libSession state") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupDelete(
                            db,
                            groupSessionId: groupId,
                            plaintext: deleteMessage,
                            using: dependencies
                        )
                    }
                    
                    expect(mockLibSessionCache)
                        .to(call(.exactly(times: 1), matchingParameters: .all) {
                            $0.removeConfigs(for: groupId)
                        })
                }
                
                // MARK: ---- removes the cached libSession state dumps
                it("removes the cached libSession state dumps") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupDelete(
                            db,
                            groupSessionId: groupId,
                            plaintext: deleteMessage,
                            using: dependencies
                        )
                    }
                    
                    expect(mockLibSessionCache)
                        .to(call(.exactly(times: 1), matchingParameters: .all) {
                            $0.removeConfigs(for: groupId)
                        })
                    
                    let dumps: [ConfigDump]? = mockStorage.read { db in
                        try ConfigDump
                            .filter(ConfigDump.Columns.publicKey == groupId.hexString)
                            .fetchAll(db)
                    }
                    expect(dumps).to(beEmpty())
                }
                
                // MARK: ------ unsubscribes from push notifications
                it("unsubscribes from push notifications") {
                    mockUserDefaults
                        .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                        .thenReturn(Data([5, 4, 3, 2, 1]).toHexString())
                    mockUserDefaults
                        .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                        .thenReturn(true)
                    
                    let expectedRequest: Network.PreparedRequest<PushNotificationAPI.UnsubscribeResponse> = mockStorage.read { db in
                        try PushNotificationAPI.preparedUnsubscribe(
                            db,
                            token: Data([5, 4, 3, 2, 1]),
                            sessionIds: [groupId],
                            using: dependencies
                        )
                    }!
                    
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupDelete(
                            db,
                            groupSessionId: groupId,
                            plaintext: deleteMessage,
                            using: dependencies
                        )
                    }
                    
                    expect(mockNetwork)
                        .to(call(.exactly(times: 1), matchingParameters: .all) { network in
                            network.send(
                                expectedRequest.body,
                                to: expectedRequest.destination,
                                requestTimeout: expectedRequest.requestTimeout,
                                requestAndPathBuildTimeout: expectedRequest.requestAndPathBuildTimeout
                            )
                        })
                }
                
                // MARK: ---- and the group is an invitation
                context("and the group is an invitation") {
                    beforeEach {
                        mockStorage.write { db in
                            try ClosedGroup.updateAll(db, ClosedGroup.Columns.invited.set(to: true))
                        }
                    }
                    
                    // MARK: ------ deletes the thread
                    it("deletes the thread") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: groupId,
                                plaintext: deleteMessage,
                                using: dependencies
                            )
                        }
                        
                        let threads: [SessionThread]? = mockStorage.read { db in try SessionThread.fetchAll(db) }
                        expect(threads).to(beEmpty())
                    }
                    
                    // MARK: ------ deletes the group
                    it("deletes the group") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: groupId,
                                plaintext: deleteMessage,
                                using: dependencies
                            )
                        }
                        
                        let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                        expect(groups).to(beEmpty())
                    }
                    
                    // MARK: ---- stops the poller
                    it("stops the poller") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: groupId,
                                plaintext: deleteMessage,
                                using: dependencies
                            )
                        }
                        
                        expect(mockGroupPollersCache)
                            .to(call(.exactly(times: 1), matchingParameters: .all) {
                                $0.stopAndRemovePoller(for: groupId.hexString)
                            })
                    }
                    
                    // MARK: ------ removes the group from the USER_GROUPS config
                    it("removes the group from the USER_GROUPS config") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: groupId,
                                plaintext: deleteMessage,
                                using: dependencies
                            )
                        }
                        
                        var cGroupId: [CChar] = groupId.hexString.cString(using: .utf8)!
                        var userGroup: ugroups_group_info = ugroups_group_info()
                        expect(user_groups_get_group(userGroupsConfig.conf, &userGroup, &cGroupId)).to(beFalse())
                    }
                }
                
                // MARK: ---- and the group is not an invitation
                context("and the group is not an invitation") {
                    beforeEach {
                        mockStorage.write { db in
                            try ClosedGroup.updateAll(db, ClosedGroup.Columns.invited.set(to: false))
                        }
                    }
                    
                    // MARK: ------ does not delete the thread
                    it("does not delete the thread") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: groupId,
                                plaintext: deleteMessage,
                                using: dependencies
                            )
                        }
                        
                        let threads: [SessionThread]? = mockStorage.read { db in try SessionThread.fetchAll(db) }
                        expect(threads).toNot(beEmpty())
                    }
                    
                    // MARK: ------ does not remove the group from the USER_GROUPS config
                    it("does not remove the group from the USER_GROUPS config") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: groupId,
                                plaintext: deleteMessage,
                                using: dependencies
                            )
                        }
                        
                        var cGroupId: [CChar] = groupId.hexString.cString(using: .utf8)!
                        var userGroup: ugroups_group_info = ugroups_group_info()
                        expect(user_groups_get_group(userGroupsConfig.conf, &userGroup, &cGroupId)).to(beTrue())
                    }
                    
                    // MARK: ---- stops the poller and flags the group to not poll
                    it("stops the poller and flags the group to not poll") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: groupId,
                                plaintext: deleteMessage,
                                using: dependencies
                            )
                        }
                        
                        let shouldPoll: [Bool]? = mockStorage.read { db in
                            try ClosedGroup
                                .select(ClosedGroup.Columns.shouldPoll)
                                .asRequest(of: Bool.self)
                                .fetchAll(db)
                        }
                        expect(mockGroupPollersCache)
                            .to(call(.exactly(times: 1), matchingParameters: .all) {
                                $0.stopAndRemovePoller(for: groupId.hexString)
                            })
                        expect(shouldPoll).to(equal([false]))
                    }
                    
                    // MARK: ------ marks the group in USER_GROUPS as kicked
                    it("marks the group in USER_GROUPS as kicked") {
                        mockStorage.write { db in
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: groupId,
                                plaintext: deleteMessage,
                                using: dependencies
                            )
                        }
                        
                        var cGroupId: [CChar] = groupId.hexString.cString(using: .utf8)!
                        var userGroup: ugroups_group_info = ugroups_group_info()
                        expect(user_groups_get_group(userGroupsConfig.conf, &userGroup, &cGroupId)).to(beTrue())
                        expect(ugroups_group_is_kicked(&userGroup)).to(beTrue())
                    }
                }
                
                // MARK: ---- throws if the data is invalid
                it("throws if the data is invalid") {
                    deleteMessage = Data([1, 2, 3])
                    
                    mockStorage.write { db in
                        expect {
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: groupId,
                                plaintext: deleteMessage,
                                using: dependencies
                            )
                        }
                        .to(throwError(MessageReceiverError.invalidMessage))
                    }
                }
                
                // MARK: ---- throws if the included member id does not match the current user
                it("throws if the included member id does not match the current user") {
                    deleteMessage = try! LibSessionMessage.groupKicked(
                        memberId: "051111111111111111111111111111111111111111111111111111111111111111",
                        groupKeysGen: 1
                    ).1
                    
                    mockStorage.write { db in
                        expect {
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: groupId,
                                plaintext: deleteMessage,
                                using: dependencies
                            )
                        }
                        .to(throwError(MessageReceiverError.invalidMessage))
                    }
                }
                
                // MARK: ---- throws if the key generation is earlier than the current keys generation
                it("throws if the key generation is earlier than the current keys generation") {
                    deleteMessage = try! LibSessionMessage.groupKicked(
                        memberId: "05\(TestConstants.publicKey)",
                        groupKeysGen: 0
                    ).1
                    
                    mockStorage.write { db in
                        expect {
                            try MessageReceiver.handleGroupDelete(
                                db,
                                groupSessionId: groupId,
                                plaintext: deleteMessage,
                                using: dependencies
                            )
                        }
                        .to(throwError(MessageReceiverError.invalidMessage))
                    }
                }
            }
            
            // MARK: -- when receiving a visible message from a member that is not accepted and the current user is a group admin
            context("when receiving a visible message from a member that is not accepted and the current user is a group admin") {
                beforeEach {
                    // Only update members if they already exist in the group
                    var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                    var groupMember: config_group_member = config_group_member()
                    _ = groups_members_get_or_construct(groupMembersConf, &groupMember, &cMemberId)
                    groupMember.set(\.name, to: "TestOtherMember")
                    groupMember.invited = 1
                    groups_members_set(groupMembersConf, &groupMember)
                    
                    mockStorage.write { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            creationDateTimestamp: 1234567890,
                            shouldBeVisible: true,
                            calledFromConfig: nil,
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
                
                // MARK: ---- updates a pending member entry to an accepted member
                it("updates a pending member entry to an accepted member") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: groupId.hexString,
                            profileId: "051111111111111111111111111111111111111111111111111111111111111112",
                            role: .standard,
                            roleStatus: .pending,
                            isHidden: false
                        ).upsert(db)
                    }
                    
                    mockStorage.write { db in
                        try MessageReceiver.handle(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: visibleMessage,
                            serverExpirationTimestamp: nil,
                            associatedWithProto: visibleMessageProto,
                            using: dependencies
                        )
                    }
                    
                    let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(members?.count).to(equal(1))
                    expect(members?.first?.profileId).to(equal(
                        "051111111111111111111111111111111111111111111111111111111111111112"
                    ))
                    expect(members?.first?.role).to(equal(.standard))
                    expect(members?.first?.roleStatus).to(equal(.accepted))
                    
                    var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                    var groupMember: config_group_member = config_group_member()
                    expect(groups_members_get(groupMembersConf, &groupMember, &cMemberId)).to(beTrue())
                    expect(groupMember.invited).to(equal(0))
                }
                
                // MARK: ---- updates a failed member entry to an accepted member
                it("updates a failed member entry to an accepted member") {
                    var cMemberId1: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                    var groupMember1: config_group_member = config_group_member()
                    _ = groups_members_get(groupMembersConf, &groupMember1, &cMemberId1)
                    groupMember1.invited = 2
                    groups_members_set(groupMembersConf, &groupMember1)
                    
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: groupId.hexString,
                            profileId: "051111111111111111111111111111111111111111111111111111111111111112",
                            role: .standard,
                            roleStatus: .failed,
                            isHidden: false
                        ).upsert(db)
                    }
                    
                    mockStorage.write { db in
                        try MessageReceiver.handle(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: visibleMessage,
                            serverExpirationTimestamp: nil,
                            associatedWithProto: visibleMessageProto,
                            using: dependencies
                        )
                    }
                    
                    let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(members?.count).to(equal(1))
                    expect(members?.first?.profileId).to(equal(
                        "051111111111111111111111111111111111111111111111111111111111111112"
                    ))
                    expect(members?.first?.role).to(equal(.standard))
                    expect(members?.first?.roleStatus).to(equal(.accepted))
                    
                    var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                    var groupMember: config_group_member = config_group_member()
                    expect(groups_members_get(groupMembersConf, &groupMember, &cMemberId)).to(beTrue())
                    expect(groupMember.invited).to(equal(0))
                }
                
                // MARK: ---- updates the entry in libSession directly if there is no database value
                it("updates the entry in libSession directly if there is no database value") {
                    mockStorage.write { db in
                        _ = try GroupMember.deleteAll(db)
                    }
                    
                    mockStorage.write { db in
                        try MessageReceiver.handle(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: visibleMessage,
                            serverExpirationTimestamp: nil,
                            associatedWithProto: visibleMessageProto,
                            using: dependencies
                        )
                    }
                    
                    var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cString(using: .utf8)!
                    var groupMember: config_group_member = config_group_member()
                    expect(groups_members_get(groupMembersConf, &groupMember, &cMemberId)).to(beTrue())
                    expect(groupMember.invited).to(equal(0))
                }
            }
        }
    }
}

// MARK: - Convenience

private extension LibSession.Config {
    var conf: UnsafeMutablePointer<config_object>? {
        switch self {
            case .object(let conf): return conf
            default: return nil
        }
    }
}

private extension Result {
    var failure: Failure? {
        switch self {
            case .success: return nil
            case .failure(let error): return error
        }
    }
}
