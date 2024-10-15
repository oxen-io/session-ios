// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

@testable import SessionMessagingKit

class MockOGMCache: Mock<OGMCacheType>, OGMCacheType {
    var defaultRoomsPublisher: AnyPublisher<[OpenGroupManager.DefaultRoomInfo], Error> {
        mock()
    }
    
    var pendingChanges: [OpenGroupAPI.PendingChange] {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    func getTimeSinceLastOpen(using dependencies: Dependencies) -> TimeInterval {
        return mock(args: [dependencies])
    }
    
    func setDefaultRoomInfo(_ info: [OpenGroupManager.DefaultRoomInfo]) {
        mockNoReturn(args: [info])
    }
}
