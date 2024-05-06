//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.

import Foundation
import SignalCoreKit
import SessionUtilitiesKit

public class SwiftSingletons {
    public static let shared = SwiftSingletons()

    private var classSet = Set<String>()

    public func register(_ singleton: AnyObject) {
        guard !SNUtilitiesKit.isRunningTests else { return }
        guard _isDebugAssertConfiguration() else { return }
        let singletonClassName = String(describing: type(of: singleton))
        guard !classSet.contains(singletonClassName) else {
            owsFailDebug("Duplicate singleton: \(singletonClassName).")
            return
        }
        Logger.verbose("Registering singleton: \(singletonClassName).")
        classSet.insert(singletonClassName)
    }

    public static func register(_ singleton: AnyObject) {
        shared.register(singleton)
    }
}
