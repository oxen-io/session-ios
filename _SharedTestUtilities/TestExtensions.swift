// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Collection {
    subscript(test index: Index) -> Element? {
        return (indices.contains(index) ? self[index] : nil)
    }
}

public extension Array {
    func allCombinations() -> [[Element]] {
        guard !isEmpty else { return [[]] }
        
        return Array(self[1...]).allCombinations().flatMap { [$0, ([self[0]] + $0)] }
    }
}
