// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

@testable import SessionMessagingKit

class MockGroupPollerCache: Mock<GroupPollerCacheType>, GroupPollerCacheType {
    func startAllPollers() { mockNoReturn() }
    @discardableResult func getOrCreatePoller(for swarmPublicKey: String) -> SwarmPollerType { mock(args: [swarmPublicKey]) }
    func stopAndRemovePoller(for swarmPublicKey: String) { mockNoReturn(args: [swarmPublicKey]) }
    func stopAndRemoveAllPollers() { mockNoReturn() }
}
