// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SignalCoreKit

// MARK: - Log

public enum Log {
    fileprivate typealias LogInfo = (level: Log.Level, message: String, withPrefixes: Bool, silenceForTests: Bool)
    
    public enum Level: Comparable {
        case verbose
        case debug
        case info
        case warn
        case error
        case critical
        case off
    }
    
    private static var logger: Atomic<Logger?> = Atomic(nil)
    private static var pendingStartupLogs: Atomic<[LogInfo]> = Atomic([])
    
    public static func setup(with logger: Logger) {
        logger.retrievePendingStartupLogs = {
            pendingStartupLogs.mutate { pendingStartupLogs in
                let logs: [LogInfo] = pendingStartupLogs
                pendingStartupLogs = []
                return logs
            }
        }
        Log.logger.mutate { $0 = logger }
    }
    
    public static func appResumedExecution() {
        guard logger.wrappedValue != nil else { return }
        
        logger.wrappedValue?.loadExtensionLogsAndResumeLogging()
    }
    
    public static func logFilePath() -> String? {
        guard
            let logger: Logger = logger.wrappedValue
        else { return nil }
        
        let logFiles: [String] = logger.fileLogger.logFileManager.sortedLogFilePaths
        
        guard !logFiles.isEmpty else { return nil }
        
        // If the latest log file is too short (ie. less that ~100kb) then we want to create a temporary file
        // which contains the previous log file logs plus the logs from the newest file so we don't miss info
        // that might be relevant for debugging
        guard
            logFiles.count > 1,
            let attributes: [FileAttributeKey: Any] = try? FileManager.default.attributesOfItem(atPath: logFiles[0]),
            let fileSize: UInt64 = attributes[.size] as? UInt64,
            fileSize < (100 * 1024)
        else { return logFiles[0] }
        
        // The file is too small so lets create a temp file to share instead
        let tempDirectory: String = NSTemporaryDirectory()
        let tempFilePath: String = URL(fileURLWithPath: tempDirectory)
            .appendingPathComponent(URL(fileURLWithPath: logFiles[1]).lastPathComponent)
            .path
        
        do {
            try FileManager.default.copyItem(
                atPath: logFiles[1],
                toPath: tempFilePath
            )
            
            guard let fileHandle: FileHandle = FileHandle(forWritingAtPath: tempFilePath) else {
                throw StorageError.objectNotFound
            }
            
            // Ensure we close the file handle
            defer { fileHandle.closeFile() }
            
            // Move to the end of the file to insert the logs
            if #available(iOS 13.4, *) { try fileHandle.seekToEnd() }
            else { fileHandle.seekToEndOfFile() }
            
            // Append the data from the newest log to the temp file
            let newestLogData: Data = try Data(contentsOf: URL(fileURLWithPath: logFiles[0]))
            if #available(iOS 13.4, *) { try fileHandle.write(contentsOf: newestLogData) }
            else { fileHandle.write(newestLogData) }
        }
        catch { return logFiles[0] }
        
        return tempFilePath
    }
    
    public static func flush() {
        DDLog.flushLog()
    }
    
    // MARK: - Log Functions
    
    fileprivate static func empty() {
        let emptyArguments: [CVarArg] = []
        
        withVaList(emptyArguments) { ptr in
            DDLog.log(
                asynchronous: true,
                level: .info,
                flag: .info,
                context: 0,
                file: "",
                function: "",
                line: 0,
                tag: nil,
                format: "",
                arguments: ptr)
        }
    }
    
    public static func verbose(
        _ message: String,
        withPrefixes: Bool = true,
        silenceForTests: Bool = false
    ) {
        custom(.verbose, message, withPrefixes: withPrefixes, silenceForTests: silenceForTests)
    }
    
    public static func debug(
        _ message: String,
        withPrefixes: Bool = true,
        silenceForTests: Bool = false
    ) {
        custom(.debug, message, withPrefixes: withPrefixes, silenceForTests: silenceForTests)
    }
    
    public static func info(
        _ message: String,
        withPrefixes: Bool = true,
        silenceForTests: Bool = false
    ) {
        custom(.info, message, withPrefixes: withPrefixes, silenceForTests: silenceForTests)
    }
    
    public static func warn(
        _ message: String,
        withPrefixes: Bool = true,
        silenceForTests: Bool = false
    ) {
        custom(.warn, message, withPrefixes: withPrefixes, silenceForTests: silenceForTests)
    }
    
    public static func error(
        _ message: String,
        withPrefixes: Bool = true,
        silenceForTests: Bool = false
    ) {
        custom(.error, message, withPrefixes: withPrefixes, silenceForTests: silenceForTests)
    }
    
    public static func critical(
        _ message: String,
        withPrefixes: Bool = true,
        silenceForTests: Bool = false
    ) {
        custom(.critical, message, withPrefixes: withPrefixes, silenceForTests: silenceForTests)
    }
    
    public static func custom(
        _ level: Log.Level,
        _ message: String,
        withPrefixes: Bool,
        silenceForTests: Bool
    ) {
        guard
            let logger: Logger = logger.wrappedValue,
            !logger.isSuspended.wrappedValue
        else { return pendingStartupLogs.mutate { $0.append((level, message, withPrefixes, silenceForTests)) } }
        
        logger.log(level, message, withPrefixes: withPrefixes, silenceForTests: silenceForTests)
    }
}

// MARK: - Logger

public class Logger {
    private let isRunningTests: Bool = (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil)
    private let primaryPrefix: String
    private var level: Log.Level
    private let forceNSLog: Bool
    fileprivate let fileLogger: DDFileLogger
    fileprivate let isSuspended: Atomic<Bool> = Atomic(true)
    fileprivate var retrievePendingStartupLogs: (() -> [Log.LogInfo])?
    
    public init(
        primaryPrefix: String,
        level: Log.Level,
        customDirectory: String? = nil,
        forceNSLog: Bool = false
    ) {
        self.primaryPrefix = primaryPrefix
        self.level = level
        self.forceNSLog = forceNSLog
        
        switch customDirectory {
            case .none: self.fileLogger = DDFileLogger()
            case .some(let customDirectory):
                let logFileManager: DDLogFileManagerDefault = DDLogFileManagerDefault(logsDirectory: customDirectory)
                self.fileLogger = DDFileLogger(logFileManager: logFileManager)
        }
        
        // We want to use the local datetime and show the timezone offset because it'll make
        // it easier to debug when users provide logs and specify that something happened at
        // a certain time (the default is UTC so we'd need to know the users timezone in order
        // to convert and debug effectively)
        let dateFormatter: DateFormatter = DateFormatter()
        dateFormatter.formatterBehavior = .behavior10_4      // 10.4+ style
        dateFormatter.locale = NSLocale.current              // Use the current locale and include the timezone instead of UTC
        dateFormatter.timeZone = NSTimeZone.local
        dateFormatter.dateFormat = "yyyy/MM/dd HH:mm:ss:SSS ZZZZZ"
        
        self.fileLogger.logFormatter = DDLogFileFormatterDefault(dateFormatter: dateFormatter)
        self.fileLogger.rollingFrequency = kDayInterval // Refresh everyday
        self.fileLogger.logFileManager.maximumNumberOfLogFiles = 3 // Save 3 days' log files
        DDLog.add(self.fileLogger)
        
        // Now that we are setup we should load the extension logs which will then
        // complete the startup process when completed
        self.loadExtensionLogsAndResumeLogging()
    }
    
    // MARK: - Functions
    
    fileprivate func loadExtensionLogsAndResumeLogging() {
        // Pause logging while we load the extension logs (want to avoid interleaving them where possible)
        isSuspended.mutate { $0 = true }
        
        // The extensions write their logs to the app shared directory but the main app writes
        // to a local directory (so they can be exported via XCode) - the below code reads any
        // logs from the shared directly and attempts to add them to the main app logs to make
        // debugging user issues in extensions easier
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let currentLogFileInfo: DDLogFileInfo = self?.fileLogger.currentLogFileInfo else {
                self?.completeResumeLogging(error: "Unable to retrieve current log file.")
                return
            }
            
            DDLog.loggingQueue.async {
                let extensionInfo: [(dir: String, type: ExtensionType)] = [
                    ("\(OWSFileSystem.appSharedDataDirectoryPath())/Logs/NotificationExtension", .notification),
                    ("\(OWSFileSystem.appSharedDataDirectoryPath())/Logs/ShareExtension", .share)
                ]
                let extensionLogs: [(path: String, type: ExtensionType)] = extensionInfo.flatMap { dir, type -> [(path: String, type: ExtensionType)] in
                    guard let files: [String] = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
                    
                    return files.map { ("\(dir)/\($0)", type) }
                }
                
                do {
                    guard let fileHandle: FileHandle = FileHandle(forWritingAtPath: currentLogFileInfo.filePath) else {
                        throw StorageError.objectNotFound
                    }
                    
                    // Ensure we close the file handle
                    defer { fileHandle.closeFile() }
                    
                    // Move to the end of the file to insert the logs
                    if #available(iOS 13.4, *) { try fileHandle.seekToEnd() }
                    else { fileHandle.seekToEndOfFile() }
                    
                    try extensionLogs
                        .grouped(by: \.type)
                        .forEach { type, value in
                            guard !value.isEmpty else { return }    // Ignore if there are no logs
                            guard
                                let typeNameStartData: Data = "🧩 \(type.name) -- Start\n".data(using: .utf8),
                                let typeNameEndData: Data = "🧩 \(type.name) -- End\n".data(using: .utf8)
                            else { throw StorageError.invalidData }
                            
                            var hasWrittenStartLog: Bool = false
                            
                            // Write the logs
                            try value.forEach { path, _ in
                                let logData: Data = try Data(contentsOf: URL(fileURLWithPath: path))
                                
                                guard !logData.isEmpty else { return }  // Ignore empty files
                                
                                // Write the type start separator if needed
                                if !hasWrittenStartLog {
                                    if #available(iOS 13.4, *) { try fileHandle.write(contentsOf: typeNameStartData) }
                                    else { fileHandle.write(typeNameStartData) }
                                    hasWrittenStartLog = true
                                }
                                
                                // Write the log data to the log file
                                if #available(iOS 13.4, *) { try fileHandle.write(contentsOf: logData) }
                                else { fileHandle.write(logData) }
                                
                                // Extension logs have been writen to the app logs, remove them now
                                try? FileManager.default.removeItem(atPath: path)
                            }
                            
                            // Write the type end separator if needed
                            if hasWrittenStartLog {
                                if #available(iOS 13.4, *) { try fileHandle.write(contentsOf: typeNameEndData) }
                                else { fileHandle.write(typeNameEndData) }
                            }
                        }
                }
                catch {
                    self?.completeResumeLogging(error: "Unable to write extension logs to current log file")
                    return
                }
                
                self?.completeResumeLogging()
            }
        }
    }
    
    private func completeResumeLogging(error: String? = nil) {
        let pendingLogs: [Log.LogInfo] = isSuspended.mutate { isSuspended in
            isSuspended = false
            return (retrievePendingStartupLogs?() ?? [])
        }
        
        // If we had an error loading the extension logs then actually log it
        if let error: String = error {
            Log.empty()
            log(.error, error, withPrefixes: true, silenceForTests: false)
        }
        
        // After creating a new logger we want to log two empty lines to make it easier to read
        Log.empty()
        Log.empty()
        
        // Add any logs that were pending during the startup process
        pendingLogs.forEach { level, message, withPrefixes, silenceForTests in
            log(level, message, withPrefixes: withPrefixes, silenceForTests: silenceForTests)
        }
    }
    
    fileprivate func log(
        _ level: Log.Level,
        _ message: String,
        withPrefixes: Bool,
        silenceForTests: Bool
    ) {
        guard !silenceForTests || !isRunningTests else { return }
        guard level >= self.level else { return }
        
        // Sort out the prefixes
        let logPrefix: String = {
            guard withPrefixes else { return "" }
            
            let prefixes: String = [
                primaryPrefix,
                (Thread.isMainThread ? "Main" : nil),
                (DispatchQueue.isDBWriteQueue ? "DBWrite" : nil)
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
            
            return "[\(prefixes)] "
        }()
        
        // Clean up the message if needed (replace double periods with single, trim whitespace)
        let logMessage: String = logPrefix
            .appending(message)
            .replacingOccurrences(of: "...", with: "|||")
            .replacingOccurrences(of: "..", with: ".")
            .replacingOccurrences(of: "|||", with: "...")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        switch level {
            case .off: return
            case .verbose: OWSLogger.verbose(logMessage)
            case .debug: OWSLogger.debug(logMessage)
            case .info: OWSLogger.info(logMessage)
            case .warn: OWSLogger.warn(logMessage)
            case .error, .critical: OWSLogger.error(logMessage)
            
        }
        
        #if DEBUG
        print(logMessage)
        #else
        if forceNSLog {
            NSLog(message)
        }
        #endif
    }
}

// MARK: - Convenience

private enum ExtensionType {
    case share
    case notification
    
    var name: String {
        switch self {
            case .share: return "ShareExtension"
            case .notification: return "NotificationExtension"
        }
    }
}

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

// FIXME: Remove this once everything has been updated to use the new `Log.x()` methods.
public func SNLog(_ message: String, forceNSLog: Bool = false) {
    Log.info(message)
}
