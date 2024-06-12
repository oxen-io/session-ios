// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil

public enum LibSessionError: Error, CustomStringConvertible {
    case unableToCreateConfigObject
    case nilConfigObject
    case userDoesNotExist
    case getOrConstructFailedUnexpectedly
    case processingLoopLimitReached
    case invalidCConversion
    case unableToGeneratePushData
    
    case libSessionError(String)
    case unknown
    
    public init(_ cError: [CChar]) {
        self = LibSessionError.libSessionError(String(cString: cError))
    }
    
    public init(_ errorString: String) {
        switch errorString {
            default: self = LibSessionError.libSessionError(errorString)
        }
    }
    
    public init?(_ conf: UnsafeMutablePointer<config_object>?) {
        guard let lastErrorPtr: UnsafePointer<CChar> = conf?.pointee.last_error else { return nil }

        let errorString = String(cString: lastErrorPtr)
        conf?.pointee.last_error = nil // Clear the last error so subsequent calls don't get confused
        self = LibSessionError.libSessionError(errorString)
    }
    
    public init(
        _ conf: UnsafeMutablePointer<config_object>?,
        fallbackError: LibSessionError,
        logMessage: String? = nil
    ) {
        self = (LibSessionError(conf) ?? fallbackError)

        if let logMessage: String = logMessage {
            Log.error("\(logMessage): \(self)")
        }
    }
    
    public static func throwIfNeeded(
        _ conf: UnsafeMutablePointer<config_object>?,
        beforeThrow: (() -> ())? = nil
    ) throws {
        guard let error: LibSessionError = LibSessionError(conf) else { return }
        
        beforeThrow?()
        throw error
    }
    
    public static func clear(_ conf: UnsafeMutablePointer<config_object>?) {
        conf?.pointee.last_error = nil
    }
    
    public var description: String {
        switch self {
            case .unableToCreateConfigObject: return "Unable to create config object (LibSessionError.unableToCreateConfigObject)."
            case .nilConfigObject: return "Null config object (LibSessionError.nilConfigObject)."
            case .userDoesNotExist: return "User does not exist (LibSessionError.userDoesNotExist)."
            case .getOrConstructFailedUnexpectedly: return "'getOrConstruct' failed unexpectedly (LibSessionError.getOrConstructFailedUnexpectedly)."
            case .processingLoopLimitReached: return "Processing loop limit reached (LibSessionError.processingLoopLimitReached)."
            case .invalidCConversion: return "Invalid conversation to C type (LibSessionError.invalidCConversion)."
            case .unableToGeneratePushData: return "Unable to generate push data (LibSessionError.unableToGeneratePushData)."
            
            case .libSessionError(let error): return "\(error)\(error.hasSuffix(".") ? "" : ".")"
            case .unknown: return "An unknown error occurred (LibSessionError.unknown)."
        }
    }
}
