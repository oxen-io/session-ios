// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

@testable import SessionMessagingKit

class MockSessionUtilCache: Mock<SessionUtilCacheType>, SessionUtilCacheType {
    var isEmpty: Bool { return mock() }
    var needsSync: Bool { return mock() }
    
    func setConfig(for variant: ConfigDump.Variant, sessionId: SessionId, to config: SessionUtil.Config?) {
        mockNoReturn(args: [variant, sessionId, config])
    }
    
    func config(for variant: ConfigDump.Variant, sessionId: SessionId) -> Atomic<SessionUtil.Config?> {
        return mock(args: [variant, sessionId])
    }
    
    func removeAll() {
        mockNoReturn()
    }
}
