// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum LibSessionError: Error, CustomStringConvertible {
    case unableToCreateConfigObject
    case invalidConfigObject
    case userDoesNotExist
    case getOrConstructFailedUnexpectedly
    case processingLoopLimitReached
    case failedToRetrieveConfigData
    
    case failedToRekeyGroup
    case failedToKeySupplementGroup
    case failedToMakeSubAccountInGroup
    
    case libSessionError(String)
    
    public var description: String {
        switch self {
            case .unableToCreateConfigObject: return "Unable to create config object."
            case .invalidConfigObject: return "Invalid config object."
            case .userDoesNotExist: return "User does not exist."
            case .getOrConstructFailedUnexpectedly: return "'getOrConstruct' failed unexpectedly."
            case .processingLoopLimitReached: return "Processing loop limit reached."
            case .failedToRetrieveConfigData: return "Failed to retrieve config data."
            
            case .failedToRekeyGroup: return "Failed to rekey group."
            case .failedToKeySupplementGroup: return "Failed to key supplement group."
            case .failedToMakeSubAccountInGroup: return "Failed to make subaccount in group."
            
            case .libSessionError(let error): return "\(error)\(error.hasSuffix(".") ? "" : ".")"
        }
    }
}
