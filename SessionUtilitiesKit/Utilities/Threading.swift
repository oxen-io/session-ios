// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public class Threading {
    public static func dispatchMainThreadSafe(_ closure: @escaping () -> ()) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { dispatchMainThreadSafe(closure) }
            return
        }
        
        closure()
    }

    public static func dispatchSyncMainThreadSafe(_ closure: @escaping () -> ()) {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { dispatchSyncMainThreadSafe(closure) }
            return
        }
        
        closure()
    }
}
