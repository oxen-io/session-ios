// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public struct EquatableIgnoring<T>: Equatable {
    public let value: T
    
    public init(value: T) {
        self.value = value
    }
    
    public static func == (lhs: EquatableIgnoring<T>, rhs: EquatableIgnoring<T>) -> Bool {
        return true
    }
}
