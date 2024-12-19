// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class CommunityPollerSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
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
                
                try OpenGroup(
                    server: "testServer",
                    roomToken: "testRoom",
                    publicKey: TestConstants.publicKey,
                    isActive: true,
                    name: "Test",
                    roomDescription: nil,
                    imageId: nil,
                    userCount: 0,
                    infoUpdates: 0
                ).insert(db)
                try OpenGroup(
                    server: "testServer1",
                    roomToken: "testRoom1",
                    publicKey: TestConstants.publicKey,
                    isActive: true,
                    name: "Test1",
                    roomDescription: nil,
                    imageId: nil,
                    userCount: 0,
                    infoUpdates: 0
                ).insert(db)
                try Capability(openGroupServer: "testServer", variant: .sogs, isMissing: false).insert(db)
            }
        )
        @TestState(singleton: .network, in: dependencies) var mockNetwork: MockNetwork! = MockNetwork(
            initialSetup: { network in
                // Delay for 10 seconds because we don't want the Poller to get stuck in a recursive loop
                network
                    .when { $0.send(.any, to: .any, requestTimeout: .any, requestAndPathBuildTimeout: .any) }
                    .thenReturn(
                        MockNetwork.response(with: FileUploadResponse(id: "1"))
                            .delay(for: .seconds(10), scheduler: DispatchQueue.main)
                            .eraseToAnyPublisher()
                    )
            }
        )
        @TestState(defaults: .standard, in: dependencies) var mockUserDefaults: MockUserDefaults! = MockUserDefaults()
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
            }
        )
        @TestState(cache: .openGroupManager, in: dependencies) var mockOGMCache: MockOGMCache! = MockOGMCache(
            initialSetup: { cache in
                cache.when { $0.pendingChanges }.thenReturn([])
                cache.when { $0.getTimeSinceLastOpen(using: .any) }.thenReturn(0)
            }
        )
        @TestState var cache: CommunityPoller.Cache! = CommunityPoller.Cache(using: dependencies)
        
        // MARK: - a CommunityPollerCache
        describe("a CommunityPollerCache") {
            // MARK: -- when starting polling
            context("when starting polling") {
                // MARK: ---- creates pollers for all of the communities
                it("creates pollers for all of the communities") {
                    cache.startAllPollers()
                    
                    expect(cache.serversBeingPolled).to(equal(["testserver", "testserver1"]))
                }
                
                // MARK: ---- updates the isPolling flag
                it("updates the isPolling flag") {
                    cache.startAllPollers()
                    
                    expect(cache.allPollers.count).to(equal(2))
                    expect(cache.allPollers[0].isPolling).to(beTrue())
                    expect(cache.allPollers[1].isPolling).to(beTrue())
                }
                
                // MARK: ---- does not create additional pollers if it's already polling
                it("does not create additional pollers if it's already polling") {
                    cache
                        .getOrCreatePoller(for: CommunityPoller.Info(server: "testserver", pollFailureCount: 0))
                        .startIfNeeded()
                    cache
                        .getOrCreatePoller(for: CommunityPoller.Info(server: "testserver1", pollFailureCount: 0))
                        .startIfNeeded()
                    
                    cache.startAllPollers()
                    
                    expect(cache.allPollers.count).to(equal(2))
                }
            }
            
            // MARK: -- when stopping polling
            context("when stopping polling") {
                beforeEach {
                    cache.startAllPollers()
                }
                
                // MARK: ---- removes all pollers
                it("removes all pollers") {
                    cache.stopAndRemoveAllPollers()
                    
                    expect(cache.allPollers.count).to(equal(0))
                }
                
                // MARK: ---- updates the isPolling flag
                it("updates the isPolling flag") {
                    let poller1 = cache.getOrCreatePoller(for: CommunityPoller.Info(server: "testserver", pollFailureCount: 0))
                    let poller2 = cache.getOrCreatePoller(for: CommunityPoller.Info(server: "testserver1", pollFailureCount: 0))
                    cache.stopAndRemoveAllPollers()
                    
                    expect(poller1.isPolling).to(beFalse())
                    expect(poller2.isPolling).to(beFalse())
                }
            }
        }
    }
}
