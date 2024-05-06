// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension Timer {
    @discardableResult public static func scheduledTimerOnMainThread(
        withTimeInterval timeInterval: TimeInterval,
        repeats: Bool = false,
        using dependencies: Dependencies = Dependencies(),
        block: @escaping (Timer) -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: timeInterval, repeats: repeats, block: block)
        
        // If we are forcing synchrnonous execution (ie. running unit tests) then ceil the
        // timeInterval for execution and append it to the execution set so the test can
        // trigger the logic in a synchronous way)
        guard !dependencies.forceSynchronous else {
            dependencies.async(at: dependencies.dateNow.timeIntervalSince1970 + timeInterval) {
                block(timer)
            }
            return timer
        }
        
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

// MARK: - Objective-C Extensions

public extension Timer {
    @objc static func weakScheduledTimer(timeInterval: TimeInterval, repeats: Bool, onFire: @escaping (Timer) -> ()) -> Timer {
        return Timer.scheduledTimerOnMainThread(withTimeInterval: timeInterval, repeats: repeats, block: onFire)
    }
}
