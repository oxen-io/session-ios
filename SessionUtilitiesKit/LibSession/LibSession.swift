// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SignalCoreKit

// MARK: - LibSession

public enum LibSession {
    private static let logLevels: [LogCategory: LOG_LEVEL] = [
        .config: LOG_LEVEL_INFO,
        .network: LOG_LEVEL_INFO,
        .manual: LOG_LEVEL_INFO,
    ]
    
    public static var version: String { String(cString: LIBSESSION_UTIL_VERSION_STR) }
}

// MARK: - Logging

extension LibSession {
    public static func addLogger() {
        /// Set the default log level first (unless specified we only care about semi-dangerous logs)
        session_logger_set_level_default(LOG_LEVEL_WARN)
        
        /// Then set any explicit category log levels we have
        logLevels.forEach { cat, level in
            guard let cCat: [CChar] = cat.rawValue.cString(using: .utf8) else { return }
            
            session_logger_set_level(cCat, level)
        }
        
        /// Finally register the actual logger callback
        session_add_logger_full({ msgPtr, msgLen, catPtr, catLen, lvl in
            guard
                let msg: String = String(pointer: msgPtr, length: msgLen, encoding: .utf8),
                let cat: String = String(pointer: catPtr, length: catLen, encoding: .utf8)
            else { return }
            
            /// Logs from libSession come through in the format:
            /// `[yyyy-MM-dd hh:mm:ss] [+{lifetime}s] [{cat}:{lvl}|log.hpp:{line}] {message}`
            /// We want to remove the extra data because it doesn't help the logs
            let processedMessage: String = {
                let logParts: [String] = msg.components(separatedBy: "] ")
                
                guard logParts.count == 4 else { return msg.trimmingCharacters(in: .whitespacesAndNewlines) }
                
                let message: String = String(logParts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
                
                return "[libSession:\(cat)] \(logParts[1])] \(message)"
            }()
            
            Log.custom(
                Log.Level(lvl),
                processedMessage,
                withPrefixes: true,
                silenceForTests: false
            )
        })
    }
    
    // MARK: - Internal
    
    fileprivate enum LogCategory: String {
        case config
        case network
        case quic
        case manual
        
        init?(_ catPtr: UnsafePointer<CChar>?, _ catLen: Int) {
            switch String(pointer: catPtr, length: catLen, encoding: .utf8).map({ LogCategory(rawValue: $0) }) {
                case .some(let cat): self = cat
                case .none: return nil
            }
        }
    }
}

// MARK: - Convenience

fileprivate extension Log.Level {
    init(_ level: LOG_LEVEL) {
        switch level {
            case LOG_LEVEL_TRACE: self = .trace
            case LOG_LEVEL_DEBUG: self = .debug
            case LOG_LEVEL_INFO: self = .info
            case LOG_LEVEL_WARN: self = .warn
            case LOG_LEVEL_ERROR: self = .error
            case LOG_LEVEL_CRITICAL: self = .critical
            default: self = .off
        }
    }
}
