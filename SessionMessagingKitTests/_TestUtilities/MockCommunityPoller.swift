// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

@testable import SessionMessagingKit

class MockCommunityPoller: Mock<CommunityPollerType>, CommunityPollerType {
    var isPolling: Bool { mock() }
    var receivedPollResponse: AnyPublisher<PollResponse, Never> { mock() }
    
    func startIfNeeded() { mockNoReturn() }
    func stop() { mockNoReturn() }
}
