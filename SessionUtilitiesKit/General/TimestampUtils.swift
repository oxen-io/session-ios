// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public final class TimestampUtils {
    public static func isWithinOneMinute(timestampMs: UInt64) -> Bool {
        Date().timeIntervalSince(Date(timeIntervalSince1970: (TimeInterval(timestampMs) / 1000))) <= 60
    }
}
