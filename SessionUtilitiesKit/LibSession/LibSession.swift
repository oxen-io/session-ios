// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil

// MARK: - LibSession

public enum LibSession {
    public static var version: String { String(cString: LIBSESSION_UTIL_VERSION_STR) }
}

// MARK: - Log.Category

public extension Log.Category {
    static let libSession: Log.Category = .create("LibSession", defaultLevel: .info)
}

// MARK: - Logging

extension LibSession {
    public static func setupLogger(using dependencies: Dependencies) {
        /// Setup any custom category default log levels for libSession
        Log.Category.create("config", defaultLevel: .info)
        Log.Category.create("network", defaultLevel: .info)
        
        /// Subscribe for log level changes (this wil' emit an initial event which we can use to set the default log level)
        dependencies.publisher(featureGroupChanges: .allLogLevels)
            .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
            .receive(on: DispatchQueue.main, using: dependencies)
            .sinkUntilComplete(
                receiveValue: {
                    let currentLogLevels: [Log.Category: Log.Level] = dependencies[feature: .allLogLevels]
                        .currentValues(using: dependencies)
                    let cDefaultLevel: LOG_LEVEL = (currentLogLevels[.default]?.libSession ?? LOG_LEVEL_OFF)
                    session_logger_set_level_default(cDefaultLevel)
                    session_logger_reset_level(cDefaultLevel)
                    
                    /// Update all explicit log levels (we don't want to register a listener for each individual one so just re-apply all)
                    ///
                    /// If the conversation to the libSession `LOG_LEVEL` fails then it means we should use the default log level
                    currentLogLevels.forEach { (category: Log.Category, level: Log.Level) in
                        guard
                            let cCat: [CChar] = category.rawValue.cString(using: .utf8),
                            let cLogLevel: LOG_LEVEL = level.libSession
                        else { return }
                        
                        session_logger_set_level(cCat, cLogLevel)
                    }
                }
            )
        
        /// Finally register the actual logger callback
        session_add_logger_full({ msgPtr, msgLen, catPtr, catLen, lvl in
            guard
                let msg: String = String(pointer: msgPtr, length: msgLen, encoding: .utf8),
                let cat: String = String(pointer: catPtr, length: catLen, encoding: .utf8)
            else { return }
            
            /// Dispatch to another thread so we don't block thread triggering the log
            DispatchQueue.global(qos: .background).async {
                /// Logs from libSession come through in the format:
                /// `[yyyy-MM-dd hh:mm:ss] [+{lifetime}s] [{cat}:{lvl}|log.hpp:{line}] {message}`
                /// We want to remove the extra data because it doesn't help the logs
                let processedMessage: String = {
                    let logParts: [String] = msg.components(separatedBy: "] ")
                    
                    guard logParts.count == 4 else { return msg.trimmingCharacters(in: .whitespacesAndNewlines) }
                    
                    let message: String = String(logParts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    return "\(logParts[1])] \(message)"
                }()
                
                Log.custom(
                    Log.Level(lvl),
                    [Log.Category(rawValue: cat, customPrefix: "libSession:")],
                    processedMessage
                )
            }
        })
    }
    
    public static func clearLoggers() {
        session_clear_loggers()
    }
}

// MARK: - Convenience

fileprivate extension Log.Level {
    var libSession: LOG_LEVEL? {
        switch self {
            case .verbose: return LOG_LEVEL_TRACE
            case .debug: return LOG_LEVEL_DEBUG
            case .info: return LOG_LEVEL_INFO
            case .warn: return LOG_LEVEL_WARN
            case .error: return LOG_LEVEL_ERROR
            case .critical: return LOG_LEVEL_CRITICAL
            case .off: return LOG_LEVEL_OFF
            case .default: return nil   // It'll use the default value by default so just return nil
        }
    }
    
    init(_ level: LOG_LEVEL) {
        switch level {
            case LOG_LEVEL_TRACE: self = .verbose
            case LOG_LEVEL_DEBUG: self = .debug
            case LOG_LEVEL_INFO: self = .info
            case LOG_LEVEL_WARN: self = .warn
            case LOG_LEVEL_ERROR: self = .error
            case LOG_LEVEL_CRITICAL: self = .critical
            default: self = .off
        }
    }
}
