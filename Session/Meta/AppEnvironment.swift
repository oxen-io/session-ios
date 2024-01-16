// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit
import SignalUtilitiesKit
import SignalCoreKit
import SessionMessagingKit

public class AppEnvironment {

    private static var _shared: AppEnvironment = AppEnvironment()

    public class var shared: AppEnvironment {
        get { return _shared }
        set {
            guard SNUtilitiesKit.isRunningTests else {
                owsFailDebug("Can only switch environments in tests.")
                return
            }

            _shared = newValue
        }
    }

    public var pushRegistrationManager: PushRegistrationManager
    public var fileLogger: DDFileLogger

    private init() {
        self.pushRegistrationManager = PushRegistrationManager()
        self.fileLogger = DDFileLogger()
        
        SwiftSingletons.register(self)
    }

    public func setup() {
        setupLogFiles()
    }
    
    private func setupLogFiles() {
        fileLogger.rollingFrequency = kDayInterval // Refresh everyday
        fileLogger.logFileManager.maximumNumberOfLogFiles = 3 // Save 3 days' log files
        DDLog.add(fileLogger)
    }
}
