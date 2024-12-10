// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUtilitiesKit

class MockGeneralCache: Mock<GeneralCacheType>, GeneralCacheType {
    var sessionId: SessionId {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var recentReactionTimestamps: [Int64] {
        get { return (mock() ?? []) }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var placeholderCache: NSCache<NSString, UIImage> {
        get { return (mock() ?? NSCache()) }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var contextualActionLookupMap: [Int: [String: [Int: Any]]] {
        get { return (mock() ?? [:]) }
        set { mockNoReturn(args: [newValue]) }
    }
    
    func setCachedSessionId(sessionId: SessionId) {
        mockNoReturn(args: [sessionId])
    }
}
