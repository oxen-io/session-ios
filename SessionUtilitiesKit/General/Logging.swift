// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import CocoaLumberjackSwift

// MARK: - Log.Level Convenience

public extension Log.Category {
    static let `default`: Log.Category = .create("default", defaultLevel: .warn)
}

// MARK: - FeatureStorage

public extension FeatureStorage {
    static func logLevel(cat: Log.Category) -> FeatureConfig<Log.Level> {
        return Dependencies.create(
            identifier: cat.identifier,
            groupIdentifier: "logging",
            defaultOption: cat.defaultLevel
        )
    }
    
    static let allLogLevels: FeatureConfig<AllLoggingCategories> = Dependencies.create(
        identifier: "allLogLevels",
        groupIdentifier: "logging"
    )
}

// MARK: - Log

public enum Log {
    fileprivate typealias LogInfo = (
        level: Log.Level,
        categories: [Category],
        message: String,
        file: StaticString,
        function: StaticString,
        line: UInt
    )
    
    public enum Level: Comparable, CaseIterable {
        case verbose
        case debug
        case info
        case warn
        case error
        case critical
        case off
        
        case `default`
    }
    
    public struct Category: Hashable {
        public let rawValue: String
        fileprivate let customPrefix: String
        public let defaultLevel: Log.Level
        
        fileprivate static let identifierPrefix: String = "logLevel-"
        fileprivate var identifier: String { "\(Category.identifierPrefix)\(rawValue)" }
        
        private init(rawValue: String, customPrefix: String, defaultLevel: Log.Level) {
            self.rawValue = rawValue
            self.customPrefix = customPrefix
            self.defaultLevel = defaultLevel
            
            AllLoggingCategories.register(category: self)
        }
        
        fileprivate init?(identifier: String) {
            guard identifier.hasPrefix(Category.identifierPrefix) else { return nil }
            
            self.init(
                rawValue: identifier.substring(from: Category.identifierPrefix.count),
                customPrefix: "",
                defaultLevel: .default
            )
        }
        
        public init(rawValue: String, customPrefix: String = "") {
            self.init(rawValue: rawValue, customPrefix: customPrefix, defaultLevel: .default)
        }
        
        @discardableResult public static func create(_ rawValue: String, customPrefix: String = "", defaultLevel: Log.Level) -> Log.Category {
            return Log.Category(rawValue: rawValue, customPrefix: customPrefix, defaultLevel: defaultLevel)
        }
    }
    
    private static var logger: Atomic<Logger?> = Atomic(nil)
    private static var pendingStartupLogs: Atomic<[LogInfo]> = Atomic([])
    
    public static func setup(with logger: Logger) {
        logger.pendingLogsRetriever.mutate { callback in
            callback = {
                pendingStartupLogs.mutate { pendingStartupLogs in
                    let logs: [LogInfo] = pendingStartupLogs
                    pendingStartupLogs = []
                    return logs
                }
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
        _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.verbose, [], msg, file: file, function: function, line: line) }
    public static func verbose(
        _ cat: Category
        , _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.verbose, [cat], msg, file: file, function: function, line: line) }
    public static func verbose(
        _ cats: [Category],
        _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.verbose, cats, msg, file: file, function: function, line: line) }
    
    public static func debug(
        _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.debug, [], msg, file: file, function: function, line: line) }
    public static func debug(
        _ cat: Category,
        _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.debug, [cat], msg, file: file, function: function, line: line) }
    public static func debug(
        _ cats: [Category],
        _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.debug, cats, msg, file: file, function: function, line: line) }
    
    public static func info(
        _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.info, [], msg, file: file, function: function, line: line) }
    public static func info(
        _ cat: Category,
        _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.info, [cat], msg, file: file, function: function, line: line) }
    public static func info(
        _ cats: [Category],
        _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.info, cats, msg, file: file, function: function, line: line) }
    
    public static func warn(
        _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.warn, [], msg, file: file, function: function, line: line) }
    public static func warn(
        _ cat: Category,
        _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.warn, [cat], msg, file: file, function: function, line: line) }
    public static func warn(
        _ cats: [Category],
        _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.warn, cats, msg, file: file, function: function, line: line) }
    
    public static func error(
        _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.error, [], msg, file: file, function: function, line: line) }
    public static func error(
        _ cat: Category,
        _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.error, [cat], msg, file: file, function: function, line: line) }
    public static func error(
        _ cats: [Category],
        _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.error, cats, msg, file: file, function: function, line: line) }
    
    public static func critical(
        _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.critical, [], msg, file: file, function: function, line: line) }
    public static func critical(
        _ cat: Category,
        _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.critical, [cat], msg, file: file, function: function, line: line) }
    public static func critical(
        _ cats: [Category],
        _ msg: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) { custom(.critical, cats, msg, file: file, function: function, line: line) }

    public static func assert(
        _ condition: Bool,
        _ message: @autoclosure () -> String = String(),
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        guard !condition else { return }
        
        let filename: String = URL(fileURLWithPath: "\(file)").lastPathComponent
        let message: String = message()
        let logMessage: String = (message.isEmpty ? "Assertion failed." : message)
        let formattedMessage: String = "[\(filename):\(line) \(function)] \(logMessage)"
        custom(.critical, [], formattedMessage, file: file, function: function, line: line)
        assertionFailure(formattedMessage)
    }
    
    public static func assertOnMainThread(
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        guard !Thread.isMainThread else { return }
        
        let filename: String = URL(fileURLWithPath: "\(file)").lastPathComponent
        let formattedMessage: String = "[\(filename):\(line) \(function)] Must be on main thread."
        custom(.critical, [], formattedMessage, file: file, function: function, line: line)
        assertionFailure(formattedMessage)
    }
    
    public static func custom(
        _ level: Level,
        _ categories: [Category],
        _ message: String,
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        guard
            let logger: Logger = logger.wrappedValue,
            !logger.isSuspended.wrappedValue
        else { return pendingStartupLogs.mutate { $0.append((level, categories, message, file, function, line)) } }
        
        logger.log(level, categories, message, file: file, function: function, line: line)
    }
}

// MARK: - Logger

public class Logger {
    private let dependencies: Dependencies
    private let primaryPrefix: String
    private let forceNSLog: Bool
    private let level: Atomic<Log.Level>
    private let systemLoggers: Atomic<[String: SystemLoggerType]> = Atomic([:])
    fileprivate let fileLogger: DDFileLogger
    fileprivate let isSuspended: Atomic<Bool> = Atomic(true)
    fileprivate let pendingLogsRetriever: Atomic<(() -> [Log.LogInfo])?> = Atomic(nil)
    
    public init(
        primaryPrefix: String,
        level: Log.Level,
        customDirectory: String? = nil,
        forceNSLog: Bool = false,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.primaryPrefix = primaryPrefix
        self.level = Atomic(level)
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
        self.fileLogger.rollingFrequency = (24 * 60 * 60) // Refresh everyday
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
        DispatchQueue.global(qos: .utility).async { [weak self, dependencies] in
            guard let currentLogFileInfo: DDLogFileInfo = self?.fileLogger.currentLogFileInfo else {
                self?.completeResumeLogging(error: "Unable to retrieve current log file.")
                return
            }
            
            // We only want to append extension logs to the main app logs (so just early out if this isn't
            // the main app)
            guard dependencies[singleton: .appContext].isMainApp else {
                self?.completeResumeLogging()
                return
            }
            
            DDLog.loggingQueue.async {
                let extensionInfo: [(dir: String, type: ExtensionType)] = [
                    ("\(FileManager.default.appSharedDataDirectoryPath)/Logs/NotificationExtension", .notification),
                    ("\(FileManager.default.appSharedDataDirectoryPath)/Logs/ShareExtension", .share)
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
                    self?.completeResumeLogging(error: "Unable to write extension logs to current log file due to error: \(error)")
                    return
                }
                
                self?.completeResumeLogging()
            }
        }
    }
    
    private func completeResumeLogging(error: String? = nil) {
        let pendingLogs: [Log.LogInfo] = isSuspended.mutate { isSuspended in
            isSuspended = false
            
            // Retrieve any logs that were added during
            return pendingLogsRetriever.mutate { retriever in (retriever?() ?? []) }
        }
        
        // If we had an error loading the extension logs then actually log it
        if let error: String = error {
            Log.empty()
            log(.error, [], error, file: #file, function: #function, line: #line)
        }
        
        // After creating a new logger we want to log two empty lines to make it easier to read
        Log.empty()
        Log.empty()
        
        // Add any logs that were pending during the startup process
        pendingLogs.forEach { level, categories, message, file, function, line in
            log(level, categories, message, file: file, function: function, line: line)
        }
    }
    
    fileprivate func log(
        _ level: Log.Level,
        _ categories: [Log.Category],
        _ message: String,
        file: StaticString,
        function: StaticString,
        line: UInt
    ) {
        guard level >= self.level.wrappedValue else { return }
        
        // Sort out the prefixes
        let logPrefix: String = {
            let prefixes: String = [
                primaryPrefix,
                (Thread.isMainThread ? "Main" : nil),
                (DispatchQueue.isDBWriteQueue ? "DBWrite" : nil)
            ]
            .compactMap { $0 }
            .appending(contentsOf: categories.map { "\($0.customPrefix)\($0.rawValue)" })
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
            case .off, .default: return
            case .verbose: DDLogVerbose("💙 \(logMessage)", file: file, function: function, line: line)
            case .debug: DDLogDebug("💚 \(logMessage)", file: file, function: function, line: line)
            case .info: DDLogInfo("💛 \(logMessage)", file: file, function: function, line: line)
            case .warn: DDLogWarn("🧡 \(logMessage)", file: file, function: function, line: line)
            case .error: DDLogError("❤️ \(logMessage)", file: file, function: function, line: line)
            case .critical: DDLogError("🔥 \(logMessage)", file: file, function: function, line: line)
        }
        
        let mainCategory: String = (categories.first?.rawValue ?? "General")
        var systemLogger: SystemLoggerType? = systemLoggers.wrappedValue[mainCategory]
        
        if systemLogger == nil {
            systemLogger = systemLoggers.mutate {
                $0[mainCategory] = SystemLogger(category: mainCategory)
                return $0[mainCategory]
            }
        }
        
        #if DEBUG
        systemLogger?.log(level, logMessage)
        #endif
    }
}

// MARK: - SystemLogger

private protocol SystemLoggerType {
    func log(_ level: Log.Level, _ log: String)
}

private class SystemLogger: SystemLoggerType {
    private static let subsystem: String = Bundle.main.bundleIdentifier!
    private let logger: os.Logger
    
    init(category: String) {
        logger = os.Logger(subsystem: SystemLogger.subsystem, category: category)
    }
    
    public func log(_ level: Log.Level, _ log: String) {
        switch level {
            case .off, .default: return
            case .verbose: logger.trace("\(log)")
            case .debug: logger.debug("\(log)")
            case .info: logger.info("\(log)")
            case .warn: logger.warning("\(log)")
            case .error: logger.error("\(log)")
            case .critical: logger.critical("\(log)")
        }
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

// MARK: - Log.Level FeatureOption

extension Log.Level: FeatureOption {
    // MARK: - Initialization
    
    public var rawValue: Int {
        switch self {
            case .verbose: return 1
            case .debug: return 2
            case .info: return 3
            case .warn: return 4
            case .error: return 5
            case .critical: return 6
            case .off: return -1        // `0` is a protected value so can't use it
            case .default: return -2    // `0` is a protected value so can't use it
        }
    }
    
    public init?(rawValue: Int) {
        switch rawValue {
            case -2: self = .default    // `0` is a protected value so can't use it
            case 1: self = .verbose
            case 2: self = .debug
            case 3: self = .info
            case 4: self = .warn
            case 5: self = .error
            case 6: self = .critical
            default: self = .off
        }
    }
    
    // MARK: - Feature Option
    
    public static var defaultOption: Log.Level = .off
    
    public var title: String {
        switch self {
            case .verbose: return "Verbose"
            case .debug: return "Debug"
            case .info: return "Info"
            case .warn: return "Warning"
            case .error: return "Error"
            case .critical: return "Critical"
            case .off: return "Off"
            case .default: return "Default"
        }
    }
    
    public var subtitle: String? {
        switch self {
            case .verbose: return "Show all logging."
            case .debug, .info, .warn, .error: return "Show logs classed as \(title) or higher."
            case .critical: return "Show logs classes as Critical."
            case .off: return "Show no logs."
            case .default: return "Use the default logging level."
        }
    }
}

// MARK: - AllLoggingCategories

public struct AllLoggingCategories: FeatureOption {
    public static let allCases: [AllLoggingCategories] = []
    private static let registeredCategoryDefaults: Atomic<Set<Log.Category>> = Atomic([])
    
    // MARK: - Initialization

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = -1      // `0` is a protected value so can't use it
    }
    
    fileprivate static func register(category: Log.Category) {
        guard
            !registeredCategoryDefaults.wrappedValue.contains(where: { cat in
                /// **Note:** We only want to use the `rawValue` to distinguish between logging categories
                /// as the `defaultLevel` can change via the dev settings and any additional metadata could
                /// be file/class specific
                category.rawValue == cat.rawValue
            })
        else { return }
        
        registeredCategoryDefaults.mutate { $0.insert(category) }
    }
    
    public func currentValues(using dependencies: Dependencies) -> [Log.Category: Log.Level] {
        return AllLoggingCategories.registeredCategoryDefaults.wrappedValue
            .reduce(into: [:]) { result, cat in
                guard cat != Log.Category.default else { return }
                
                result[cat] = dependencies[feature: .logLevel(cat: cat)]
            }
    }
    
    // MARK: - Feature Option
    
    public static var defaultOption: AllLoggingCategories = AllLoggingCategories(rawValue: -1)
    
    public var title: String = "AllLoggingCategories"
    public let subtitle: String? = nil
}

// FIXME: Remove this once everything has been updated to use the new `Log.x()` methods.
public func SNLog(_ message: String, forceNSLog: Bool = false) {
    Log.info(message)
}
