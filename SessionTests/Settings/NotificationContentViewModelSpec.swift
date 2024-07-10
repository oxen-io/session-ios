// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit

@testable import Session

class NotificationContentViewModelSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        @TestState var dependencies: Dependencies! = Dependencies(
            storage: nil,
            scheduler: .immediate
        )
        @TestState var mockStorage: Storage! = {
            let result = SynchronousStorage(
                customWriter: try! DatabaseQueue(),
                migrationTargets: [
                    SNUtilitiesKit.self,
                    SNSnodeKit.self,
                    SNMessagingKit.self,
                    SNUIKit.self
                ],
                using: dependencies
            )
            dependencies.storage = result
            
            return result
        }()
        @TestState var viewModel: NotificationContentViewModel! = NotificationContentViewModel(
            using: dependencies
        )
        @TestState var dataChangeCancellable: AnyCancellable? = viewModel.tableDataPublisher
            .receive(on: ImmediateScheduler.shared)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { viewModel.updateTableData($0.0) }
            )
        @TestState var dismissCancellable: AnyCancellable?
        
        // MARK: - a NotificationContentViewModel
        describe("a NotificationContentViewModel") {
            // MARK: -- has the correct title
            it("has the correct title") {
                expect(viewModel.title).to(equal("NOTIFICATIONS_STYLE_CONTENT_TITLE".localized()))
            }

            // MARK: -- has the correct number of items
            it("has the correct number of items") {
                expect(viewModel.tableData.count)
                    .to(equal(1))
                expect(viewModel.tableData.first?.elements.count)
                    .to(equal(3))
            }
            
            // MARK: -- has the correct default state
            it("has the correct default state") {
                expect(viewModel.tableData.first?.elements)
                    .to(
                        equal([
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.nameAndPreview,
                                position: .top,
                                title: "NOTIFICATIONS_STYLE_CONTENT_OPTION_NAME_AND_CONTENT".localized(),
                                rightAccessory: .radio(
                                    isSelected: { true }
                                )
                            ),
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.nameNoPreview,
                                position: .middle,
                                title: "NOTIFICATIONS_STYLE_CONTENT_OPTION_NAME_ONLY".localized(),
                                rightAccessory: .radio(
                                    isSelected: { false }
                                )
                            ),
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.noNameNoPreview,
                                position: .bottom,
                                title: "NOTIFICATIONS_STYLE_CONTENT_OPTION_NO_NAME_OR_CONTENT".localized(),
                                rightAccessory: .radio(
                                    isSelected: { false }
                                )
                            )
                        ])
                    )
            }
            
            // MARK: -- starts with the correct item active if not default
            it("starts with the correct item active if not default") {
                mockStorage.write { db in
                    db[.preferencesNotificationPreviewType] = Preferences.NotificationPreviewType.nameNoPreview
                }
                viewModel = NotificationContentViewModel(using: dependencies)
                dataChangeCancellable = viewModel.tableDataPublisher
                    .receive(on: ImmediateScheduler.shared)
                    .sink(
                        receiveCompletion: { _ in },
                        receiveValue: { viewModel.updateTableData($0.0) }
                    )
                
                expect(viewModel.tableData.first?.elements)
                    .to(
                        equal([
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.nameAndPreview,
                                position: .top,
                                title: "NOTIFICATIONS_STYLE_CONTENT_OPTION_NAME_AND_CONTENT".localized(),
                                rightAccessory: .radio(
                                    isSelected: { false }
                                )
                            ),
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.nameNoPreview,
                                position: .middle,
                                title: "NOTIFICATIONS_STYLE_CONTENT_OPTION_NAME_ONLY".localized(),
                                rightAccessory: .radio(
                                    isSelected: { true }
                                )
                            ),
                            SessionCell.Info(
                                id: Preferences.NotificationPreviewType.noNameNoPreview,
                                position: .bottom,
                                title: "NOTIFICATIONS_STYLE_CONTENT_OPTION_NO_NAME_OR_CONTENT".localized(),
                                rightAccessory: .radio(
                                    isSelected: { false }
                                )
                            )
                        ])
                    )
            }
            
            // MARK: -- when tapping an item
            context("when tapping an item") {
                // MARK: ---- updates the saved preference
                it("updates the saved preference") {
                    viewModel.tableData.first?.elements.last?.onTap?()
                    
                    expect(mockStorage[.preferencesNotificationPreviewType])
                        .to(equal(Preferences.NotificationPreviewType.noNameNoPreview))
                }
                
                // MARK: ---- dismisses the screen
                it("dismisses the screen") {
                    var didDismissScreen: Bool = false
                    
                    dismissCancellable = viewModel.navigatableState.dismissScreen
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { _ in didDismissScreen = true }
                        )
                    viewModel.tableData.first?.elements.last?.onTap?()
                    
                    expect(didDismissScreen).to(beTrue())
                }
            }
        }
    }
}
