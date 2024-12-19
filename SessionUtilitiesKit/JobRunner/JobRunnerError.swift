// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum JobRunnerError: Error, CustomStringConvertible {
    case executorMissing
    case jobIdMissing
    case requiredThreadIdMissing
    case requiredInteractionIdMissing
    
    case missingRequiredDetails
    case missingDependencies
    
    case possibleDuplicateJob
    case possibleDeferralLoop
    
    var wasPossibleDeferralLoop: Bool {
        switch self {
            case .possibleDeferralLoop: return true
            default: return false
        }
    }
    
    public var description: String {
        switch self {
            case .executorMissing: return "The job executor was missing."
            case .jobIdMissing: return "The job had no id."
            case .requiredThreadIdMissing: return "A threadId was required but not present."
            case .requiredInteractionIdMissing: return "An interactionId was required but not present."
            
            case .missingRequiredDetails: return "The job had required details which were missing."
            case .missingDependencies: return "The job had missing dependencies."
            
            case .possibleDuplicateJob: return "This job might be the duplicate of another running job."
            case .possibleDeferralLoop: return "The job might have been stuck in a deferral loop."
        }
    }
}
