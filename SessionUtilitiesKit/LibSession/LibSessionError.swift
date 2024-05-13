// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil

public enum LibSessionError: LocalizedError {
    case unableToCreateConfigObject
    case nilConfigObject
    case userDoesNotExist
    case getOrConstructFailedUnexpectedly
    case processingLoopLimitReached
    
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
    
    public var errorDescription: String? {
        switch self {
            case .unableToCreateConfigObject: return "Unable to create config object."
            case .nilConfigObject: return "Null config object."
            case .userDoesNotExist: return "User does not exist."
            case .getOrConstructFailedUnexpectedly: return "'getOrConstruct' failed unexpectedly."
            case .processingLoopLimitReached: return "Processing loop limit reached."
            
            case .libSessionError(let error): return "\(error)\(error.hasSuffix(".") ? "" : ".")"
            case .unknown: return "An unknown error occurred."
        }
    }
}
