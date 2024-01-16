// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public protocol UpdatableTimestamp {
    func with(timestampMs: UInt64) -> Self
}
