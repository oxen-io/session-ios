// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionSnodeKit
import SessionUtilitiesKit

@testable import SessionMessagingKit

extension PollerDestination: Mocked { static var mock: PollerDestination { .swarm(TestConstants.publicKey) } }

class MockPoller: Mock<PollerType>, PollerType {
    typealias PollResponse = Void
    
    var pollerQueue: DispatchQueue { DispatchQueue.main }
    var pollerName: String { mock() }
    var pollerDestination: PollerDestination { mock() }
    var logStartAndStopCalls: Bool { mock() }
    var receivedPollResponse: AnyPublisher<Void, Never> { mock() }
    var isPolling: Bool {
        get { mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    var pollCount: Int {
        get { mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    var failureCount: Int {
        get { mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    var lastPollStart: TimeInterval {
        get { mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    var cancellable: AnyCancellable? {
        get { mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    required init(
        pollerName: String,
        pollerQueue: DispatchQueue,
        pollerDestination: PollerDestination,
        pollerDrainBehaviour: SwarmDrainBehaviour,
        namespaces: [SnodeAPI.Namespace],
        failureCount: Int,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        customAuthMethod: (any AuthenticationMethod)?,
        using dependencies: Dependencies
    ) {
        super.init()
        
        mockNoReturn(
            args: [
                pollerName,
                pollerQueue,
                pollerDestination,
                pollerDrainBehaviour,
                namespaces,
                failureCount,
                shouldStoreMessages,
                logStartAndStopCalls,
                customAuthMethod
            ],
            untrackedArgs: [dependencies]
        )
    }
    
    internal required init(functionHandler: MockFunctionHandler? = nil, initialSetup: ((Mock<any PollerType>) -> ())? = nil) {
        super.init(functionHandler: functionHandler, initialSetup: initialSetup)
    }
    
    func startIfNeeded() { mockNoReturn() }
    func stop() { mockNoReturn() }
    func poll(forceSynchronousProcessing: Bool) -> AnyPublisher<PollResult, Error> { mock(args: [forceSynchronousProcessing]) }
    func nextPollDelay() -> TimeInterval { mock() }
    func handlePollError(_ error: Error, _ lastError: Error?) -> PollerErrorResponse { mock(args: [error, lastError]) }
}
