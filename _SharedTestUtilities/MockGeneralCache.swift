// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

class MockGeneralCache: Mock<GeneralCacheType>, GeneralCacheType {
    var sessionId: SessionId? {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var recentReactionTimestamps: [Int64] {
        get { return (mock() ?? []) }
        set { mockNoReturn(args: [newValue]) }
    }
}
