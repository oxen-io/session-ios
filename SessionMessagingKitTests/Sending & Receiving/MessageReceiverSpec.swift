// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble
import SessionSnodeKit
import SessionUtilitiesKit
import SessionUIKit

@testable import SessionMessagingKit

class MessageReceiverSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies[feature: .updatedDisappearingMessages] = true
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
                try SessionThread.fetchOrCreate(
                    db,
                    id: "TestId",
                    variant: .contact,
                    shouldBeVisible: true,
                    calledFromConfigHandling: false,
                    using: dependencies
                )
            }
        )
        @TestState var mockProto: SNProtoContent! = {
            let proto = SNProtoContent.builder()
            let dataMessage = SNProtoDataMessage.builder()
            proto.setExpirationType(.deleteAfterRead)
            proto.setExpirationTimer(UInt32(DisappearingMessagesConfiguration.DefaultDuration.disappearAfterRead.seconds))
            proto.setLastDisappearingMessageChangeTimestamp((1234567890 - (60 * 10)) * 1000)
            dataMessage.setBody("Test")
            proto.setDataMessage(try! dataMessage.build())
            return try? proto.build()
        }()
        @TestState var mockMessage: VisibleMessage! = {
            let result = VisibleMessage(
                sender: "TestId",
                sentTimestamp: ((1234567890 - (60 * 10)) * 1000),
                recipient: "05\(TestConstants.publicKey)",
                text: "Test"
            )
            result.receivedTimestamp = (1234567890 * 1000)
            return result
        }()
        
        // MARK: - a MessageReceiver
        describe("a MessageReceiver") {
            // MARK: -- when receiving an outdated disappearing message config update
            context("when receiving an outdated disappearing message config update") {
                // MARK: ---- does NOT update local config
                it("does NOT update local config") {
                    let config: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration
                        .defaultWith("TestId")
                        .with(
                            isEnabled: false,
                            durationSeconds: 0,
                            type: .unknown,
                            lastChangeTimestampMs: (1234567890 * 1000)
                        )
                    
                    mockStorage.write { db in
                        try config.upsert(db)
                        
                        try MessageReceiver.handle(
                            db,
                            threadId: "TestId",
                            threadVariant: .contact,
                            message: mockMessage,
                            serverExpirationTimestamp: nil,
                            associatedWithProto: mockProto
                        )
                    }
                    
                    let updatedConfig: DisappearingMessagesConfiguration? = mockStorage.read { db in
                        try DisappearingMessagesConfiguration.fetchOne(db, id: "TestId")
                    }
                    
                    expect(updatedConfig?.isEnabled).to(beFalse())
                    expect(updatedConfig?.durationSeconds).to(equal(0))
                    expect(updatedConfig?.type).to(equal(.unknown))
                }
            }
            
            // MARK: -- when receiving a newer disappearing message config update
            context("when receiving a newer disappearing message config update") {
                // MARK: ---- updates the local config properly
                it("updates the local config properly") {
                    mockStorage.write { db in
                        do {
                            try MessageReceiver.handle(
                                db,
                                threadId: "TestId",
                                threadVariant: .contact,
                                message: mockMessage,
                                serverExpirationTimestamp: nil,
                                associatedWithProto: mockProto
                            )
                        }
                        catch {
                            print(error)
                        }
                    }
                    
                    let updatedConfig: DisappearingMessagesConfiguration? = mockStorage.read { db in
                        try DisappearingMessagesConfiguration.fetchOne(db, id: "TestId")
                    }
                    
                    expect(updatedConfig?.isEnabled).to(beTrue())
                    expect(updatedConfig?.durationSeconds)
                        .to(equal(DisappearingMessagesConfiguration.DefaultDuration.disappearAfterRead.seconds))
                    expect(updatedConfig?.type).to(equal(.disappearAfterRead))
                }
            }
        }
    }
}
