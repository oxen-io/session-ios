// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Foundation
import Combine
import SessionUtilitiesKit

@testable import SessionSnodeKit

class MockSnodeAPICache: Mock<SnodeAPICacheType>, SnodeAPICacheType {
    var hardfork: Int {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var softfork: Int {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var clockOffsetMs: Int64 { mock() }
    
    func currentOffsetTimestampMs<T>() -> T where T: Numeric {
        return mock()
    }
    
    func setClockOffsetMs(_ clockOffsetMs: Int64) {
        mockNoReturn(args: [clockOffsetMs])
    }
}
