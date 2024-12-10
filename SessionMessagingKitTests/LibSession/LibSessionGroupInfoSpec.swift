// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionSnodeKit
@testable import SessionMessagingKit

class LibSessionGroupInfoSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
            }
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
            }
        )
        @TestState(singleton: .network, in: dependencies) var mockNetwork: MockNetwork! = MockNetwork(
            initialSetup: { network in
                network
                    .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
                    .thenReturn(MockNetwork.response(data: Data([1, 2, 3])))
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
        @TestState var createGroupOutput: LibSession.CreatedGroupInfo! = {
            mockStorage.write { db in
                 try LibSession.createGroup(
                    db,
                    name: "TestGroup",
                    description: nil,
                    displayPictureUrl: nil,
                    displayPictureFilename: nil,
                    displayPictureEncryptionKey: nil,
                    members: [],
                    using: dependencies
                 )
            }
        }()
        @TestState(cache: .libSession, in: dependencies) var mockLibSessionCache: MockLibSessionCache! = MockLibSessionCache(
            initialSetup: { cache in
                var conf: UnsafeMutablePointer<config_object>!
                var secretKey: [UInt8] = Array(Data(hex: TestConstants.edSecretKey))
                _ = user_groups_init(&conf, &secretKey, nil, 0, nil)
                
                cache.when { $0.setConfig(for: .any, sessionId: .any, to: .any) }.thenReturn(())
                cache.when { $0.removeConfigs(for: .any) }.thenReturn(())
                cache.when { $0.config(for: .userGroups, sessionId: .any) }
                    .thenReturn(.userGroups(conf))
                cache.when { $0.config(for: .groupInfo, sessionId: .any) }
                    .thenReturn(createGroupOutput.groupState[.groupInfo])
                cache.when { $0.config(for: .groupMembers, sessionId: .any) }
                    .thenReturn(createGroupOutput.groupState[.groupMembers])
                cache.when { $0.config(for: .groupKeys, sessionId: .any) }
                    .thenReturn(createGroupOutput.groupState[.groupKeys])
                cache.when { $0.configNeedsDump(.any) }.thenReturn(true)
                cache.when { try $0.createDump(config: .any, for: .any, sessionId: .any, timestampMs: .any) }.thenReturn(nil)
                cache.when { try $0.performAndPushChange(.any, for: .any, sessionId: .any, change: { _ in }) }.thenReturn(nil)
                cache
                    .when { $0.pinnedPriority(.any, threadId: .any, threadVariant: .any) }
                    .thenReturn(LibSession.defaultNewThreadPriority)
                cache.when { $0.disappearingMessagesConfig(threadId: .any, threadVariant: .any) }
                    .thenReturn(nil)
            }
        )
        
        // MARK: - LibSessionGroupInfo
        describe("LibSessionGroupInfo") {
            // MARK: -- when handling a GROUP_INFO update
            context("when handling a GROUP_INFO update") {
                @TestState var latestGroup: ClosedGroup?
                @TestState var initialDisappearingConfig: DisappearingMessagesConfiguration?
                @TestState var latestDisappearingConfig: DisappearingMessagesConfiguration?
                
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.upsert(
                            db,
                            id: createGroupOutput.group.threadId,
                            variant: .group,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(1234567890),
                                shouldBeVisible: .setTo(true)
                            ),
                            calledFromConfig: nil,
                            using: dependencies
                        )
                        try createGroupOutput.group.insert(db)
                        try createGroupOutput.members.forEach { try $0.insert(db) }
                        initialDisappearingConfig = try DisappearingMessagesConfiguration
                            .fetchOne(db, id: createGroupOutput.group.threadId)
                            .defaulting(
                                to: DisappearingMessagesConfiguration.defaultWith(createGroupOutput.group.threadId)
                            )
                    }
                }
                
                // MARK: ---- does nothing if there are no changes
                it("does nothing if there are no changes") {
                    mockLibSessionCache.when { $0.configNeedsDump(.any) }.thenReturn(false)
                    
                    mockStorage.write { db in
                        try mockLibSessionCache.handleGroupInfoUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupInfo],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                            serverTimestampMs: 1234567891000
                        )
                    }
                    
                    latestGroup = mockStorage.read { db in
                        try ClosedGroup.fetchOne(db, id: createGroupOutput.group.threadId)
                    }
                    expect(createGroupOutput.groupState[.groupInfo]).toNot(beNil())
                    expect(createGroupOutput.group).to(equal(latestGroup))
                }
                
                // MARK: ---- throws if the config is invalid
                it("throws if the config is invalid") {
                    mockStorage.write { db in
                        expect {
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupMembers]!,
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                                serverTimestampMs: 1234567891000
                            )
                        }
                        .to(throwError())
                    }
                }
                
                // MARK: ---- removes group data if the group is destroyed
                it("removes group data if the group is destroyed") {
                    createGroupOutput.groupState[.groupInfo]?.conf.map { groups_info_destroy_group($0) }
                    
                    mockStorage.write { db in
                        try mockLibSessionCache.handleGroupInfoUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupInfo],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                            serverTimestampMs: 1234567891000
                        )
                    }
                    
                    latestGroup = mockStorage.read { db in
                        try ClosedGroup.fetchOne(db, id: createGroupOutput.group.threadId)
                    }
                    expect(latestGroup?.authData).to(beNil())
                    expect(latestGroup?.groupIdentityPrivateKey).to(beNil())
                }
                
                // MARK: ---- updates the name if it changed
                it("updates the name if it changed") {
                    createGroupOutput.groupState[.groupInfo]?.conf.map {
                        var updatedName: [CChar] = "UpdatedName".cString(using: .utf8)!
                        groups_info_set_name($0, &updatedName)
                    }
                    
                    mockStorage.write { db in
                        try mockLibSessionCache.handleGroupInfoUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupInfo],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                            serverTimestampMs: 1234567891000
                        )
                    }
                    
                    latestGroup = mockStorage.read { db in
                        try ClosedGroup.fetchOne(db, id: createGroupOutput.group.threadId)
                    }
                    expect(createGroupOutput.group.name).to(equal("TestGroup"))
                    expect(latestGroup?.name).to(equal("UpdatedName"))
                }
                
                // MARK: ---- updates the description if it changed
                it("updates the description if it changed") {
                    createGroupOutput.groupState[.groupInfo]?.conf.map {
                        var updatedDesc: [CChar] = "UpdatedDesc".cString(using: .utf8)!
                        groups_info_set_description($0, &updatedDesc)
                    }
                    
                    mockStorage.write { db in
                        try mockLibSessionCache.handleGroupInfoUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupInfo],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                            serverTimestampMs: 1234567891000
                        )
                    }
                    
                    latestGroup = mockStorage.read { db in
                        try ClosedGroup.fetchOne(db, id: createGroupOutput.group.threadId)
                    }
                    expect(createGroupOutput.group.groupDescription).to(beNil())
                    expect(latestGroup?.groupDescription).to(equal("UpdatedDesc"))
                }
                
                // MARK: ---- updates the formation timestamp if it is later than the current value
                it("updates the formation timestamp if it is later than the current value") {
                    // Note: the 'formationTimestamp' stores the "joinedAt" date so we on'y update it if it's later
                    // than the current value (as we don't want to replace the record of when the current user joined
                    // the group with when the group was originally created)
                    mockStorage.write { db in try ClosedGroup.updateAll(db, ClosedGroup.Columns.formationTimestamp.set(to: 50000)) }
                    createGroupOutput.groupState[.groupInfo]?.conf.map { groups_info_set_created($0, 54321) }
                    let originalGroup: ClosedGroup? = mockStorage.read { db in
                        try ClosedGroup.fetchOne(db, id: createGroupOutput.group.threadId)
                    }
                    
                    mockStorage.write { db in
                        try mockLibSessionCache.handleGroupInfoUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupInfo],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                            serverTimestampMs: 1234567891000
                        )
                    }
                    
                    latestGroup = mockStorage.read { db in
                        try ClosedGroup.fetchOne(db, id: createGroupOutput.group.threadId)
                    }
                    expect(originalGroup?.formationTimestamp).to(equal(50000))
                    expect(latestGroup?.formationTimestamp).to(equal(54321))
                }
                
                // MARK: ---- and the display picture was changed
                context("and the display picture was changed") {
                    // MARK: ------ removes the display picture
                    it("removes the display picture") {
                        mockStorage.write { db in
                            try ClosedGroup
                                .updateAll(
                                    db,
                                    ClosedGroup.Columns.displayPictureUrl.set(to: "TestUrl"),
                                    ClosedGroup.Columns.displayPictureEncryptionKey.set(to: Data([1, 2, 3])),
                                    ClosedGroup.Columns.displayPictureFilename.set(to: "TestFilename")
                                )
                        }
                        
                        mockStorage.write { db in
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo],
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                                serverTimestampMs: 1234567891000
                            )
                        }
                        
                        latestGroup = mockStorage.read { db in
                            try ClosedGroup.fetchOne(db, id: createGroupOutput.group.threadId)
                        }
                        expect(latestGroup?.displayPictureUrl).to(beNil())
                        expect(latestGroup?.displayPictureEncryptionKey).to(beNil())
                        expect(latestGroup?.displayPictureFilename).to(beNil())
                        expect(latestGroup?.lastDisplayPictureUpdate).to(equal(1234567891))
                    }
                    
                    // MARK: ------ schedules a display picture download job if there is a new one
                    it("schedules a display picture download job if there is a new one") {
                        createGroupOutput.groupState[.groupInfo]?.conf.map {
                            var displayPic: user_profile_pic = user_profile_pic()
                            displayPic.set(\.url, to: "https://www.oxen.io/file/1234")
                            displayPic.set(\.key, to: Data(repeating: 1, count: DisplayPictureManager.aes256KeyByteLength))
                            groups_info_set_pic($0, displayPic)
                        }
                        
                        mockStorage.write { db in
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo],
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                                serverTimestampMs: 1234567891000
                            )
                        }
                        
                        expect(mockJobRunner)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { jobRunner in
                                jobRunner.add(
                                    .any,
                                    job: Job(
                                        variant: .displayPictureDownload,
                                        behaviour: .runOnce,
                                        shouldBlock: false,
                                        shouldBeUnique: true,
                                        shouldSkipLaunchBecomeActive: false,
                                        details: DisplayPictureDownloadJob.Details(
                                            target: .group(
                                                id: createGroupOutput.group.threadId,
                                                url: "https://www.oxen.io/file/1234",
                                                encryptionKey: Data(
                                                    repeating: 1,
                                                    count: DisplayPictureManager.aes256KeyByteLength
                                                )
                                            ),
                                            timestamp: 1234567891
                                        )
                                    ),
                                    canStartJob: true
                                )
                            })
                    }
                }
                
                // MARK: ---- updates the disappearing messages config
                it("updates the disappearing messages config") {
                    createGroupOutput.groupState[.groupInfo]?.conf.map { groups_info_set_expiry_timer($0, 10) }
                    
                    mockStorage.write { db in
                        try mockLibSessionCache.handleGroupInfoUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupInfo],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                            serverTimestampMs: 1234567891000
                        )
                    }
                    
                    latestDisappearingConfig = mockStorage.read { db in
                        try DisappearingMessagesConfiguration.fetchOne(db, id: createGroupOutput.group.threadId)
                    }
                    expect(initialDisappearingConfig?.isEnabled).to(beFalse())
                    expect(initialDisappearingConfig?.durationSeconds).to(equal(0))
                    expect(latestDisappearingConfig?.isEnabled).to(beTrue())
                    expect(latestDisappearingConfig?.durationSeconds).to(equal(10))
                }
                
                // MARK: ---- containing a deleteBefore timestamp
                context("containing a deleteBefore timestamp") {
                    @TestState var numInteractions: Int!
                    
                    // MARK: ------ deletes messages before the timestamp
                    it("deletes messages before the timestamp") {
                        mockStorage.write { db in
                            try SessionThread.upsert(
                                db,
                                id: createGroupOutput.group.threadId,
                                variant: .contact,
                                values: SessionThread.TargetValues(
                                    creationDateTimestamp: .setTo(1234567890),
                                    shouldBeVisible: .setTo(true)
                                ),
                                calledFromConfig: nil,
                                using: dependencies
                            )
                            _ = try Interaction(
                                serverHash: "1234",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4321",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 100000000,
                                receivedAtTimestampMs: 1234567890,
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
                                transientDependencies: nil
                            ).inserted(db)
                        }
                        
                        createGroupOutput.groupState[.groupInfo]?.conf.map { groups_info_set_delete_before($0, 123456) }
                        
                        mockStorage.write { db in
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo],
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                                serverTimestampMs: 1234567891000
                            )
                        }
                        
                        numInteractions = mockStorage.read { db in
                            try Interaction.fetchCount(db)
                        }
                        expect(numInteractions).to(equal(0))
                    }
                    
                    // MARK: ------ does not delete messages after the timestamp
                    it("does not delete messages after the timestamp") {
                        mockStorage.write { db in
                            try SessionThread.upsert(
                                db,
                                id: createGroupOutput.group.threadId,
                                variant: .contact,
                                values: SessionThread.TargetValues(
                                    creationDateTimestamp: .setTo(1234567890),
                                    shouldBeVisible: .setTo(true)
                                ),
                                calledFromConfig: nil,
                                using: dependencies
                            )
                            _ = try Interaction(
                                serverHash: "1234",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4321",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 100000000,
                                receivedAtTimestampMs: 1234567890,
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
                                transientDependencies: nil
                            ).inserted(db)
                            _ = try Interaction(
                                serverHash: "1235",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4322",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 200000000,
                                receivedAtTimestampMs: 2234567890,
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
                                transientDependencies: nil
                            ).inserted(db)
                        }
                        
                        createGroupOutput.groupState[.groupInfo]?.conf.map { groups_info_set_delete_before($0, 123456) }
                        
                        mockStorage.write { db in
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo],
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                                serverTimestampMs: 1234567891000
                            )
                        }
                        
                        numInteractions = mockStorage.read { db in
                            try Interaction.fetchCount(db)
                        }
                        expect(numInteractions).to(equal(1))
                    }
                }
                
                // MARK: ---- containing a deleteAttachmentsBefore timestamp
                context("containing a deleteAttachmentsBefore timestamp") {
                    @TestState var numInteractions: Int!
                    
                    // MARK: ------ deletes messages with attachments before the timestamp
                    it("deletes messages with attachments before the timestamp") {
                        mockStorage.write { db in
                            try SessionThread.upsert(
                                db,
                                id: createGroupOutput.group.threadId,
                                variant: .contact,
                                values: SessionThread.TargetValues(
                                    creationDateTimestamp: .setTo(1234567890),
                                    shouldBeVisible: .setTo(true)
                                ),
                                calledFromConfig: nil,
                                using: dependencies
                            )
                            let interaction: Interaction = try Interaction(
                                serverHash: "1234",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4321",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 100000000,
                                receivedAtTimestampMs: 1234567890,
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
                                transientDependencies: nil
                            ).inserted(db)
                            _ = try Attachment(
                                id: "AttachmentId",
                                variant: .standard,
                                contentType: "Test",
                                byteCount: 1234
                            ).inserted(db)
                            _ = try InteractionAttachment(
                                albumIndex: 1,
                                interactionId: interaction.id!,
                                attachmentId: "AttachmentId"
                            ).inserted(db)
                        }
                        
                        createGroupOutput.groupState[.groupInfo]?.conf.map {
                            groups_info_set_attach_delete_before($0, 123456)
                        }
                        
                        mockStorage.write { db in
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo],
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                                serverTimestampMs: 1234567891000
                            )
                        }
                        
                        numInteractions = mockStorage.read { db in
                            try Interaction.fetchCount(db)
                        }
                        expect(numInteractions).to(equal(0))
                    }
                    
                    // MARK: ------ schedules a garbage collection job to clean up the attachments
                    it("schedules a garbage collection job to clean up the attachments") {
                        mockStorage.write { db in
                            try SessionThread.upsert(
                                db,
                                id: createGroupOutput.group.threadId,
                                variant: .contact,
                                values: SessionThread.TargetValues(
                                    creationDateTimestamp: .setTo(1234567890),
                                    shouldBeVisible: .setTo(true)
                                ),
                                calledFromConfig: nil,
                                using: dependencies
                            )
                            let interaction: Interaction = try Interaction(
                                serverHash: "1234",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4321",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 100000000,
                                receivedAtTimestampMs: 1234567890,
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
                                transientDependencies: nil
                            ).inserted(db)
                            _ = try Attachment(
                                id: "AttachmentId",
                                variant: .standard,
                                contentType: "Test",
                                byteCount: 1234
                            ).inserted(db)
                            _ = try InteractionAttachment(
                                albumIndex: 1,
                                interactionId: interaction.id!,
                                attachmentId: "AttachmentId"
                            ).inserted(db)
                        }
                        
                        createGroupOutput.groupState[.groupInfo]?.conf.map {
                            groups_info_set_attach_delete_before($0, 123456)
                        }
                        
                        mockStorage.write { db in
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo],
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                                serverTimestampMs: 1234567891000
                            )
                        }
                        
                        expect(mockJobRunner)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { jobRunner in
                                jobRunner.add(
                                    .any,
                                    job: Job(
                                        variant: .garbageCollection,
                                        behaviour: .runOnce,
                                        shouldBlock: false,
                                        shouldBeUnique: false,
                                        shouldSkipLaunchBecomeActive: false,
                                        details: GarbageCollectionJob.Details(
                                            typesToCollect: [.orphanedAttachments, .orphanedAttachmentFiles]
                                        )
                                    ),
                                    canStartJob: true
                                )
                            })
                    }
                    
                    // MARK: ------ does not delete messages with attachments after the timestamp
                    it("does not delete messages with attachments after the timestamp") {
                        mockStorage.write { db in
                            try SessionThread.upsert(
                                db,
                                id: createGroupOutput.group.threadId,
                                variant: .contact,
                                values: SessionThread.TargetValues(
                                    creationDateTimestamp: .setTo(1234567890),
                                    shouldBeVisible: .setTo(true)
                                ),
                                calledFromConfig: nil,
                                using: dependencies
                            )
                            let interaction1: Interaction = try Interaction(
                                serverHash: "1234",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4321",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 100000000,
                                receivedAtTimestampMs: 1234567890,
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
                                transientDependencies: nil
                            ).inserted(db)
                            let interaction2: Interaction = try Interaction(
                                serverHash: "1235",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4321",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 200000000,
                                receivedAtTimestampMs: 2234567890,
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
                                transientDependencies: nil
                            ).inserted(db)
                            _ = try Attachment(
                                id: "AttachmentId",
                                variant: .standard,
                                contentType: "Test",
                                byteCount: 1234
                            ).inserted(db)
                            _ = try Attachment(
                                id: "AttachmentId2",
                                variant: .standard,
                                contentType: "Test",
                                byteCount: 1234
                            ).inserted(db)
                            _ = try InteractionAttachment(
                                albumIndex: 1,
                                interactionId: interaction1.id!,
                                attachmentId: "AttachmentId"
                            ).inserted(db)
                            _ = try InteractionAttachment(
                                albumIndex: 1,
                                interactionId: interaction2.id!,
                                attachmentId: "AttachmentId2"
                            ).inserted(db)
                        }
                        
                        createGroupOutput.groupState[.groupInfo]?.conf.map {
                            groups_info_set_attach_delete_before($0, 123456)
                        }
                        
                        mockStorage.write { db in
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo],
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                                serverTimestampMs: 1234567891000
                            )
                        }
                        
                        numInteractions = mockStorage.read { db in
                            try Interaction.fetchCount(db)
                        }
                        expect(numInteractions).to(equal(1))
                    }
                    
                    // MARK: ------ does not delete messages before the timestamp that have no attachments
                    it("does not delete messages before the timestamp that have no attachments") {
                        mockStorage.write { db in
                            try SessionThread.upsert(
                                db,
                                id: createGroupOutput.group.threadId,
                                variant: .contact,
                                values: SessionThread.TargetValues(
                                    creationDateTimestamp: .setTo(1234567890),
                                    shouldBeVisible: .setTo(true)
                                ),
                                calledFromConfig: nil,
                                using: dependencies
                            )
                            let interaction1: Interaction = try Interaction(
                                serverHash: "1234",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4321",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 100000000,
                                receivedAtTimestampMs: 1234567890,
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
                                transientDependencies: nil
                            ).inserted(db)
                            _ = try Interaction(
                                serverHash: "1235",
                                messageUuid: nil,
                                threadId: createGroupOutput.group.threadId,
                                authorId: "4321",
                                variant: .standardIncoming,
                                body: nil,
                                timestampMs: 200000000,
                                receivedAtTimestampMs: 2234567890,
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
                                transientDependencies: nil
                            ).inserted(db)
                            _ = try Attachment(
                                id: "AttachmentId",
                                variant: .standard,
                                contentType: "Test",
                                byteCount: 1234
                            ).inserted(db)
                            _ = try InteractionAttachment(
                                albumIndex: 1,
                                interactionId: interaction1.id!,
                                attachmentId: "AttachmentId"
                            ).inserted(db)
                        }
                        
                        createGroupOutput.groupState[.groupInfo]?.conf.map {
                            groups_info_set_attach_delete_before($0, 123456)
                        }
                        
                        mockStorage.write { db in
                            try mockLibSessionCache.handleGroupInfoUpdate(
                                db,
                                in: createGroupOutput.groupState[.groupInfo],
                                groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                                serverTimestampMs: 1234567891000
                            )
                        }
                        
                        numInteractions = mockStorage.read { db in
                            try Interaction.fetchCount(db)
                        }
                        expect(numInteractions).to(equal(1))
                    }
                }
                
                // MARK: ---- deletes from the server after deleting messages before a given timestamp
                it("deletes from the server after deleting messages before a given timestamp") {
                    mockStorage.write { db in
                        try SessionThread.upsert(
                            db,
                            id: createGroupOutput.group.threadId,
                            variant: .contact,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(1234567890),
                                shouldBeVisible: .setTo(true)
                            ),
                            calledFromConfig: nil,
                            using: dependencies
                        )
                        _ = try Interaction(
                            serverHash: "1234",
                            messageUuid: nil,
                            threadId: createGroupOutput.group.threadId,
                            authorId: "4321",
                            variant: .standardIncoming,
                            body: nil,
                            timestampMs: 100000000,
                            receivedAtTimestampMs: 1234567890,
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
                            transientDependencies: nil
                        ).inserted(db)
                    }
                    
                    createGroupOutput.groupState[.groupInfo]?.conf.map { groups_info_set_delete_before($0, 123456) }
                    
                    mockStorage.write { db in
                        try mockLibSessionCache.handleGroupInfoUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupInfo],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                            serverTimestampMs: 1234567891000
                        )
                    }
                    
                    let expectedRequest: Network.PreparedRequest<[String: Bool]> = try SnodeAPI.preparedDeleteMessages(
                        serverHashes: ["1234"],
                        requireSuccessfulDeletion: false,
                        authMethod: Authentication.groupAdmin(
                            groupSessionId: createGroupOutput.groupSessionId,
                            ed25519SecretKey: createGroupOutput.identityKeyPair.secretKey
                        ),
                        using: dependencies
                    )
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
                
                // MARK: ---- does not delete from the server if there is no server hash
                it("does not delete from the server if there is no server hash") {
                    mockStorage.write { db in
                        try SessionThread.upsert(
                            db,
                            id: createGroupOutput.group.threadId,
                            variant: .contact,
                            values: SessionThread.TargetValues(
                                creationDateTimestamp: .setTo(1234567890),
                                shouldBeVisible: .setTo(true)
                            ),
                            calledFromConfig: nil,
                            using: dependencies
                        )
                        _ = try Interaction(
                            serverHash: nil,
                            messageUuid: nil,
                            threadId: createGroupOutput.group.threadId,
                            authorId: "4321",
                            variant: .standardIncoming,
                            body: nil,
                            timestampMs: 100000000,
                            receivedAtTimestampMs: 1234567890,
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
                            transientDependencies: nil
                        ).inserted(db)
                    }
                    
                    createGroupOutput.groupState[.groupInfo]?.conf.map { groups_info_set_delete_before($0, 123456) }
                    
                    mockStorage.write { db in
                        try mockLibSessionCache.handleGroupInfoUpdate(
                            db,
                            in: createGroupOutput.groupState[.groupInfo],
                            groupSessionId: SessionId(.group, hex: createGroupOutput.group.threadId),
                            serverTimestampMs: 1234567891000
                        )
                    }
                    
                    let numInteractions: Int? = mockStorage.read { db in
                        try Interaction.fetchCount(db)
                    }
                    expect(numInteractions).to(equal(0))
                    expect(mockNetwork)
                        .toNot(call { network in
                            network.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any)
                        })
                }
            }
        }
    }
}

// MARK: - Convenience

private extension LibSession.Config {
    var conf: UnsafeMutablePointer<config_object>? {
        switch self {
            case .userProfile(let conf), .contacts(let conf),
                .convoInfoVolatile(let conf), .userGroups(let conf),
                .groupInfo(let conf), .groupMembers(let conf):
                return conf
            default: return nil
        }
    }
}
