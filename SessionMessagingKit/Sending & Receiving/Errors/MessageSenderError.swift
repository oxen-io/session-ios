// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum MessageSenderError: LocalizedError, Equatable {
    case invalidMessage
    case protoConversionFailed
    case noUserX25519KeyPair
    case noUserED25519KeyPair
    case signingFailed
    case encryptionFailed
    case noUsername
    case attachmentsNotUploaded
    case blindingFailed
    case sendJobTimeout
    
    // Closed groups
    case noThread
    case noKeyPair
    case invalidClosedGroupUpdate
    case invalidConfigMessageHandling
    
    case other(String, Error)

    internal var isRetryable: Bool {
        switch self {
            case .invalidMessage, .protoConversionFailed, .invalidClosedGroupUpdate,
                .signingFailed, .encryptionFailed, .blindingFailed:
                return false
                
            default: return true
        }
    }
    
    public var errorDescription: String? {
        switch self {
            case .invalidMessage: return "Invalid message."
            case .protoConversionFailed: return "Couldn't convert message to proto."
            case .noUserX25519KeyPair: return "Couldn't find user X25519 key pair."
            case .noUserED25519KeyPair: return "Couldn't find user ED25519 key pair."
            case .signingFailed: return "Couldn't sign message."
            case .encryptionFailed: return "Couldn't encrypt message."
            case .noUsername: return "Missing username."
            case .attachmentsNotUploaded: return "Attachments for this message have not been uploaded."
            case .blindingFailed: return "Couldn't blind the sender"
            case .sendJobTimeout: return "Send job timeout (likely due to path building taking too long)."
            
            // Closed groups
            case .noThread: return "Couldn't find a thread associated with the given group public key."
            case .noKeyPair: return "Couldn't find a private key associated with the given group public key."
            case .invalidClosedGroupUpdate: return "Invalid group update."
            case .invalidConfigMessageHandling: return "Invalid handling of a config message."
            case .other(_, let error): return error.localizedDescription
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
            case (.sendJobTimeout, .sendJobTimeout): return true
            
            case (.other(let lhsDescription, let lhsError), .other(let rhsDescription, let rhsError)):
                // Not ideal but the best we can do
                return (
                    lhsDescription == rhsDescription &&
                    lhsError.localizedDescription == rhsError.localizedDescription
                )
                
            default: return false
        }
    }
}
