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
    
    var hasInsufficientSnodes: Bool {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    func hasLoadedSwarm(for publicKey: String) -> Bool {
        return mock(args: [publicKey])
    }
    
    func swarmCache(publicKey: String) -> Set<Snode>? {
        return mock(args: [publicKey])
    }
    
    func setSwarmCache(publicKey: String, cache: Set<Snode>) {
        mockNoReturn(args: [publicKey, cache])
    }
    
    func clearSwarmCache() {
        mockNoReturn()
    }
}
