// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit

@testable import SessionUIKit
@testable import SessionMessagingKit
@testable import Session

class ThreadSettingsViewModelSpec: QuickSpec {
    private typealias Item = SessionCell.Info<ThreadSettingsViewModel.TableItem>
    
    override class func spec() {
        // MARK: Configuration
        
        @TestState var userPubkey: String! = "05\(TestConstants.publicKey)"
        @TestState var user2Pubkey: String! = "05\(TestConstants.publicKey.replacingOccurrences(of: "8", with: "7"))"
        @TestState var legacyGroupPubkey: String! = "05\(TestConstants.publicKey.replacingOccurrences(of: "8", with: "6"))"
        @TestState var groupPubkey: String! = "03\(TestConstants.publicKey.replacingOccurrences(of: "8", with: "5"))"
        @TestState var communityId: String! = "testserver.testRoom"
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies[singleton: .scheduler] = .immediate
        }
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrationTargets: [
                SNUtilitiesKit.self,
                SNSnodeKit.self,
                SNMessagingKit.self,
                DeprecatedUIKitMigrationTarget.self
            ],
            using: dependencies,
            initialData: { db in
                try Identity(
                    variant: .x25519PublicKey,
                    data: Data(hex: TestConstants.publicKey)
                ).insert(db)
                try Profile(id: userPubkey, name: "TestMe").insert(db)
                try Profile(id: user2Pubkey, name: "TestUser").insert(db)
            }
        )
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
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
        @TestState(cache: .libSession, in: dependencies) var mockLibSessionCache: MockLibSessionCache! = MockLibSessionCache(
            initialSetup: { cache in
                cache
                    .when { try $0.performAndPushChange(.any, for: .any, sessionId: .any, change: { _ in }) }
                    .thenReturn(())
                cache
                    .when { $0.pinnedPriority(.any, threadId: .any, threadVariant: .any) }
                    .thenReturn(LibSession.defaultNewThreadPriority)
                cache.when { $0.disappearingMessagesConfig(threadId: .any, threadVariant: .any) }
                    .thenReturn(nil)
                cache
                    .when { $0.isAdmin(groupSessionId: .any) }
                    .thenReturn(false)
            }
        )
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto
                    .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                    .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
            }
        )
        @TestState var timestampMs: Int64! = 1234567890000
        @TestState(cache: .snodeAPI, in: dependencies) var mockSnodeAPICache: MockSnodeAPICache! = MockSnodeAPICache(
            initialSetup: { cache in
                cache.when { $0.clockOffsetMs }.thenReturn(0)
                cache
                    .when { $0.currentOffsetTimestampMs() }
                    .thenReturn { _, _ in
                        /// **Note:** We need to increment this value every time it's accessed because otherwise any functions which
                        /// insert multiple `Interaction` values can end up running into unique constraint conflicts due to the timestamp
                        /// being identical between different interactions
                        timestampMs += 1
                        return timestampMs
                    }
            }
        )
        @TestState var threadVariant: SessionThread.Variant! = .contact
        @TestState var didTriggerSearchCallbackTriggered: Bool! = false
        @TestState var viewModel: ThreadSettingsViewModel!
        @TestState var disposables: [AnyCancellable]! = []
        @TestState var screenTransitions: [(destination: UIViewController, transition: TransitionType)]! = []
        
        func item(section: ThreadSettingsViewModel.Section, id: ThreadSettingsViewModel.TableItem) -> Item? {
            return viewModel.tableData
                .first(where: { (sectionModel: ThreadSettingsViewModel.SectionModel) -> Bool in
                    sectionModel.model == section
                })?
                .elements
                .first(where: { (item: SessionCell.Info<ThreadSettingsViewModel.TableItem>) -> Bool in
                    item.id == id
                })
        }
        func setupTestSubscriptions() {
            viewModel.tableDataPublisher
                .receive(on: ImmediateScheduler.shared)
                .sink(
                    receiveCompletion: { _ in },
                    receiveValue: { viewModel.updateTableData($0) }
                )
                .store(in: &disposables)
            viewModel.navigatableState.transitionToScreen
                .receive(on: ImmediateScheduler.shared)
                .sink(
                    receiveCompletion: { _ in },
                    receiveValue: { screenTransitions.append($0) }
                )
                .store(in: &disposables)
        }
        
        // MARK: - a ThreadSettingsViewModel
        describe("a ThreadSettingsViewModel") {
            beforeEach {
                mockStorage.write { db in
                    try SessionThread(
                        id: user2Pubkey,
                        variant: .contact,
                        creationDateTimestamp: 0,
                        using: dependencies
                    ).insert(db)
                }
                
                viewModel = ThreadSettingsViewModel(
                    threadId: user2Pubkey,
                    threadVariant: .contact,
                    didTriggerSearch: {
                        didTriggerSearchCallbackTriggered = true
                    },
                    using: dependencies
                )
                setupTestSubscriptions()
            }
            
            // MARK: -- with any conversation type
            context("with any conversation type") {
                // MARK: ---- triggers the search callback when tapping search
                it("triggers the search callback when tapping search") {
                    item(section: .content, id: .searchConversation)?.onTap?()
                    
                    expect(didTriggerSearchCallbackTriggered).to(beTrue())
                }
                
                // MARK: ---- mutes a conversation
                it("mutes a conversation") {
                    item(section: .content, id: .notificationMute)?.onTap?()
                    
                    expect(
                        mockStorage
                            .read { db in try SessionThread.fetchOne(db, id: user2Pubkey) }?
                            .mutedUntilTimestamp
                    )
                    .toNot(beNil())
                }
                
                // MARK: ---- unmutes a conversation
                it("unmutes a conversation") {
                    mockStorage.write { db in
                        try SessionThread
                            .updateAll(
                                db,
                                SessionThread.Columns.mutedUntilTimestamp.set(to: 1234567890)
                            )
                    }
                    
                    expect(
                        mockStorage
                            .read { db in try SessionThread.fetchOne(db, id: user2Pubkey) }?
                            .mutedUntilTimestamp
                    )
                    .toNot(beNil())
                    
                    item(section: .content, id: .notificationMute)?.onTap?()
                
                    expect(
                        mockStorage
                            .read { db in try SessionThread.fetchOne(db, id: user2Pubkey) }?
                            .mutedUntilTimestamp
                    )
                    .to(beNil())
                }
            }
            
            // MARK: -- with a note-to-self conversation
            context("with a note-to-self conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread(
                            id: userPubkey,
                            variant: .contact,
                            creationDateTimestamp: 0,
                            using: dependencies
                        ).insert(db)
                    }
                    
                    viewModel = ThreadSettingsViewModel(
                        threadId: userPubkey,
                        threadVariant: .contact,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    setupTestSubscriptions()
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    expect(viewModel.title).to(equal("sessionSettings".localized()))
                }
                
                // MARK: ---- has the correct display name
                it("has the correct display name") {
                    let item: Item? = item(section: .conversationInfo, id: .displayName)
                    expect(item?.title?.text).to(equal("noteToSelf".localized()))
                }
                
                // MARK: ---- has no edit icon
                it("has no edit icon") {
                    let item: Item? = item(section: .conversationInfo, id: .displayName)
                    expect(item?.leadingAccessory).to(beNil())
                }
                
                // MARK: ---- does nothing when tapped
                it("does nothing when tapped") {
                    item(section: .conversationInfo, id: .displayName)?.onTap?()
                    expect(screenTransitions).to(beEmpty())
                }
                
                // MARK: ---- has no mute button
                it("has no mute button") {
                    expect(item(section: .content, id: .notificationMute)).to(beNil())
                }
            }
            
            // MARK: -- with a one-to-one conversation
            context("with a one-to-one conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread(
                            id: user2Pubkey,
                            variant: .contact,
                            creationDateTimestamp: 0,
                            using: dependencies
                        ).insert(db)
                    }
                    
                    viewModel = ThreadSettingsViewModel(
                        threadId: user2Pubkey,
                        threadVariant: .contact,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    setupTestSubscriptions()
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    expect(viewModel.title).to(equal("sessionSettings".localized()))
                }
                
                // MARK: ---- has the correct display name
                it("has the correct display name") {
                    let item: Item? = item(section: .conversationInfo, id: .displayName)
                    expect(item?.title?.text).to(equal("TestUser"))
                }
                
                // MARK: ---- has an edit icon
                it("has an edit icon") {
                    let item: Item? = item(section: .conversationInfo, id: .displayName)
                    expect(item?.leadingAccessory).toNot(beNil())
                }
                
                // MARK: ---- presents a confirmation modal when tapped
                it("presents a confirmation modal when tapped") {
                    item(section: .conversationInfo, id: .displayName)?.onTap?()
                    expect(screenTransitions.first?.destination).to(beAKindOf(ConfirmationModal.self))
                    expect(screenTransitions.first?.transition).to(equal(TransitionType.present))
                }
                
                // MARK: ---- when updating the nickname
                context("when updating the nickname") {
                    @TestState var onChange: ((String) -> ())?
                    @TestState var modal: ConfirmationModal?
                    
                    beforeEach {
                        item(section: .conversationInfo, id: .displayName)?.onTap?()
                        modal = (screenTransitions.first?.destination as? ConfirmationModal)
                        switch modal?.info.body {
                            case .input(_, _, let onChange_): onChange = onChange_
                            default: break
                        }
                    }
                    
                    // MARK: ---- has the correct content
                    it("has the correct content") {
                        expect(modal?.info.title).to(equal("nicknameSet".localized()))
                        expect(modal?.info.body).to(equal(
                            .input(
                                explanation: "nicknameDescription"
                                    .put(key: "name", value: "TestUser")
                                    .localizedFormatted(baseFont: ConfirmationModal.explanationFont),
                                info: ConfirmationModal.Info.Body.InputInfo(
                                    placeholder: "nicknameEnter".localized(),
                                    initialValue: nil,
                                    accessibility: Accessibility(identifier: "Username")
                                ),
                                onChange: { _ in }
                            )
                        ))
                        expect(modal?.info.confirmTitle).to(equal("save".localized()))
                        expect(modal?.info.cancelTitle).to(equal("remove".localized()))
                    }
                    
                    // MARK: ---- does nothing if the name contains only white space
                    it("does nothing if the name contains only white space") {
                        onChange?("   ")
                        modal?.confirmationPressed()
                        
                        expect(screenTransitions.count).to(equal(1))
                    }
                    
                    // MARK: ---- shows an error modal when the updated nickname is too long
                    it("shows an error modal when the updated nickname is too long") {
                        onChange?([String](Array(repeating: "1", count: 101)).joined())
                        modal?.confirmationPressed()
                        
                        expect(screenTransitions.count).to(equal(2))
                        expect(screenTransitions.last?.destination).to(beAKindOf(ConfirmationModal.self))
                        expect(screenTransitions.last?.transition).to(equal(TransitionType.present))
                        
                        let modal2: ConfirmationModal? = (screenTransitions.last?.destination as? ConfirmationModal)
                        expect(modal2?.info.title).to(equal("theError".localized()))
                        expect(modal2?.info.body).to(equal(.text("nicknameErrorShorter".localized())))
                        expect(modal2?.info.confirmTitle).to(beNil())
                        expect(modal2?.info.cancelTitle).to(equal("okay".localized()))
                    }
                    
                    // MARK: ---- updates the contacts nickname when valid
                    it("updates the contacts nickname when valid") {
                        onChange?("TestNickname")
                        modal?.confirmationPressed()
                        
                        let profiles: [Profile]? = mockStorage.read { db in try Profile.fetchAll(db) }
                        expect(profiles?.map { $0.nickname }.asSet()).to(equal([nil, "TestNickname"]))
                    }
                    
                    // MARK: ---- removes the nickname when cancel is pressed
                    it("removes the nickname when cancel is pressed") {
                        mockStorage.write { db in
                            try Profile
                                .filter(id: "TestId")
                                .updateAll(db, Profile.Columns.nickname.set(to: "TestOldNickname"))
                        }
                        modal?.cancel()
                        
                        let profiles: [Profile]? = mockStorage.read { db in try Profile.fetchAll(db) }
                        expect(profiles?.map { $0.nickname }.asSet()).to(equal([nil, nil]))
                    }
                }
            }
            
            // MARK: -- with a legacy group conversation
            context("with a legacy group conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread(
                            id: legacyGroupPubkey,
                            variant: .legacyGroup,
                            creationDateTimestamp: 0,
                            using: dependencies
                        ).insert(db)
                        
                        try DisappearingMessagesConfiguration
                            .defaultWith(legacyGroupPubkey)
                            .insert(db)
                        
                        try ClosedGroup(
                            threadId: legacyGroupPubkey,
                            name: "TestGroup",
                            groupDescription: nil,
                            formationTimestamp: 1234567890,
                            displayPictureUrl: nil,
                            displayPictureFilename: nil,
                            displayPictureEncryptionKey: nil,
                            lastDisplayPictureUpdate: nil,
                            shouldPoll: false,
                            groupIdentityPrivateKey: nil,
                            authData: nil,
                            invited: nil
                        ).insert(db)
                        
                        try ClosedGroupKeyPair(
                            threadId: legacyGroupPubkey,
                            publicKey: Data([1, 2, 3]),
                            secretKey: Data([3, 2, 1]),
                            receivedTimestamp: 1234567890
                        ).insert(db)
                        
                        try GroupMember(
                            groupId: legacyGroupPubkey,
                            profileId: userPubkey,
                            role: .standard,
                            roleStatus: .accepted,
                            isHidden: false
                        ).insert(db)
                    }
                    
                    viewModel = ThreadSettingsViewModel(
                        threadId: legacyGroupPubkey,
                        threadVariant: .legacyGroup,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    setupTestSubscriptions()
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    expect(viewModel.title).to(equal("deleteAfterGroupPR1GroupSettings".localized()))
                }
                
                // MARK: ---- has the correct display name
                it("has the correct display name") {
                    let item: Item? = item(section: .conversationInfo, id: .displayName)
                    expect(item?.title?.text).to(equal("TestGroup"))
                }
                
                // MARK: ---- when the user is a standard member
                context("when the user is a standard member") {
                    // MARK: ---- has no edit icon
                    it("has no edit icon") {
                        let item: Item? = item(section: .conversationInfo, id: .displayName)
                        expect(item?.leadingAccessory).to(beNil())
                    }
                    
                    // MARK: ---- does nothing when tapped
                    it("does nothing when tapped") {
                        item(section: .conversationInfo, id: .displayName)?.onTap?()
                        expect(screenTransitions).to(beEmpty())
                    }
                }
                
                // MARK: ---- when the user is an admin
                context("when the user is an admin") {
                    beforeEach {
                        mockStorage.write { db in
                            try GroupMember.deleteAll(db)
                            
                            try GroupMember(
                                groupId: legacyGroupPubkey,
                                profileId: userPubkey,
                                role: .admin,
                                roleStatus: .accepted,
                                isHidden: false
                            ).insert(db)
                        }
                        
                        viewModel = ThreadSettingsViewModel(
                            threadId: legacyGroupPubkey,
                            threadVariant: .legacyGroup,
                            didTriggerSearch: {
                                didTriggerSearchCallbackTriggered = true
                            },
                            using: dependencies
                        )
                        setupTestSubscriptions()
                    }
                    
                    // MARK: ---- has an edit icon
                    it("has an edit icon") {
                        let item: Item? = item(section: .conversationInfo, id: .displayName)
                        expect(item?.leadingAccessory).toNot(beNil())
                    }
                    
                    // MARK: ---- presents a confirmation modal when tapped
                    it("presents a confirmation modal when tapped") {
                        item(section: .conversationInfo, id: .displayName)?.onTap?()
                        expect(screenTransitions.first?.destination).to(beAKindOf(ConfirmationModal.self))
                        expect(screenTransitions.first?.transition).to(equal(TransitionType.present))
                    }
                    
                    // MARK: ---- when updating the group name
                    context("when updating the group name") {
                        @TestState var onChange: ((String) -> ())?
                        @TestState var modal: ConfirmationModal?
                        
                        beforeEach {
                            item(section: .conversationInfo, id: .displayName)?.onTap?()
                            modal = (screenTransitions.first?.destination as? ConfirmationModal)
                            switch modal?.info.body {
                                case .input(_, _, let onChange_): onChange = onChange_
                                default: break
                            }
                        }
                        
                        // MARK: ---- has the correct content
                        it("has the correct content") {
                            expect(modal?.info.title).to(equal("groupInformationSet".localized()))
                            expect(modal?.info.body).to(equal(
                                .input(
                                    explanation: NSAttributedString(string: "groupNameVisible".localized()),
                                    info: ConfirmationModal.Info.Body.InputInfo(
                                        placeholder: "groupNameEnter".localized(),
                                        initialValue: "TestGroup",
                                        accessibility: Accessibility(identifier: "Group name text field")
                                    ),
                                    onChange: { _ in }
                                )
                            ))
                            
                            expect(modal?.info.confirmTitle).to(equal("save".localized()))
                            expect(modal?.info.cancelTitle).to(equal("cancel".localized()))
                        }
                        
                        // MARK: ---- does nothing if the name contains only white space
                        it("does nothing if the name contains only white space") {
                            onChange?("   ")
                            modal?.confirmationPressed()
                            
                            expect(screenTransitions.count).to(equal(1))
                        }
                        
                        // MARK: ---- shows an error modal when the updated name is too long
                        it("shows an error modal when the updated name is too long") {
                            onChange?([String](Array(repeating: "1", count: 101)).joined())
                            modal?.confirmationPressed()
                            
                            expect(screenTransitions.count).to(equal(2))
                            expect(screenTransitions.last?.destination).to(beAKindOf(ConfirmationModal.self))
                            expect(screenTransitions.last?.transition).to(equal(TransitionType.present))
                            
                            let modal2: ConfirmationModal? = (screenTransitions.last?.destination as? ConfirmationModal)
                            expect(modal2?.info.title).to(equal("theError".localized()))
                            expect(modal2?.info.body).to(equal(.text("groupNameEnterShorter".localized())))
                            expect(modal2?.info.confirmTitle).to(beNil())
                            expect(modal2?.info.cancelTitle).to(equal("okay".localized()))
                        }
                        
                        // MARK: ---- updates the group name when valid
                        it("updates the group name when valid") {
                            onChange?("TestNewGroupName")
                            modal?.confirmationPressed()
                            
                            let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                            expect(groups?.map { $0.name }.asSet()).to(equal(["TestNewGroupName"]))
                        }
                        
                        // MARK: ---- inserts a control message
                        it("inserts a control message") {
                            onChange?("TestNewGroupName")
                            modal?.confirmationPressed()
                            
                            let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                            expect(interactions?.first?.variant).to(equal(.infoLegacyGroupUpdated))
                            expect(interactions?.first?.body)
                                .to(equal(
                                    "groupNameNew"
                                        .put(key: "group_name", value: "TestNewGroupName")
                                        .localized()
                                ))
                        }
                        
                        // MARK: ---- schedules a control message to be sent
                        it("schedules a control message to be sent") {
                            onChange?("TestNewGroupName")
                            modal?.confirmationPressed()
                            
                            expect(mockJobRunner)
                                .to(call(matchingParameters: .all) {
                                    $0.add(
                                        .any,
                                        job: Job(
                                            variant: .messageSend,
                                            threadId: legacyGroupPubkey,
                                            interactionId: 1,
                                            details: MessageSendJob.Details(
                                                destination: .closedGroup(groupPublicKey: legacyGroupPubkey),
                                                message: ClosedGroupControlMessage(
                                                    kind: .nameChange(name: "TestNewGroupName")
                                                )
                                            )
                                        ),
                                        dependantJob: nil,
                                        canStartJob: true
                                    )
                                })
                        }
                        
                        // MARK: ---- triggers a libSession change
                        it("triggers a libSession change") {
                            onChange?("TestNewGroupName")
                            modal?.confirmationPressed()
                            
                            expect(mockLibSessionCache)
                                .to(call(matchingParameters: .all) {
                                    try $0.performAndPushChange(
                                        .any,
                                        for: .userGroups,
                                        sessionId: SessionId(.standard, hex: userPubkey),
                                        change: { _ in }
                                    )
                                })
                        }
                    }
                }
            }
            
            // MARK: -- with a group conversation
            context("with a group conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread(
                            id: groupPubkey,
                            variant: .group,
                            creationDateTimestamp: 0,
                            using: dependencies
                        ).insert(db)
                        
                        try ClosedGroup(
                            threadId: groupPubkey,
                            name: "TestGroup",
                            groupDescription: nil,
                            formationTimestamp: 1234567890,
                            displayPictureUrl: nil,
                            displayPictureFilename: nil,
                            displayPictureEncryptionKey: nil,
                            lastDisplayPictureUpdate: nil,
                            shouldPoll: false,
                            groupIdentityPrivateKey: nil,
                            authData: nil,
                            invited: nil
                        ).insert(db)
                        
                        try GroupMember(
                            groupId: groupPubkey,
                            profileId: userPubkey,
                            role: .standard,
                            roleStatus: .accepted,
                            isHidden: false
                        ).insert(db)
                    }
                    
                    viewModel = ThreadSettingsViewModel(
                        threadId: groupPubkey,
                        threadVariant: .group,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    setupTestSubscriptions()
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    expect(viewModel.title).to(equal("deleteAfterGroupPR1GroupSettings".localized()))
                }
                
                // MARK: ---- has the correct display name
                it("has the correct display name") {
                    let item: Item? = item(section: .conversationInfo, id: .displayName)
                    expect(item?.title?.text).to(equal("TestGroup"))
                }
                
                // MARK: ---- when the user is a standard member
                context("when the user is a standard member") {
                    // MARK: ---- has no edit icon
                    it("has no edit icon") {
                        let item: Item? = item(section: .conversationInfo, id: .displayName)
                        expect(item?.leadingAccessory).to(beNil())
                    }
                    
                    // MARK: ---- does nothing when tapped
                    it("does nothing when tapped") {
                        item(section: .conversationInfo, id: .displayName)?.onTap?()
                        expect(screenTransitions).to(beEmpty())
                    }
                }
                
                // MARK: ---- when the user is an admin
                context("when the user is an admin") {
                    beforeEach {
                        mockStorage.write { db in
                            try GroupMember.deleteAll(db)
                            
                            try ClosedGroup
                                .updateAll(
                                    db,
                                    ClosedGroup.Columns.groupIdentityPrivateKey.set(to: Data([1, 2, 3]))
                                )
                            try GroupMember(
                                groupId: groupPubkey,
                                profileId: userPubkey,
                                role: .admin,
                                roleStatus: .accepted,
                                isHidden: false
                            ).insert(db)
                        }
                        
                        viewModel = ThreadSettingsViewModel(
                            threadId: groupPubkey,
                            threadVariant: .group,
                            didTriggerSearch: {
                                didTriggerSearchCallbackTriggered = true
                            },
                            using: dependencies
                        )
                        setupTestSubscriptions()
                    }
                    
                    // MARK: ---- has an edit icon
                    it("has an edit icon") {
                        let item: Item? = item(section: .conversationInfo, id: .displayName)
                        expect(item?.leadingAccessory).toNot(beNil())
                    }
                    
                    // MARK: ---- presents a confirmation modal when tapped
                    it("presents a confirmation modal when tapped") {
                        item(section: .conversationInfo, id: .displayName)?.onTap?()
                        expect(screenTransitions.first?.destination).to(beAKindOf(ConfirmationModal.self))
                        expect(screenTransitions.first?.transition).to(equal(TransitionType.present))
                    }
                    
                    // MARK: ---- when updating the group info
                    context("when updating the group info") {
                        @TestState var onChange: ((String) -> ())?
                        @TestState var onChange2: ((String, String) -> ())?
                        @TestState var modal: ConfirmationModal?
                        
                        // MARK: ------ and editing the group description is enabled
                        context("and editing the group description is enabled") {
                            beforeEach {
                                dependencies[feature: .updatedGroupsAllowDescriptionEditing] = true
                                viewModel = ThreadSettingsViewModel(
                                    threadId: groupPubkey,
                                    threadVariant: .group,
                                    didTriggerSearch: {
                                        didTriggerSearchCallbackTriggered = true
                                    },
                                    using: dependencies
                                )
                                setupTestSubscriptions()
                                
                                item(section: .conversationInfo, id: .displayName)?.onTap?()
                                modal = (screenTransitions.first?.destination as? ConfirmationModal)
                                switch modal?.info.body {
                                    case .input(_, _, let onChange_): onChange = onChange_
                                    case .dualInput(_, _, _, let onChange2_): onChange2 = onChange2_
                                    default: break
                                }
                            }
                            
                            // MARK: ---- has the correct content
                            it("has the correct content") {
                                expect(modal?.info.title).to(equal("groupInformationSet".localized()))
                                expect(modal?.info.body).to(equal(
                                    .dualInput(
                                        explanation: NSAttributedString(string: "Group name and description are visible to all group members."),
                                        firstInfo: ConfirmationModal.Info.Body.InputInfo(
                                            placeholder: "groupNameEnter".localized(),
                                            initialValue: "TestGroup",
                                            accessibility: Accessibility(identifier: "Group name text field")
                                        ),
                                        secondInfo: ConfirmationModal.Info.Body.InputInfo(
                                            placeholder: "groupDescriptionEnter".localized(),
                                            initialValue: nil,
                                            accessibility: Accessibility(identifier: "Group description text field")
                                        ),
                                        onChange: { _, _ in }
                                    )
                                ))
                                expect(modal?.info.confirmTitle).to(equal("save".localized()))
                                expect(modal?.info.cancelTitle).to(equal("cancel".localized()))
                            }
                            
                            // MARK: ---- does nothing if the name contains only white space
                            it("does nothing if the name contains only white space") {
                                onChange2?("   ", "Test")
                                modal?.confirmationPressed()
                                
                                expect(screenTransitions.count).to(equal(1))
                            }
                            
                            // MARK: ---- shows an error modal when the updated name is too long
                            it("shows an error modal when the updated name is too long") {
                                onChange2?([String](Array(repeating: "1", count: 101)).joined(), "Test")
                                modal?.confirmationPressed()
                                
                                expect(screenTransitions.count).to(equal(2))
                                expect(screenTransitions.last?.destination).to(beAKindOf(ConfirmationModal.self))
                                expect(screenTransitions.last?.transition).to(equal(TransitionType.present))
                                
                                let modal2: ConfirmationModal? = (screenTransitions.last?.destination as? ConfirmationModal)
                                expect(modal2?.info.title).to(equal("theError".localized()))
                                expect(modal2?.info.body).to(equal(.text("groupNameEnterShorter".localized())))
                                expect(modal2?.info.confirmTitle).to(beNil())
                                expect(modal2?.info.cancelTitle).to(equal("okay".localized()))
                            }
                            
                            // MARK: ---- shows an error modal when the updated description is too long
                            it("shows an error modal when the updated description is too long") {
                                onChange2?("Test", [String](Array(repeating: "1", count: 2001)).joined())
                                modal?.confirmationPressed()
                                
                                expect(screenTransitions.count).to(equal(2))
                                expect(screenTransitions.last?.destination).to(beAKindOf(ConfirmationModal.self))
                                expect(screenTransitions.last?.transition).to(equal(TransitionType.present))
                                
                                let modal2: ConfirmationModal? = (screenTransitions.last?.destination as? ConfirmationModal)
                                expect(modal2?.info.title).to(equal("theError".localized()))
                                expect(modal2?.info.body).to(equal(.text("Please enter a shorter group description.")))
                                expect(modal2?.info.confirmTitle).to(beNil())
                                expect(modal2?.info.cancelTitle).to(equal("okay".localized()))
                            }
                            
                            // MARK: ---- updates the group name when valid
                            it("updates the group name when valid") {
                                onChange2?("TestNewGroupName", "Test")
                                modal?.confirmationPressed()
                                
                                let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                                expect(groups?.map { $0.name }.asSet()).to(equal(["TestNewGroupName"]))
                            }
                            
                            // MARK: ---- updates the group description when valid
                            it("updates the group description when valid") {
                                onChange2?("Test", "TestNewGroupDescription")
                                modal?.confirmationPressed()
                                
                                let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                                expect(groups?.map { $0.groupDescription }.asSet()).to(equal(["TestNewGroupDescription"]))
                            }
                            
                            // MARK: ---- inserts a control message
                            it("inserts a control message") {
                                onChange2?("TestNewGroupName", "")
                                modal?.confirmationPressed()
                                
                                let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                                expect(interactions?.first?.variant).to(equal(.infoGroupInfoUpdated))
                                expect(interactions?.first?.body)
                                    .to(equal(
                                        ClosedGroup.MessageInfo
                                            .updatedName("TestNewGroupName")
                                            .infoString(using: dependencies)
                                    ))
                            }
                            
                            // MARK: ---- schedules a control message to be sent
                            it("schedules a control message to be sent") {
                                onChange2?("TestNewGroupName", "")
                                modal?.confirmationPressed()
                                
                                expect(mockJobRunner)
                                    .to(call(matchingParameters: .all) {
                                        $0.add(
                                            .any,
                                            job: Job(
                                                variant: .messageSend,
                                                threadId: groupPubkey,
                                                interactionId: nil,
                                                details: MessageSendJob.Details(
                                                    destination: .closedGroup(groupPublicKey: groupPubkey),
                                                    message: try GroupUpdateInfoChangeMessage(
                                                        changeType: .name,
                                                        updatedName: "TestNewGroupName",
                                                        sentTimestampMs: UInt64(1234567890002),
                                                        authMethod: Authentication.groupAdmin(
                                                            groupSessionId: SessionId(.group, hex: groupPubkey),
                                                            ed25519SecretKey: [1, 2, 3]
                                                        ),
                                                        using: dependencies
                                                    )
                                                )
                                            ),
                                            dependantJob: nil,
                                            canStartJob: true
                                        )
                                    })
                            }
                            
                            // MARK: ---- triggers a libSession change
                            it("triggers a libSession change") {
                                mockLibSessionCache
                                    .when { $0.isAdmin(groupSessionId: .any) }
                                    .thenReturn(true)
                                
                                onChange2?("Test", "TestNewGroupDescription")
                                modal?.confirmationPressed()
                                
                                expect(mockLibSessionCache)
                                    .to(call(matchingParameters: .all) {
                                        try $0.performAndPushChange(
                                            .any,
                                            for: .userGroups,
                                            sessionId: SessionId(.standard, hex: userPubkey),
                                            change: { _ in }
                                        )
                                    })
                                expect(mockLibSessionCache)
                                    .to(call(matchingParameters: .all) {
                                        try $0.performAndPushChange(
                                            .any,
                                            for: .groupInfo,
                                            sessionId: SessionId(.group, hex: groupPubkey),
                                            change: { _ in }
                                        )
                                    })
                            }
                        }
                        
                        // MARK: ------ and editing the group description is disabled
                        context("and editing the group description is disabled") {
                            beforeEach {
                                dependencies[feature: .updatedGroupsAllowDescriptionEditing] = false
                                viewModel = ThreadSettingsViewModel(
                                    threadId: groupPubkey,
                                    threadVariant: .group,
                                    didTriggerSearch: {
                                        didTriggerSearchCallbackTriggered = true
                                    },
                                    using: dependencies
                                )
                                setupTestSubscriptions()
                                
                                item(section: .conversationInfo, id: .displayName)?.onTap?()
                                modal = (screenTransitions.first?.destination as? ConfirmationModal)
                                switch modal?.info.body {
                                    case .input(_, _, let onChange_): onChange = onChange_
                                    default: break
                                }
                            }
                            
                            // MARK: ---- has the correct content
                            it("has the correct content") {
                                expect(modal?.info.title).to(equal("groupInformationSet".localized()))
                                expect(modal?.info.body).to(equal(
                                    .input(
                                        explanation: NSAttributedString(string: "groupNameVisible".localized()),
                                        info: ConfirmationModal.Info.Body.InputInfo(
                                            placeholder: "groupNameEnter".localized(),
                                            initialValue: "TestGroup",
                                            accessibility: Accessibility(identifier: "Group name text field")
                                        ),
                                        onChange: { _ in }
                                    )
                                ))
                                
                                expect(modal?.info.confirmTitle).to(equal("save".localized()))
                                expect(modal?.info.cancelTitle).to(equal("cancel".localized()))
                            }
                            
                            // MARK: ---- does nothing if the name contains only white space
                            it("does nothing if the name contains only white space") {
                                onChange?("   ")
                                modal?.confirmationPressed()
                                
                                expect(screenTransitions.count).to(equal(1))
                            }
                            
                            // MARK: ---- shows an error modal when the updated name is too long
                            it("shows an error modal when the updated name is too long") {
                                onChange?([String](Array(repeating: "1", count: 101)).joined())
                                modal?.confirmationPressed()
                                
                                expect(screenTransitions.count).to(equal(2))
                                expect(screenTransitions.last?.destination).to(beAKindOf(ConfirmationModal.self))
                                expect(screenTransitions.last?.transition).to(equal(TransitionType.present))
                                
                                let modal2: ConfirmationModal? = (screenTransitions.last?.destination as? ConfirmationModal)
                                expect(modal2?.info.title).to(equal("theError".localized()))
                                expect(modal2?.info.body).to(equal(.text("groupNameEnterShorter".localized())))
                                expect(modal2?.info.confirmTitle).to(beNil())
                                expect(modal2?.info.cancelTitle).to(equal("okay".localized()))
                            }
                            
                            // MARK: ---- updates the group name when valid
                            it("updates the group name when valid") {
                                onChange?("TestNewGroupName")
                                modal?.confirmationPressed()
                                
                                let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                                expect(groups?.map { $0.name }.asSet()).to(equal(["TestNewGroupName"]))
                            }
                            
                            // MARK: ---- inserts a control message
                            it("inserts a control message") {
                                onChange?("TestNewGroupName")
                                modal?.confirmationPressed()
                                
                                let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                                expect(interactions?.first?.variant).to(equal(.infoGroupInfoUpdated))
                                expect(interactions?.first?.body)
                                    .to(equal(
                                        ClosedGroup.MessageInfo
                                            .updatedName("TestNewGroupName")
                                            .infoString(using: dependencies)
                                    ))
                            }
                            
                            // MARK: ---- schedules a control message to be sent
                            it("schedules a control message to be sent") {
                                onChange?("TestNewGroupName")
                                modal?.confirmationPressed()
                                
                                expect(mockJobRunner)
                                    .to(call(matchingParameters: .all) {
                                        $0.add(
                                            .any,
                                            job: Job(
                                                variant: .messageSend,
                                                threadId: groupPubkey,
                                                interactionId: nil,
                                                details: MessageSendJob.Details(
                                                    destination: .closedGroup(groupPublicKey: groupPubkey),
                                                    message: try GroupUpdateInfoChangeMessage(
                                                        changeType: .name,
                                                        updatedName: "TestNewGroupName",
                                                        sentTimestampMs: UInt64(1234567890002),
                                                        authMethod: Authentication.groupAdmin(
                                                            groupSessionId: SessionId(.group, hex: groupPubkey),
                                                            ed25519SecretKey: [1, 2, 3]
                                                        ),
                                                        using: dependencies
                                                    )
                                                )
                                            ),
                                            dependantJob: nil,
                                            canStartJob: true
                                        )
                                    })
                            }
                            
                            // MARK: ---- triggers a libSession change
                            it("triggers a libSession change") {
                                mockLibSessionCache
                                    .when { $0.isAdmin(groupSessionId: .any) }
                                    .thenReturn(true)
                                
                                onChange?("TestNewGroupName")
                                modal?.confirmationPressed()
                                
                                expect(mockLibSessionCache)
                                    .to(call(matchingParameters: .all) {
                                        try $0.performAndPushChange(
                                            .any,
                                            for: .userGroups,
                                            sessionId: SessionId(.standard, hex: userPubkey),
                                            change: { _ in }
                                        )
                                    })
                                expect(mockLibSessionCache)
                                    .to(call(matchingParameters: .all) {
                                        try $0.performAndPushChange(
                                            .any,
                                            for: .groupInfo,
                                            sessionId: SessionId(.group, hex: groupPubkey),
                                            change: { _ in }
                                        )
                                    })
                            }
                        }
                    }
                }
            }
            
            // MARK: -- with a community conversation
            context("with a community conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.deleteAll(db)
                        
                        try SessionThread(
                            id: communityId,
                            variant: .community,
                            creationDateTimestamp: 0,
                            using: dependencies
                        ).insert(db)
                        
                        try OpenGroup(
                            server: "testServer",
                            roomToken: "testRoom",
                            publicKey: TestConstants.serverPublicKey,
                            isActive: false,
                            name: "TestCommunity",
                            userCount: 1,
                            infoUpdates: 1
                        ).insert(db)
                    }
                    
                    viewModel = ThreadSettingsViewModel(
                        threadId: communityId,
                        threadVariant: .community,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    setupTestSubscriptions()
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    expect(viewModel.title).to(equal("deleteAfterGroupPR1GroupSettings".localized()))
                }
                
                // MARK: ---- has the correct display name
                it("has the correct display name") {
                    let item: Item? = item(section: .conversationInfo, id: .displayName)
                    expect(item?.title?.text).to(equal("TestCommunity"))
                }
                
                // MARK: ---- has no edit icon
                it("has no edit icon") {
                    let item: Item? = item(section: .conversationInfo, id: .displayName)
                    expect(item?.leadingAccessory).to(beNil())
                }
                
                // MARK: ---- does nothing when tapped
                it("does nothing when tapped") {
                    item(section: .conversationInfo, id: .displayName)?.onTap?()
                    expect(screenTransitions).to(beEmpty())
                }
            }
        }
    }
}
