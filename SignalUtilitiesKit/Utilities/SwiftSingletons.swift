//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.

import Foundation
import SessionUtilitiesKit

public class SwiftSingletons: NSObject {
    public static let shared = SwiftSingletons()

    private var classSet = Set<String>()

    private override init() {
        super.init()
    }

    public func register(_ singleton: AnyObject) {
        guard !SNUtilitiesKit.isRunningTests else { return }
        guard _isDebugAssertConfiguration() else { return }
        let singletonClassName = String(describing: type(of: singleton))
        guard !classSet.contains(singletonClassName) else {
            Log.error("[SwiftSingletons] Duplicate singleton: \(singletonClassName).")
            return
        }
        Log.verbose("[SwiftSingletons] Registering singleton: \(singletonClassName).")
        classSet.insert(singletonClassName)
    }

    public static func register(_ singleton: AnyObject) {
        shared.register(singleton)
    }
}
