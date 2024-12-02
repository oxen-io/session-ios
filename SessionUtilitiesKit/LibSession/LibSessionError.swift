// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil

public enum LibSessionError: Error, CustomStringConvertible {
    case unableToCreateConfigObject
    case invalidConfigObject
    case invalidDataProvided
    case userDoesNotExist
    case getOrConstructFailedUnexpectedly
    case processingLoopLimitReached
    case failedToRetrieveConfigData
    case failedToRekeyGroup
    case failedToKeySupplementGroup
    case failedToMakeSubAccountInGroup
    case invalidCConversion
    case unableToGeneratePushData
    case attemptedToModifyGroupWithoutAdminKey
    
    case libSessionError(String)
    
    public init(_ cError: [CChar]) {
        self = LibSessionError.libSessionError(String(cString: cError))
    }
    
    public init(_ errorString: String) {
        switch errorString {
            default: self = LibSessionError.libSessionError(errorString)
        }
    }
    
    // MARK: - Config
    
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
    
    // MARK: - GroupKeys
    
    public init?(_ conf: UnsafeMutablePointer<config_group_keys>?) {
        guard let lastErrorPtr: UnsafePointer<CChar> = conf?.pointee.last_error else { return nil }

        let errorString = String(cString: lastErrorPtr)
        conf?.pointee.last_error = nil // Clear the last error so subsequent calls don't get confused
        self = LibSessionError.libSessionError(errorString)
    }
    
    public init(
        _ conf: UnsafeMutablePointer<config_group_keys>?,
        fallbackError: LibSessionError,
        logMessage: String? = nil
    ) {
        self = (LibSessionError(conf) ?? fallbackError)

        if let logMessage: String = logMessage {
            Log.error(.libSession, "\(logMessage): \(self)")
        }
    }
    
    public static func throwIfNeeded(
        _ conf: UnsafeMutablePointer<config_group_keys>?,
        beforeThrow: (() -> ())? = nil
    ) throws {
        guard let error: LibSessionError = LibSessionError(conf) else { return }
        
        beforeThrow?()
        throw error
    }
    
    public static func clear(_ conf: UnsafeMutablePointer<config_group_keys>?) {
        conf?.pointee.last_error = nil
    }
    
    public func logging(_ logMessage: String) -> LibSessionError {
        Log.error(.libSession, "\(logMessage): \(self)")
        return self
    }
    
    // MARK: - CustomStringCOnvertible
    
    public var description: String {
        switch self {
            case .unableToCreateConfigObject: return "Unable to create config object (LibSessionError.unableToCreateConfigObject)."
            case .invalidConfigObject: return "Invalid config object (LibSessionError.invalidConfigObject)."
            case .invalidDataProvided: return "Invalid data provided (LibSessionError.invalidDataProvided)."
            case .userDoesNotExist: return "User does not exist (LibSessionError.userDoesNotExist)."
            case .getOrConstructFailedUnexpectedly: return "'getOrConstruct' failed unexpectedly (LibSessionError.getOrConstructFailedUnexpectedly)."
            case .processingLoopLimitReached: return "Processing loop limit reached (LibSessionError.processingLoopLimitReached)."
            case .failedToRetrieveConfigData: return "Failed to retrieve config data (LibSessionError.failedToRetrieveConfigData)."
            case .failedToRekeyGroup: return "Failed to rekey group (LibSessionError.failedToRekeyGroup)."
            case .failedToKeySupplementGroup: return "Failed to key supplement group (LibSessionError.failedToKeySupplementGroup)."
            case .failedToMakeSubAccountInGroup: return "Failed to make subaccount in group (LibSessionError.failedToMakeSubAccountInGroup)."
            case .invalidCConversion: return "Invalid conversation to C type (LibSessionError.invalidCConversion)."
            case .unableToGeneratePushData: return "Unable to generate push data (LibSessionError.unableToGeneratePushData)."
            case .attemptedToModifyGroupWithoutAdminKey:
                return "Attempted to modify group without admin key (LibSessionError.attemptedToModifyGroupWithoutAdminKey)."
            
            case .libSessionError(let error): return "\(error)"
        }
    }
}
