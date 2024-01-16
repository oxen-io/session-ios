// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionSnodeKit
import SessionUtilitiesKit

@testable import SessionMessagingKit

class MockPoller: Mock<PollerType>, PollerType {
    func start(using dependencies: Dependencies) {
        mockNoReturn(untrackedArgs: [dependencies])
    }
    
    func startIfNeeded(for publicKey: String, using dependencies: Dependencies) {
        mockNoReturn(args: [publicKey], untrackedArgs: [dependencies])
    }
    
    func stopAllPollers() {
        mockNoReturn(args: [])
    }
    
    func stopPolling(for publicKey: String) {
        mockNoReturn(args: [publicKey])
    }
    
    func poll(
        namespaces: [SnodeAPI.Namespace],
        for publicKey: String,
        calledFromBackgroundPoller: Bool,
        isBackgroundPollValid: @escaping () -> Bool,
        drainBehaviour: Atomic<SwarmDrainBehaviour>,
        using dependencies: Dependencies
    ) -> AnyPublisher<[ProcessedMessage], Error> {
        mock(args: [
            namespaces,
            publicKey,
            calledFromBackgroundPoller,
            isBackgroundPollValid,
            drainBehaviour,
            dependencies
        ])
    }
    
    func afterNextPoll(
        for publicKey: String,
        closure: @escaping ([ProcessedMessage]) -> ()
    ) {
        mockNoReturn(args: [publicKey, closure])
        closure([])
    }
}
