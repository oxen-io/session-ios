// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public enum MessageSenderError: Error, CustomStringConvertible, Equatable {
    case invalidMessage
    case protoConversionFailed
    case noUserX25519KeyPair
    case noUserED25519KeyPair
    case signingFailed
    case encryptionFailed
    case noUsername
    case attachmentsNotUploaded
    case blindingFailed
    
    // Closed groups
    case noThread
    case noKeyPair
    case invalidClosedGroupUpdate
    case invalidConfigMessageHandling
    
    case other(Log.Category?, String, Error)

    internal var isRetryable: Bool {
        switch self {
            case .invalidMessage, .protoConversionFailed, .invalidClosedGroupUpdate,
                .signingFailed, .encryptionFailed, .blindingFailed:
                return false
                
            default: return true
        }
    }
    
    public var description: String {
        switch self {
            case .invalidMessage: return "Invalid message (MessageSenderError.invalidMessage)."
            case .protoConversionFailed: return "Couldn't convert message to proto (MessageSenderError.protoConversionFailed)."
            case .noUserX25519KeyPair: return "Couldn't find user X25519 key pair (MessageSenderError.noUserX25519KeyPair)."
            case .noUserED25519KeyPair: return "Couldn't find user ED25519 key pair (MessageSenderError.noUserED25519KeyPair)."
            case .signingFailed: return "Couldn't sign message (MessageSenderError.signingFailed)."
            case .encryptionFailed: return "Couldn't encrypt message (MessageSenderError.encryptionFailed)."
            case .noUsername: return "Missing username (MessageSenderError.noUsername)."
            case .attachmentsNotUploaded: return "Attachments for this message have not been uploaded (MessageSenderError.attachmentsNotUploaded)."
            case .blindingFailed: return "Couldn't blind the sender (MessageSenderError.blindingFailed)."
            
            // Closed groups
            case .noThread: return "Couldn't find a thread associated with the given group public key (MessageSenderError.noThread)."
            case .noKeyPair: return "Couldn't find a private key associated with the given group public key (MessageSenderError.noKeyPair)."
            case .invalidClosedGroupUpdate: return "Invalid group update (MessageSenderError.invalidClosedGroupUpdate)."
            case .invalidConfigMessageHandling: return "Invalid handling of a config message (MessageSenderError.invalidConfigMessageHandling)."
            case .other(_, _, let error): return "\(error)"
        }
    }
    
    public static func == (lhs: MessageSenderError, rhs: MessageSenderError) -> Bool {
        switch (lhs, rhs) {
            case (.invalidMessage, .invalidMessage): return true
            case (.protoConversionFailed, .protoConversionFailed): return true
            case (.noUserX25519KeyPair, .noUserX25519KeyPair): return true
            case (.noUserED25519KeyPair, .noUserED25519KeyPair): return true
            case (.signingFailed, .signingFailed): return true
            case (.encryptionFailed, .encryptionFailed): return true
            case (.noUsername, .noUsername): return true
            case (.attachmentsNotUploaded, .attachmentsNotUploaded): return true
            case (.noThread, .noThread): return true
            case (.noKeyPair, .noKeyPair): return true
            case (.invalidClosedGroupUpdate, .invalidClosedGroupUpdate): return true
            case (.blindingFailed, .blindingFailed): return true
            
            case (.other(_, let lhsDescription, let lhsError), .other(_, let rhsDescription, let rhsError)):
                // Not ideal but the best we can do
                return (
                    lhsDescription == rhsDescription &&
                    "\(lhsError)" == "\(rhsError)"
                )
                
            default: return false
        }
    }
}
