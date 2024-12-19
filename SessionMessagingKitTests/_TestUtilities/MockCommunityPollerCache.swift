// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

@testable import SessionMessagingKit

class MockCommunityPollerCache: Mock<CommunityPollerCacheType>, CommunityPollerCacheType {
    var serversBeingPolled: Set<String> { mock() }
    var allPollers: [CommunityPollerType] { mock() }
    
    func startAllPollers() { mockNoReturn() }
    @discardableResult func getOrCreatePoller(for info: CommunityPoller.Info) -> CommunityPollerType { mock(args: [info]) }
    func stopAndRemovePoller(for server: String) { mockNoReturn(args: [server]) }
    func stopAndRemoveAllPollers() { mockNoReturn() }
}
