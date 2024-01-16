// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

@testable import SessionMessagingKit

class MockLibSessionCache: Mock<LibSessionCacheType>, LibSessionCacheType {
    var isEmpty: Bool { return mock() }
    var needsSync: Bool { return mock() }
    
    func setConfig(for variant: ConfigDump.Variant, sessionId: SessionId, to config: LibSession.Config?) {
        mockNoReturn(args: [variant, sessionId, config])
    }
    
    func config(for variant: ConfigDump.Variant, sessionId: SessionId) -> Atomic<LibSession.Config?> {
        return mock(args: [variant, sessionId])
    }
    
    func removeAll() {
        mockNoReturn()
    }
}
