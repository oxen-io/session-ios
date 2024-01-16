// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Foundation
import Combine
import SessionUtilitiesKit

@testable import SessionSnodeKit

class MockSnodeAPICache: Mock<SnodeAPICacheType>, SnodeAPICacheType {
    var hasLoadedSnodePool: Bool {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var loadedSwarms: Set<String> {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var getSnodePoolPublisher: AnyPublisher<Set<Snode>, Error>? {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var snodeFailureCount: [Snode: UInt] {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var snodePool: Set<Snode> {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var clockOffsetMs: Int64 {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var swarmCache: [String: Set<Snode>] {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var hasInsufficientSnodes: Bool {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
}
