// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum OpenGroupAPIError: Error, CustomStringConvertible {
    case decryptionFailed
    case signingFailed
    case noPublicKey
    case invalidEmoji
    case invalidPoll
    
    public var description: String {
        switch self {
            case .decryptionFailed: return "Couldn't decrypt response."
            case .signingFailed: return "Couldn't sign message."
            case .noPublicKey: return "Couldn't find server public key."
            case .invalidEmoji: return "The emoji is invalid."
            case .invalidPoll: return "Poller in invalid state."
        }
    }
}
