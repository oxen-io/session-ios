// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit
import SessionMessagingKit

@testable import Session

class ThreadSettingsViewModelSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies[singleton: .scheduler] = .immediate
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
                try Identity(
                    variant: .x25519PublicKey,
                    data: Data(hex: TestConstants.publicKey)
                ).insert(db)
                
                try SessionThread(id: "TestId",variant: .contact).insert(db)
                try Profile(id: "05\(TestConstants.publicKey)", name: "TestMe").insert(db)
                try Profile(id: "TestId", name: "TestUser").insert(db)
            }
        )
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
            }
        )
        @TestState var threadVariant: SessionThread.Variant! = .contact
        @TestState var didTriggerSearchCallbackTriggered: Bool! = false
        @TestState var viewModel: ThreadSettingsViewModel! = ThreadSettingsViewModel(
            threadId: "TestId",
            threadVariant: .contact,
            didTriggerSearch: {
                didTriggerSearchCallbackTriggered = true
            },
            using: dependencies
        )
        @TestState var disposables: [AnyCancellable]! = [
            viewModel.tableDataPublisher
                .receive(on: ImmediateScheduler.shared)
                .sink(
                    receiveCompletion: { _ in },
                    receiveValue: { viewModel.updateTableData($0.0) }
                )
        ]
        
        // MARK: - a ThreadSettingsViewModel
        describe("a ThreadSettingsViewModel") {
            // MARK: -- with any conversation type
            context("with any conversation type") {
                // MARK: ---- triggers the search callback when tapping search
                it("triggers the search callback when tapping search") {
                    viewModel.tableData
                        .first(where: { $0.model == .content })?
                        .elements
                        .first(where: { $0.id == .searchConversation })?
                        .onTap?()
                    
                    expect(didTriggerSearchCallbackTriggered).to(beTrue())
                }
                
                // MARK: ---- mutes a conversation
                it("mutes a conversation") {
                    viewModel.tableData
                        .first(where: { $0.model == .content })?
                        .elements
                        .first(where: { $0.id == .notificationMute })?
                        .onTap?()
                    
                    expect(
                        mockStorage
                            .read { db in try SessionThread.fetchOne(db, id: "TestId") }?
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
                            .read { db in try SessionThread.fetchOne(db, id: "TestId") }?
                            .mutedUntilTimestamp
                    )
                    .toNot(beNil())
                    
                    viewModel.tableData
                        .first(where: { $0.model == .content })?
                        .elements
                        .first(where: { $0.id == .notificationMute })?
                        .onTap?()
                
                    expect(
                        mockStorage
                            .read { db in try SessionThread.fetchOne(db, id: "TestId") }?
                            .mutedUntilTimestamp
                    )
                    .to(beNil())
                }
            }
            
            // MARK: -- with a note-to-self conversation
            context("with a note-to-self conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.deleteAll(db)
                        
                        try SessionThread(
                            id: "05\(TestConstants.publicKey)",
                            variant: .contact
                        ).insert(db)
                    }
                    
                    viewModel = ThreadSettingsViewModel(
                        threadId: "05\(TestConstants.publicKey)",
                        threadVariant: .contact,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    disposables.append(
                        viewModel.tableDataPublisher
                            .receive(on: ImmediateScheduler.shared)
                            .sink(
                                receiveCompletion: { _ in },
                                receiveValue: { viewModel.updateTableData($0.0) }
                            )
                    )
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    expect(viewModel.title).to(equal("vc_settings_title".localized()))
                }
                
                // MARK: ---- starts in the standard nav state
                it("starts in the standard nav state") {
                    expect(viewModel.navState.firstValue())
                        .to(equal(.standard))
                    
                    expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                    expect(viewModel.rightNavItems.firstValue())
                        .to(equal([
                            SessionNavItem<ThreadSettingsViewModel.NavItem>(
                                id: .edit,
                                systemItem: .edit,
                                accessibilityIdentifier: "Edit button"
                            )
                        ]))
                }
                
                // MARK: ---- has no mute button
                it("has no mute button") {
                    expect(
                        viewModel.tableData
                            .first(where: { $0.model == .content })?
                            .elements
                            .first(where: { $0.id == .notificationMute })
                    ).to(beNil())
                }
                
                // MARK: ---- when entering edit mode
                context("when entering edit mode") {
                    beforeEach {
                        viewModel.navState.sinkAndStore(in: &disposables)
                        viewModel.rightNavItems.firstValue()?.first?.action?()
                        viewModel.textChanged("TestNew", for: .nickname)
                    }
                    
                    // MARK: ------ enters the editing state
                    it("enters the editing state") {
                        expect(viewModel.navState.firstValue())
                            .to(equal(.editing))
                        
                        expect(viewModel.leftNavItems.firstValue())
                            .to(equal([
                                SessionNavItem<ThreadSettingsViewModel.NavItem>(
                                    id: .cancel,
                                    systemItem: .cancel,
                                    accessibilityIdentifier: "Cancel button"
                                )
                            ]))
                        expect(viewModel.rightNavItems.firstValue())
                            .to(equal([
                                SessionNavItem<ThreadSettingsViewModel.NavItem>(
                                    id: .done,
                                    systemItem: .done,
                                    accessibilityIdentifier: "Done"
                                )
                            ]))
                    }
                    
                    // MARK: ------ when cancelling edit mode
                    context("when cancelling edit mode") {
                        beforeEach {
                            viewModel.leftNavItems.firstValue()?.first?.action?()
                        }
                        
                        // MARK: -------- exits editing mode
                        it("exits editing mode") {
                            expect(viewModel.navState.firstValue())
                                .to(equal(.standard))
                            
                            expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                            expect(viewModel.rightNavItems.firstValue())
                                .to(equal([
                                    SessionNavItem<ThreadSettingsViewModel.NavItem>(
                                        id: .edit,
                                        systemItem: .edit,
                                        accessibilityIdentifier: "Edit button"
                                    )
                                ]))
                        }
                        
                        // MARK: -------- does not update the nickname for the current user
                        it("does not update the nickname for the current user") {
                            expect(
                                mockStorage
                                    .read { db in
                                        try Profile.fetchOne(db, id: "05\(TestConstants.publicKey)")
                                    }?
                                    .nickname
                            )
                            .to(beNil())
                        }
                    }
                    
                    // MARK: ------ when saving edit mode
                    context("when saving edit mode") {
                        beforeEach {
                            viewModel.rightNavItems.firstValue()?.first?.action?()
                        }
                        
                        // MARK: -------- exits editing mode
                        it("exits editing mode") {
                            expect(viewModel.navState.firstValue())
                                .to(equal(.standard))
                            
                            expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                            expect(viewModel.rightNavItems.firstValue())
                                .to(equal([
                                    SessionNavItem<ThreadSettingsViewModel.NavItem>(
                                        id: .edit,
                                        systemItem: .edit,
                                        accessibilityIdentifier: "Edit button"
                                    )
                                ]))
                        }
                        
                        // MARK: -------- updates the nickname for the current user
                        it("updates the nickname for the current user") {
                            expect(
                                mockStorage
                                    .read { db in
                                        try Profile.fetchOne(db, id: "05\(TestConstants.publicKey)")
                                    }?
                                    .nickname
                            )
                            .to(equal("TestNew"))
                        }
                    }
                }
            }
            
            // MARK: -- with a one-to-one conversation
            context("with a one-to-one conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.deleteAll(db)
                        
                        try SessionThread(
                            id: "TestId",
                            variant: .contact
                        ).insert(db)
                    }
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    expect(viewModel.title).to(equal("vc_settings_title".localized()))
                }
                
                // MARK: ---- starts in the standard nav state
                it("starts in the standard nav state") {
                    expect(viewModel.navState.firstValue())
                        .to(equal(.standard))
                    
                    expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                    expect(viewModel.rightNavItems.firstValue())
                        .to(equal([
                            SessionNavItem<ThreadSettingsViewModel.NavItem>(
                                id: .edit,
                                systemItem: .edit,
                                accessibilityIdentifier: "Edit button"
                            )
                        ]))
                }
                
                // MARK: ---- when entering edit mode
                context("when entering edit mode") {
                    beforeEach {
                        viewModel.navState.sinkAndStore(in: &disposables)
                        viewModel.rightNavItems.firstValue()?.first?.action?()
                        viewModel.textChanged("TestUserNew", for: .nickname)
                    }
                    
                    // MARK: ------ enters the editing state
                    it("enters the editing state") {
                        expect(viewModel.navState.firstValue())
                            .to(equal(.editing))
                        
                        expect(viewModel.leftNavItems.firstValue())
                            .to(equal([
                                SessionNavItem<ThreadSettingsViewModel.NavItem>(
                                    id: .cancel,
                                    systemItem: .cancel,
                                    accessibilityIdentifier: "Cancel button"
                                )
                            ]))
                        expect(viewModel.rightNavItems.firstValue())
                            .to(equal([
                                SessionNavItem<ThreadSettingsViewModel.NavItem>(
                                    id: .done,
                                    systemItem: .done,
                                    accessibilityIdentifier: "Done"
                                )
                            ]))
                    }
                    
                    // MARK: ------ when cancelling edit mode
                    context("when cancelling edit mode") {
                        beforeEach {
                            viewModel.leftNavItems.firstValue()?.first?.action?()
                        }
                        
                        // MARK: -------- exits editing mode
                        it("exits editing mode") {
                            expect(viewModel.navState.firstValue())
                                .to(equal(.standard))
                            
                            expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                            expect(viewModel.rightNavItems.firstValue())
                                .to(equal([
                                    SessionNavItem<ThreadSettingsViewModel.NavItem>(
                                        id: .edit,
                                        systemItem: .edit,
                                        accessibilityIdentifier: "Edit button"
                                    )
                                ]))
                        }
                        
                        // MARK: -------- does not update the nickname for the current user
                        it("does not update the nickname for the current user") {
                            expect(
                                mockStorage
                                    .read { db in try Profile.fetchOne(db, id: "TestId") }?
                                    .nickname
                            )
                            .to(beNil())
                        }
                    }
                    
                    // MARK: ------ when saving edit mode
                    context("when saving edit mode") {
                        beforeEach {
                            viewModel.rightNavItems.firstValue()?.first?.action?()
                        }
                        
                        // MARK: -------- exits editing mode
                        it("exits editing mode") {
                            expect(viewModel.navState.firstValue())
                                .to(equal(.standard))
                            
                            expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                            expect(viewModel.rightNavItems.firstValue())
                                .to(equal([
                                    SessionNavItem<ThreadSettingsViewModel.NavItem>(
                                        id: .edit,
                                        systemItem: .edit,
                                        accessibilityIdentifier: "Edit button"
                                    )
                                ]))
                        }
                        
                        // MARK: -------- updates the nickname for the current user
                        it("updates the nickname for the current user") {
                            expect(
                                mockStorage
                                    .read { db in try Profile.fetchOne(db, id: "TestId") }?
                                    .nickname
                            )
                            .to(equal("TestUserNew"))
                        }
                    }
                }
            }
            
            // MARK: -- with a group conversation
            context("with a group conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.deleteAll(db)
                        
                        try SessionThread(
                            id: "TestId",
                            variant: .legacyGroup
                        ).insert(db)
                    }
                    
                    viewModel = ThreadSettingsViewModel(
                        threadId: "TestId",
                        threadVariant: .legacyGroup,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    disposables.append(
                        viewModel.tableDataPublisher
                            .receive(on: ImmediateScheduler.shared)
                            .sink(
                                receiveCompletion: { _ in },
                                receiveValue: { viewModel.updateTableData($0.0) }
                            )
                    )
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    expect(viewModel.title).to(equal("vc_group_settings_title".localized()))
                }
                
                // MARK: ---- starts in the standard nav state
                it("starts in the standard nav state") {
                    expect(viewModel.navState.firstValue())
                        .to(equal(.standard))
                    
                    expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                    expect(viewModel.rightNavItems.firstValue()).to(equal([]))
                }
            }
            
            // MARK: -- with a community conversation
            context("with a community conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.deleteAll(db)
                        
                        try SessionThread(
                            id: "TestId",
                            variant: .community
                        ).insert(db)
                    }
                    
                    viewModel = ThreadSettingsViewModel(
                        threadId: "TestId",
                        threadVariant: .community,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        },
                        using: dependencies
                    )
                    disposables.append(
                        viewModel.tableDataPublisher
                            .receive(on: ImmediateScheduler.shared)
                            .sink(
                                receiveCompletion: { _ in },
                                receiveValue: { viewModel.updateTableData($0.0) }
                            )
                    )
                }
                
                // MARK: ---- has the correct title
                it("has the correct title") {
                    expect(viewModel.title).to(equal("vc_group_settings_title".localized()))
                }
                
                // MARK: ---- starts in the standard nav state
                it("starts in the standard nav state") {
                    expect(viewModel.navState.firstValue())
                        .to(equal(.standard))
                    
                    expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                    expect(viewModel.rightNavItems.firstValue()).to(equal([]))
                }
            }
        }
    }
}
