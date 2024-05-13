// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit
import SignalUtilitiesKit
import SignalCoreKit
import SessionMessagingKit

public class AppEnvironment {
    
    enum ExtensionType {
        case share
        case notification
        
        var name: String {
            switch self {
                case .share: return "ShareExtension"
                case .notification: return "NotificationExtension"
            }
        }
    }

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

    public var callManager: SessionCallManager
    public var notificationPresenter: NotificationPresenter
    public var pushRegistrationManager: PushRegistrationManager
    public var fileLogger: DDFileLogger

    // Stored properties cannot be marked as `@available`, only classes and functions.
    // Instead, store a private `Any` and wrap it with a public `@available` getter
    private var _userNotificationActionHandler: Any?

    public var userNotificationActionHandler: UserNotificationActionHandler {
        return _userNotificationActionHandler as! UserNotificationActionHandler
    }

    private init() {
        self.callManager = SessionCallManager()
        self.notificationPresenter = NotificationPresenter()
        self.pushRegistrationManager = PushRegistrationManager()
        self._userNotificationActionHandler = UserNotificationActionHandler()
        self.fileLogger = DDFileLogger()
        
        SwiftSingletons.register(self)
    }

    public func setup() {
        // Hang certain singletons on Environment too.
        SessionEnvironment.shared?.callManager.mutate {
            $0 = callManager
        }
        SessionEnvironment.shared?.notificationsManager.mutate {
            $0 = notificationPresenter
        }
        setupLogFiles()
    }
    
    private func setupLogFiles() {
        fileLogger.rollingFrequency = kDayInterval // Refresh everyday
        fileLogger.logFileManager.maximumNumberOfLogFiles = 3 // Save 3 days' log files
        DDLog.add(fileLogger)
        
        // The extensions write their logs to the app shared directory but the main app writes
        // to a local directory (so they can be exported via XCode) - the below code reads any
        // logs from the shared directly and attempts to add them to the main app logs to make
        // debugging user issues in extensions easier
        DispatchQueue.global(qos: .utility).async { [fileLogger] in
            guard let currentLogFileInfo: DDLogFileInfo = fileLogger.currentLogFileInfo else {
                return SNLog("Unable to retrieve current log file.")
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
                catch { SNLog("Unable to write extension logs to current log file") }
            }
        }
    }
}
