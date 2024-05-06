// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum SnodeAPIError: Error, CustomStringConvertible {
    case generic
    case clockOutOfSync
    case snodePoolUpdatingFailed
    case inconsistentSnodePools
    case noKeyPair
    case signingFailed
    case signatureVerificationFailed
    case invalidAuthentication
    case invalidIP
    case emptySnodePool
    case responseFailedValidation
    case unauthorised
    case ranOutOfRandomSnodes(Error?)
    
    // ONS
    case decryptionFailed
    case hashingFailed
    case validationFailed

    public var description: String {
        switch self {
            case .generic: return "An error occurred (SnodeAPIError.generic)."
            case .clockOutOfSync: return "Your clock is out of sync with the Service Node network. Please check that your device's clock is set to automatic time (SnodeAPIError.clockOutOfSync)."
            case .snodePoolUpdatingFailed: return "Failed to update the Service Node pool (SnodeAPIError.snodePoolUpdatingFailed)."
            case .inconsistentSnodePools: return "Received inconsistent Service Node pool information from the Service Node network (SnodeAPIError.inconsistentSnodePools)."
            case .noKeyPair: return "Missing user key pair (SnodeAPIError.noKeyPair)."
            case .signingFailed: return "Couldn't sign message (SnodeAPIError.signingFailed)."
            case .signatureVerificationFailed: return "Failed to verify the signature (SnodeAPIError.signatureVerificationFailed)."
            case .invalidAuthentication: return "Invalid Authentication (SnodeAPIError.invalidAuthentication)."
            case .invalidIP: return "Invalid IP (SnodeAPIError.invalidIP)."
            case .emptySnodePool: return "Service Node pool is empty (SnodeAPIError.emptySnodePool)."
            case .responseFailedValidation: return "Response failed validation (SnodeAPIError.responseFailedValidation)."
            case .unauthorised: return "Unauthorized (SnodeAPIError.unauthorised)."
            case .ranOutOfRandomSnodes(let maybeError):
                switch maybeError {
                    case .none: return "Ran out of random snodes (SnodeAPIError.ranOutOfRandomSnodes(nil))."
                    case .some(let error):
                        let errorDesc = "\(error)".trimmingCharacters(in: CharacterSet(["."]))
                        return "Ran out of random snodes (SnodeAPIError.ranOutOfRandomSnodes(\(errorDesc))."
                }
                
            // ONS
            case .decryptionFailed: return "Couldn't decrypt ONS name (SnodeAPIError.decryptionFailed)."
            case .hashingFailed: return "Couldn't compute ONS name hash (SnodeAPIError.hashingFailed)."
            case .validationFailed: return "ONS name validation failed (SnodeAPIError.validationFailed)."
        }
    }
}
