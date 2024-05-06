// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SignalCoreKit

private extension DispatchQueue {
    static var isDBWriteQueue: Bool {
        /// The `dispatch_queue_get_label` function is used to get the label for a given DispatchQueue, in Swift this
        /// was replaced with the `label` property on a queue instance but you used to be able to just pass `nil` in order
        /// to get the name of the current queue - it seems that there might be a hole in the current design where there isn't
        /// a built-in way to get the label of the current queue natively in Swift
        ///
        /// On a positive note it seems that we can safely call `__dispatch_queue_get_label(nil)` in order to do this,
        /// it won't appear in auto-completed code but works properly
        ///
        /// For more information see
        /// https://developer.apple.com/forums/thread/701313?answerId=705773022#705773022
        /// https://forums.swift.org/t/gcd-getting-current-dispatch-queue-name-with-swift-3/3039/2
        return (String(cString: __dispatch_queue_get_label(nil)) == "\(Storage.queuePrefix).writer")
    }
}

public enum LogType {
    case verbose
    case debug
    case info
    case warn
    case error
}

public func SNLog(_ type: LogType, _ message: String) {
    let logPrefixes: String = [
        "Session",
        (Thread.isMainThread ? "Main" : nil),
        (DispatchQueue.isDBWriteQueue ? "DBWrite" : nil)
    ]
    .compactMap { $0 }
    .joined(separator: ", ")
    
    #if DEBUG
    print("[\(logPrefixes)] \(message)")
    #endif
    
    switch type {
        case .verbose: OWSLogger.verbose("[\(logPrefixes)] \(message)")
        case .debug: OWSLogger.debug("[\(logPrefixes)] \(message)")
        case .info: OWSLogger.info("[\(logPrefixes)] \(message)")
        case .warn: OWSLogger.warn("[\(logPrefixes)] \(message)")
        case .error: OWSLogger.error("[\(logPrefixes)] \(message)")
    }
}

public func SNLogNotTests(_ type: LogType, _ message: String) {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
    
    SNLog(type, message)
}

// Default to 'info'
public func SNLog(_ message: String) { SNLog(.info, message) }
public func SNLogNotTests(_ message: String) { SNLogNotTests(.info, message) }
