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
        @TestState var groupKeyPair: KeyPair! = Crypto().generate(.ed25519KeyPair(seed: Array(groupSeed)))
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
                SNSnodeKit.self,
                SNMessagingKit.self,
                SNUIKit.self
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
                jobRunner
                    .when { $0.upsert(.any, job: .any, canStartJob: .any, using: .any) }
                    .thenReturn(nil)
            }
        )
        @TestState(singleton: .network, in: dependencies) var mockNetwork: MockNetwork! = MockNetwork(
            initialSetup: { network in
                network
                    .when { $0.send(.selectedNetworkRequest(.any, to: .any, with: .any, timeout: .any, using: .any)) }
                    .thenReturn(MockNetwork.response(with: FileUploadResponse(id: "1")))
                network
                    .when { $0.send(.selectedNetworkRequest(.any, to: .any, timeout: .any, using: .any)) }
                    .thenReturn(MockNetwork.nullResponse())
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
                
                cache
                    .when { $0.setConfig(for: .any, sessionId: .any, to: .any) }
                    .thenReturn(())
                cache
                    .when { $0.config(for: .userGroups, sessionId: userSessionId) }
                    .thenReturn(Atomic(userGroupsConfig))
                cache
                    .when { $0.config(for: .convoInfoVolatile, sessionId: userSessionId) }
                    .thenReturn(Atomic(convoInfoVolatileConfig))
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
                poller
                    .when { $0.stopPolling(for: .any) }
                    .thenReturn(())
            }
        )
        @TestState(singleton: .notificationsManager, in: dependencies) var mockNotificationsManager: MockNotificationsManager! = MockNotificationsManager(
            initialSetup: { notificationsManager in
                notificationsManager
                    .when { $0.notifyUser(.any, for: .any, in: .any, applicationState: .any, using: .any) }
                    .thenReturn(())
                notificationsManager
                    .when { $0.cancelNotifications(identifiers: .any) }
                    .thenReturn(())
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
            result.sentTimestamp = 1234567890000
            
            return result
        }()
        @TestState var promoteMessage: GroupUpdatePromoteMessage! = {
            let result: GroupUpdatePromoteMessage = GroupUpdatePromoteMessage(
                groupIdentitySeed: groupSeed,
                sentTimestamp: 1234567890000
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
            result.sentTimestamp = 1234567800000
            
            return result
        }()
        @TestState var memberChangedMessage: GroupUpdateMemberChangeMessage! = {
            let result: GroupUpdateMemberChangeMessage = GroupUpdateMemberChangeMessage(
                changeType: .added,
                memberSessionIds: ["051111111111111111111111111111111111111111111111111111111111111112"],
                adminSignature: .standard(signature: "TestSignature".bytes)
            )
            result.sender = "051111111111111111111111111111111111111111111111111111111111111111"
            result.sentTimestamp = 1234567800000
            
            return result
        }()
        @TestState var memberLeftMessage: GroupUpdateMemberLeftMessage! = {
            let result: GroupUpdateMemberLeftMessage = GroupUpdateMemberLeftMessage()
            result.sender = "051111111111111111111111111111111111111111111111111111111111111112"
            result.sentTimestamp = 1234567800000
            
            return result
        }()
        @TestState var inviteResponseMessage: GroupUpdateInviteResponseMessage! = {
            let result: GroupUpdateInviteResponseMessage = GroupUpdateInviteResponseMessage(
                isApproved: true,
                profile: VisibleMessage.VMProfile(displayName: "TestOtherMember"),
                sentTimestamp: 1234567800000
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
            result.sentTimestamp = 1234567800000
            
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
                sentTimestamp: ((1234568890 - (60 * 10)) * 1000),
                recipient: groupId.hexString,
                text: "Test"
            )
            result.receivedTimestamp = (1234568890 * 1000)
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
                    
                    // MARK: ------ schedules a displayPictureDownload job if there is a profile picture
                    it("schedules a displayPictureDownload job if there is a profile picture") {
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
                                    canStartJob: true,
                                    using: .any
                                )
                            })
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
                                isApproved: false
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
                        
                        var cGroupId: [CChar] = groupId.hexString.cArray.nullTerminated()
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
                        
                        expect(mockGroupsPoller).toNot(call { $0.startIfNeeded(for: .any, using: .any) })
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
                                        expiresInSeconds: 0,
                                        expiresStartedAtMs: nil,
                                        linkPreviewUrl: nil,
                                        openGroupServerMessageId: nil,
                                        openGroupWhisperMods: false,
                                        openGroupWhisperTo: nil
                                    ),
                                    in: SessionThread(
                                        id: groupId.hexString,
                                        variant: .group,
                                        shouldBeVisible: true,
                                        using: dependencies
                                    ),
                                    applicationState: .active,
                                    using: .any
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
                                isApproved: true
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
                        
                        var cGroupId: [CChar] = groupId.hexString.cArray.nullTerminated()
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
                        
                        expect(mockGroupsPoller).to(call(.exactly(times: 1), matchingParameters: .all) {
                            $0.startIfNeeded(for: groupId.hexString, using: .any)
                        })
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
                                    applicationState: .any,
                                    using: .any
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
                    
                    // MARK: ------ and push notifications are enabled
                    context("and push notifications are enabled") {
                        beforeEach {
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
                                    groupIdentityPrivateKey: nil,
                                    authData: Data([1, 2, 3]),
                                    invited: false
                                ).upsert(db)
                            }
                            mockUserDefaults
                                .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                                .thenReturn(Data([5, 4, 3, 2, 1]).toHexString())
                            mockUserDefaults
                                .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                                .thenReturn(true)
                        }
                        
                        // MARK: -------- subscribes for push notifications
                        it("subscribes for push notifications") {
                            mockStorage.write { db in
                                try MessageReceiver.handleGroupUpdateMessage(
                                    db,
                                    threadId: groupId.hexString,
                                    threadVariant: .group,
                                    message: inviteMessage,
                                    using: dependencies
                                )
                            }
                            
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
                            shouldBeVisible: true,
                            calledFromConfigHandling: false,
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
                    var cMemberId: [CChar] = "05\(TestConstants.publicKey)".cArray
                    var member: config_group_member = config_group_member()
                    _ = groups_members_get_or_construct(groupMembersConf, &member, &cMemberId)
                    member.name = "TestName".toLibSession()
                    groups_members_set(groupMembersConf, &member)
                    
                    mockStorage.write(using: dependencies) { db in
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
                            groupIdentityPrivateKey: nil,
                            authData: Data([1, 2, 3]),
                            invited: false
                        ).upsert(db)
                    }
                }
                
                // MARK: ---- promotes the user to admin within the group
                it("promotes the user to admin within the group") {
                    mockCrypto.when { $0.generate(.ed25519KeyPair(seed: .any)) }.thenReturn(nil)
                    
                    mockStorage.write { db in
                        result = Result(try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: promoteMessage,
                            using: dependencies
                        ))
                    }
                    
                    expect(result.failure).to(matchError(MessageReceiverError.invalidMessage))
                }
                
                // MARK: ---- updates the GROUP_KEYS state correctly
                it("updates the GROUP_KEYS state correctly") {
                    mockCrypto.when { $0.generate(.ed25519KeyPair(seed: .any)) }.thenReturn(nil)
                    
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
                
                // MARK: ---- updates a standard member entry to an accepted admin
                it("updates a standard member entry to an accepted admin") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: groupId.hexString,
                            profileId: "05\(TestConstants.publicKey)",
                            role: .standard,
                            roleStatus: .accepted,
                            isHidden: false
                        ).insert(db)
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
                    
                    let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(members?.count).to(equal(1))
                    expect(members?.first?.role).to(equal(.admin))
                    expect(members?.first?.roleStatus).to(equal(.accepted))
                }
                
                // MARK: ---- updates a failed admin entry to an accepted admin
                it("updates a failed admin entry to an accepted admin") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: groupId.hexString,
                            profileId: "05\(TestConstants.publicKey)",
                            role: .admin,
                            roleStatus: .failed,
                            isHidden: false
                        ).insert(db)
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
                    
                    let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(members?.count).to(equal(1))
                    expect(members?.first?.role).to(equal(.admin))
                    expect(members?.first?.roleStatus).to(equal(.accepted))
                }
                
                // MARK: ---- updates a pending admin entry to an accepted admin
                it("updates a pending admin entry to an accepted admin") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: groupId.hexString,
                            profileId: "05\(TestConstants.publicKey)",
                            role: .admin,
                            roleStatus: .pending,
                            isHidden: false
                        ).insert(db)
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
                    
                    let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(members?.count).to(equal(1))
                    expect(members?.first?.role).to(equal(.admin))
                    expect(members?.first?.roleStatus).to(equal(.accepted))
                }
                
                // MARK: ---- updates a sending admin entry to an accepted admin
                it("updates a sending admin entry to an accepted admin") {
                    mockStorage.write { db in
                        try GroupMember(
                            groupId: groupId.hexString,
                            profileId: "05\(TestConstants.publicKey)",
                            role: .admin,
                            roleStatus: .sending,
                            isHidden: false
                        ).insert(db)
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
                    
                    let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                    expect(members?.count).to(equal(1))
                    expect(members?.first?.role).to(equal(.admin))
                    expect(members?.first?.roleStatus).to(equal(.accepted))
                }
                
                // MARK: ---- updates the member in GROUP_MEMBERS from a standard member to be an approved admin
                it("updates the member in GROUP_MEMBERS from a standard member to be an approved admin") {
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: promoteMessage,
                            using: dependencies
                        )
                    }
                    
                    var cMemberId: [CChar] = "05\(TestConstants.publicKey)".cArray
                    var groupMember: config_group_member = config_group_member()
                    _ = groups_members_get(groupMembersConf, &groupMember, &cMemberId)
                    expect(groupMember.admin).to(beTrue())
                    expect(groupMember.promoted).to(equal(0))
                }
                
                // MARK: ---- updates the member in GROUP_MEMBERS from a pending admin to be an approved admin
                it("updates the member in GROUP_MEMBERS from a pending admin to be an approved admin") {
                    var cMemberId: [CChar] = "05\(TestConstants.publicKey)".cArray
                    var initialMember: config_group_member = config_group_member()
                    _ = groups_members_get_or_construct(groupMembersConf, &initialMember, &cMemberId)
                    initialMember.promoted = 1
                    groups_members_set(groupMembersConf, &initialMember)
                    
                    mockStorage.write { db in
                        try MessageReceiver.handleGroupUpdateMessage(
                            db,
                            threadId: groupId.hexString,
                            threadVariant: .group,
                            message: promoteMessage,
                            using: dependencies
                        )
                    }
                    
                    var groupMember: config_group_member = config_group_member()
                    _ = groups_members_get(groupMembersConf, &groupMember, &cMemberId)
                    expect(groupMember.admin).to(beTrue())
                    expect(groupMember.promoted).to(equal(0))
                }
            }
            
            // MARK: -- when receiving an info changed message
            context("when receiving an info changed message") {
                beforeEach {
                    mockStorage.write(using: dependencies) { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            shouldBeVisible: true,
                            calledFromConfigHandling: false,
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
                    infoChangedMessage.sentTimestamp = nil
                    
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
                        infoChangedMessage.sentTimestamp = 1234567800000
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
                        infoChangedMessage.sentTimestamp = 1234567800000
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
                                type: .disappearAfterSend,
                                lastChangeTimestampMs: nil
                            ).messageInfoString(
                                with: infoChangedMessage.sender,
                                isPreviousOff: false,
                                using: dependencies
                            )
                        ))
                        expect(interaction?.expiresInSeconds).to(equal(0))
                    }
                }
            }
            
            // MARK: -- when receiving a member changed message
            context("when receiving a member changed message") {
                beforeEach {
                    mockStorage.write(using: dependencies) { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            shouldBeVisible: true,
                            calledFromConfigHandling: false,
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
                    memberChangedMessage.sentTimestamp = nil
                    
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
                            .addedUsers(names: ["TestOtherProfile"])
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
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestamp = 1234567800000
                        
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
                                .addedUsers(names: ["0511...1112"])
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
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestamp = 1234567800000
                        
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
                                .addedUsers(names: ["0511...1112", "0511...1113"])
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
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestamp = 1234567800000
                        
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
                                .addedUsers(names: ["0511...1112", "0511...1113", "0511...1114"])
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
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestamp = 1234567800000
                        
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
                                .removedUsers(names: ["0511...1112"])
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
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestamp = 1234567800000
                        
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
                                .removedUsers(names: ["0511...1112", "0511...1113"])
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
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestamp = 1234567800000
                        
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
                                .removedUsers(names: ["0511...1112", "0511...1113", "0511...1114"])
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
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestamp = 1234567800000
                        
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
                                .promotedUsers(names: ["0511...1112"])
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
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestamp = 1234567800000
                        
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
                                .promotedUsers(names: ["0511...1112", "0511...1113"])
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
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        memberChangedMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        memberChangedMessage.sentTimestamp = 1234567800000
                        
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
                                .promotedUsers(names: ["0511...1112", "0511...1113", "0511...1114"])
                                .infoString(using: dependencies)
                        ))
                    }
                }
            }
            
            // MARK: -- when receiving a member left message
            context("when receiving a member left message") {
                beforeEach {
                    mockStorage.write(using: dependencies) { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            shouldBeVisible: true,
                            calledFromConfigHandling: false,
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
                            message: memberLeftMessage,
                            using: dependencies
                        )
                    }
                    
                    let interaction: Interaction? = mockStorage.read { db in try Interaction.fetchOne(db) }
                    expect(interaction?.timestampMs).to(equal(1234567800000))
                    expect(interaction?.body).to(equal(
                        ClosedGroup.MessageInfo
                            .memberLeft(name: "0511...1112")
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
                            message: memberLeftMessage,
                            using: dependencies
                        )
                    }
                    
                    let interaction: Interaction? = mockStorage.read { db in try Interaction.fetchOne(db) }
                    expect(interaction?.timestampMs).to(equal(1234567800000))
                    expect(interaction?.body).to(equal(
                        ClosedGroup.MessageInfo
                            .memberLeft(name: "TestOtherProfile")
                            .infoString(using: dependencies)
                    ))
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
                    memberLeftMessage.sentTimestamp = nil
                    
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
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cArray
                        var groupMember: config_group_member = config_group_member()
                        _ = groups_members_get_or_construct(groupMembersConf, &groupMember, &cMemberId)
                        groupMember.name = "TestOtherName".toLibSession()
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
                        
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cArray
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
                            .to(call(.exactly(times: 1), matchingParameters: .all) {
                                $0.add(
                                    .any,
                                    job: Job(
                                        variant: .processPendingGroupMemberRemovals,
                                        threadId: groupId.hexString,
                                        details: ProcessPendingGroupMemberRemovalsJob.Details(
                                            changeTimestampMs: 1234567800000
                                        )
                                    ),
                                    canStartJob: true,
                                    using: .any
                                )
                            })
                    }
                    
                    // MARK: ------ does not add a member change control message
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
                        
                        let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                        expect(interactions?.count).to(equal(1))    // 1 for the 'member left' control message
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
                                                sentTimestamp: 1234567800000,
                                                authMethod: Authentication.groupAdmin(
                                                    groupSessionId: groupId,
                                                    ed25519SecretKey: Array(groupSecretKey)
                                                ),
                                                using: dependencies
                                            ),
                                            isSyncMessage: false
                                        )
                                    ),
                                    canStartJob: true,
                                    using: .any
                                )
                            })
                    }
                }
            }
            
            // MARK: -- when receiving an invite response message
            context("when receiving an invite response message") {
                beforeEach {
                    mockStorage.write(using: dependencies) { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            shouldBeVisible: true,
                            calledFromConfigHandling: false,
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
                    inviteResponseMessage.sentTimestamp = nil
                    
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
                
                // MARK: ---- updates the profile information if provided
                it("updates the profile information if provided") {
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
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cArray
                        var groupMember: config_group_member = config_group_member()
                        _ = groups_members_get_or_construct(groupMembersConf, &groupMember, &cMemberId)
                        groupMember.name = "TestOtherMember".toLibSession()
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
                        
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cArray
                        var groupMember: config_group_member = config_group_member()
                        expect(groups_members_get(groupMembersConf, &groupMember, &cMemberId)).to(beTrue())
                        expect(groupMember.invited).to(equal(0))
                    }
                    
                    // MARK: ------ updates a failed member entry to an accepted member
                    it("updates a failed member entry to an accepted member") {
                        var cMemberId1: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cArray
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
                        
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cArray
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
                        
                        var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cArray
                        var groupMember: config_group_member = config_group_member()
                        expect(groups_members_get(groupMembersConf, &groupMember, &cMemberId)).to(beTrue())
                        expect(groupMember.invited).to(equal(0))
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
                            shouldBeVisible: true,
                            calledFromConfigHandling: false,
                            using: dependencies
                        )
                        
                        _ = try Interaction(
                            id: 1,
                            serverHash: "TestMessageHash1",
                            messageUuid: nil,
                            threadId: groupId.hexString,
                            authorId: "051111111111111111111111111111111111111111111111111111111111111111",
                            variant: .standardIncoming,
                            body: "Test",
                            timestampMs: 1234560000001,
                            receivedAtTimestampMs: 1234560000001,
                            wasRead: false,
                            hasMention: false,
                            expiresInSeconds: 0,
                            expiresStartedAtMs: nil,
                            linkPreviewUrl: nil,
                            openGroupServerMessageId: nil,
                            openGroupWhisperMods: false,
                            openGroupWhisperTo: nil
                        ).inserted(db)
                        
                        _ = try Interaction(
                            id: 2,
                            serverHash: "TestMessageHash2",
                            messageUuid: nil,
                            threadId: groupId.hexString,
                            authorId: "051111111111111111111111111111111111111111111111111111111111111111",
                            variant: .standardIncoming,
                            body: "Test",
                            timestampMs: 1234567890002,
                            receivedAtTimestampMs: 1234567890002,
                            wasRead: false,
                            hasMention: false,
                            expiresInSeconds: 0,
                            expiresStartedAtMs: nil,
                            linkPreviewUrl: nil,
                            openGroupServerMessageId: nil,
                            openGroupWhisperMods: false,
                            openGroupWhisperTo: nil
                        ).inserted(db)
                        
                        _ = try Interaction(
                            id: 3,
                            serverHash: "TestMessageHash3",
                            messageUuid: nil,
                            threadId: groupId.hexString,
                            authorId: "051111111111111111111111111111111111111111111111111111111111111112",
                            variant: .standardIncoming,
                            body: "Test",
                            timestampMs: 1234560000003,
                            receivedAtTimestampMs: 1234560000003,
                            wasRead: false,
                            hasMention: false,
                            expiresInSeconds: 0,
                            expiresStartedAtMs: nil,
                            linkPreviewUrl: nil,
                            openGroupServerMessageId: nil,
                            openGroupWhisperMods: false,
                            openGroupWhisperTo: nil
                        ).inserted(db)
                        
                        _ = try Interaction(
                            id: 4,
                            serverHash: "TestMessageHash4",
                            messageUuid: nil,
                            threadId: groupId.hexString,
                            authorId: "051111111111111111111111111111111111111111111111111111111111111112",
                            variant: .standardIncoming,
                            body: "Test",
                            timestampMs: 1234567890004,
                            receivedAtTimestampMs: 1234567890004,
                            wasRead: false,
                            hasMention: false,
                            expiresInSeconds: 0,
                            expiresStartedAtMs: nil,
                            linkPreviewUrl: nil,
                            openGroupServerMessageId: nil,
                            openGroupWhisperMods: false,
                            openGroupWhisperTo: nil
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
                    deleteContentMessage.sentTimestamp = 1234567800000
                    
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
                    deleteContentMessage.sentTimestamp = nil
                    
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
                    // MARK: ------ removes specific messages from the database
                    it("removes specific messages from the database") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash3"],
                            adminSignature: nil
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        deleteContentMessage.sentTimestamp = 1234567800000
                        
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
                        expect(interactions?.count).to(equal(3))
                        expect(interactions?.map { $0.serverHash }).to(equal([
                            "TestMessageHash1", "TestMessageHash2", "TestMessageHash4"
                        ]))
                        expect(interactions?.map { $0.authorId }).to(equal([
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ]))
                        expect(interactions?.map { $0.timestampMs }).to(equal([
                            1234560000001,
                            1234567890002,
                            1234567890004
                        ]))
                    }
                    
                    // MARK: ------ removes all messages from the sender from the database
                    it("removes all messages from the sender from the database") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112"
                            ],
                            messageHashes: [],
                            adminSignature: nil
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        deleteContentMessage.sentTimestamp = 1234567800000
                        
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
                        expect(interactions?.count).to(equal(3))
                        expect(interactions?.map { $0.serverHash }).to(equal([
                            "TestMessageHash1", "TestMessageHash2", "TestMessageHash4"
                        ]))
                        expect(interactions?.map { $0.authorId }).to(equal([
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ]))
                        expect(interactions?.map { $0.timestampMs }).to(equal([
                            1234560000001,
                            1234567890002,
                            1234567890004
                        ]))
                    }
                    
                    // MARK: ------ ignores messages not sent by the sender
                    it("ignores messages not sent by the sender") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash1", "TestMessageHash3"],
                            adminSignature: nil
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        deleteContentMessage.sentTimestamp = 1234567800000
                        
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
                        expect(interactions?.count).to(equal(3))
                        expect(interactions?.map { $0.serverHash }).to(equal([
                            "TestMessageHash1", "TestMessageHash2", "TestMessageHash4"
                        ]))
                        expect(interactions?.map { $0.authorId }).to(equal([
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ]))
                        expect(interactions?.map { $0.timestampMs }).to(equal([
                            1234560000001,
                            1234567890002,
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
                        deleteContentMessage.sentTimestamp = 1234567800000
                        
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
                        expect(interactions?.count).to(equal(3))
                        expect(interactions?.map { $0.serverHash }).to(equal([
                            "TestMessageHash1", "TestMessageHash2", "TestMessageHash4"
                        ]))
                        expect(interactions?.map { $0.authorId }).to(equal([
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ]))
                        expect(interactions?.map { $0.timestampMs }).to(equal([
                            1234560000001,
                            1234567890002,
                            1234567890004
                        ]))
                    }
                }
                
                // MARK: ---- and there is no admin signature
                context("and there is no admin signature") {
                    // MARK: ------ removes specific messages from the database
                    it("removes specific messages from the database") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash3"],
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        deleteContentMessage.sentTimestamp = 1234567800000
                        
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
                        expect(interactions?.count).to(equal(3))
                        expect(interactions?.map { $0.serverHash }).to(equal([
                            "TestMessageHash1", "TestMessageHash2", "TestMessageHash4"
                        ]))
                        expect(interactions?.map { $0.authorId }).to(equal([
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ]))
                        expect(interactions?.map { $0.timestampMs }).to(equal([
                            1234560000001,
                            1234567890002,
                            1234567890004
                        ]))
                    }
                    
                    // MARK: ------ removes all messages for a given id from the database
                    it("removes all messages for a given id from the database") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112"
                            ],
                            messageHashes: [],
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        deleteContentMessage.sentTimestamp = 1234567800000
                        
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
                        expect(interactions?.count).to(equal(3))
                        expect(interactions?.map { $0.serverHash }).to(equal([
                            "TestMessageHash1", "TestMessageHash2", "TestMessageHash4"
                        ]))
                        expect(interactions?.map { $0.authorId }).to(equal([
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ]))
                        expect(interactions?.map { $0.timestampMs }).to(equal([
                            1234560000001,
                            1234567890002,
                            1234567890004
                        ]))
                    }
                    
                    // MARK: ------ removes specific messages sent from a user that is not the sender from the database
                    it("removes specific messages sent from a user that is not the sender from the database") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash3"],
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        deleteContentMessage.sentTimestamp = 1234567800000
                        
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
                        expect(interactions?.count).to(equal(3))
                        expect(interactions?.map { $0.serverHash }).to(equal([
                            "TestMessageHash1", "TestMessageHash2", "TestMessageHash4"
                        ]))
                        expect(interactions?.map { $0.authorId }).to(equal([
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ]))
                        expect(interactions?.map { $0.timestampMs }).to(equal([
                            1234560000001,
                            1234567890002,
                            1234567890004
                        ]))
                    }
                    
                    // MARK: ------ removes all messages for a given id that is not the sender from the database
                    it("removes all messages for a given id that is not the sender from the database") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [
                                "051111111111111111111111111111111111111111111111111111111111111112"
                            ],
                            messageHashes: [],
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111111"
                        deleteContentMessage.sentTimestamp = 1234567800000
                        
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
                        expect(interactions?.count).to(equal(3))
                        expect(interactions?.map { $0.serverHash }).to(equal([
                            "TestMessageHash1", "TestMessageHash2", "TestMessageHash4"
                        ]))
                        expect(interactions?.map { $0.authorId }).to(equal([
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ]))
                        expect(interactions?.map { $0.timestampMs }).to(equal([
                            1234560000001,
                            1234567890002,
                            1234567890004
                        ]))
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
                        deleteContentMessage.sentTimestamp = 1234567800000
                        
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
                        expect(interactions?.count).to(equal(2))
                        expect(interactions?.map { $0.serverHash }).to(equal([
                            "TestMessageHash2", "TestMessageHash4"
                        ]))
                        expect(interactions?.map { $0.authorId }).to(equal([
                            "051111111111111111111111111111111111111111111111111111111111111111",
                            "051111111111111111111111111111111111111111111111111111111111111112"
                        ]))
                        expect(interactions?.map { $0.timestampMs }).to(equal([
                            1234567890002,
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
                    
                    // MARK: ------ deletes the messages from the swarm if the sender was not an admin
                    it("deletes the messages from the swarm if the sender was not an admin") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash3"],
                            adminSignature: nil
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        deleteContentMessage.sentTimestamp = 1234567800000
                        
                        let expectedRequest: URLRequest = (try? SnodeAPI
                            .preparedDeleteMessages(
                                serverHashes: ["TestMessageHash3"],
                                requireSuccessfulDeletion: false,
                                authMethod: Authentication.groupAdmin(
                                    groupSessionId: groupId,
                                    ed25519SecretKey: Array(groupSecretKey)
                                ),
                                using: dependencies
                            ))!.request
                        
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
                                    .selectedNetworkRequest(
                                        expectedRequest.httpBody!,
                                        to: dependencies.randomElement(mockSwarmCache)!,
                                        timeout: HTTP.defaultTimeout,
                                        using: .any
                                    )
                                )
                            })
                    }
                    
                    // MARK: ------ does not delete the messages from the swarm if the sender was an admin
                    it("does not delete the messages from the swarm if the sender was an admin") {
                        deleteContentMessage = GroupUpdateDeleteMemberContentMessage(
                            memberSessionIds: [],
                            messageHashes: ["TestMessageHash3"],
                            adminSignature: .standard(signature: "TestSignature".bytes)
                        )
                        deleteContentMessage.sender = "051111111111111111111111111111111111111111111111111111111111111112"
                        deleteContentMessage.sentTimestamp = 1234567800000
                        
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
                                network.send(.selectedNetworkRequest(.any, to: .any, timeout: .any, using: .any))
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
                        deleteContentMessage.sentTimestamp = 1234567800000
                        
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
                                network.send(.selectedNetworkRequest(.any, to: .any, timeout: .any, using: .any))
                            })
                    }
                }
            }
            
            // MARK: -- when receiving a delete message
            context("when receiving a delete message") {
                beforeEach {
                    var cGroupId: [CChar] = groupId.hexString.cArray.nullTerminated()
                    var userGroup: ugroups_group_info = ugroups_group_info()
                    user_groups_get_or_construct_group(userGroupsConfig.conf, &userGroup, &cGroupId)
                    userGroup.name = "TestName".toLibSession()
                    user_groups_set_group(userGroupsConfig.conf, &userGroup)
                    
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
                            openGroupWhisperMods: false,
                            openGroupWhisperTo: nil
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
                            $0.setConfig(for: .groupKeys, sessionId: groupId, to: nil)
                        })
                    expect(mockLibSessionCache)
                        .to(call(.exactly(times: 1), matchingParameters: .all) {
                            $0.setConfig(for: .groupInfo, sessionId: groupId, to: nil)
                        })
                    expect(mockLibSessionCache)
                        .to(call(.exactly(times: 1), matchingParameters: .all) {
                            $0.setConfig(for: .groupMembers, sessionId: groupId, to: nil)
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
                            $0.setConfig(for: .groupKeys, sessionId: groupId, to: nil)
                        })
                    expect(mockLibSessionCache)
                        .to(call(.exactly(times: 1), matchingParameters: .all) {
                            $0.setConfig(for: .groupInfo, sessionId: groupId, to: nil)
                        })
                    expect(mockLibSessionCache)
                        .to(call(.exactly(times: 1), matchingParameters: .all) {
                            $0.setConfig(for: .groupMembers, sessionId: groupId, to: nil)
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
                    
                    let expectedRequest: URLRequest = mockStorage.read(using: dependencies) { db in
                        try PushNotificationAPI
                            .preparedUnsubscribe(
                                db,
                                token: Data([5, 4, 3, 2, 1]),
                                sessionIds: [groupId],
                                using: dependencies
                            )
                            .request
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
                        
                        expect(mockGroupsPoller)
                            .to(call(.exactly(times: 1), matchingParameters: .all) {
                                $0.stopPolling(for: groupId.hexString)
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
                        
                        var cGroupId: [CChar] = groupId.hexString.cArray.nullTerminated()
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
                        
                        var cGroupId: [CChar] = groupId.hexString.cArray.nullTerminated()
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
                        expect(mockGroupsPoller)
                            .to(call(.exactly(times: 1), matchingParameters: .all) {
                                $0.stopPolling(for: groupId.hexString)
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
                        
                        var cGroupId: [CChar] = groupId.hexString.cArray.nullTerminated()
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
                    var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cArray
                    var groupMember: config_group_member = config_group_member()
                    _ = groups_members_get_or_construct(groupMembersConf, &groupMember, &cMemberId)
                    groupMember.name = "TestOtherMember".toLibSession()
                    groupMember.invited = 1
                    groups_members_set(groupMembersConf, &groupMember)
                    
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
                    
                    var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cArray
                    var groupMember: config_group_member = config_group_member()
                    expect(groups_members_get(groupMembersConf, &groupMember, &cMemberId)).to(beTrue())
                    expect(groupMember.invited).to(equal(0))
                }
                
                // MARK: ---- updates a failed member entry to an accepted member
                it("updates a failed member entry to an accepted member") {
                    var cMemberId1: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cArray
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
                    
                    var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cArray
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
                    
                    var cMemberId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111112".cArray
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
