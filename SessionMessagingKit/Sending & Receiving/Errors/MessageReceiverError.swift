// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum MessageReceiverError: LocalizedError {
    case duplicateMessage
    case duplicateMessageNewSnode
    case duplicateControlMessage
    case invalidMessage
    case unknownMessage
    case unknownEnvelopeType
    case noUserX25519KeyPair
    case noUserED25519KeyPair
    case invalidSignature
    case noData
    case senderBlocked
    case noThread
    case selfSend
    case decryptionFailed
    case noGroupKeyPair
    case invalidConfigMessageHandling
    case requiredThreadNotInConfig
    case outdatedMessage

    public var isRetryable: Bool {
        switch self {
            case .duplicateMessage, .duplicateMessageNewSnode, .duplicateControlMessage,
                .invalidMessage, .unknownMessage, .unknownEnvelopeType, .invalidSignature,
                .noData, .senderBlocked, .noThread, .selfSend, .decryptionFailed,
                .invalidConfigMessageHandling, .requiredThreadNotInConfig, .outdatedMessage:
                return false
                
            default: return true
        }
    }
    
    public var shouldUpdateLastHash: Bool {
        switch self {
            // If we get one of these errors then we still want to update the last hash to prevent
            // retrieving and attempting to process the same messages again (as well as ensure the
            // next poll doesn't retrieve the same message - these errors are essentially considered
            // "already successfully processed")
            case .selfSend, .duplicateControlMessage, .outdatedMessage:
                return true
                
            default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
            case .duplicateMessage: return "Duplicate message."
            case .duplicateMessageNewSnode: return "Duplicate message from different service node."
            case .duplicateControlMessage: return "Duplicate control message."
            case .invalidMessage: return "Invalid message."
            case .unknownMessage: return "Unknown message type."
            case .unknownEnvelopeType: return "Unknown envelope type."
            case .noUserX25519KeyPair: return "Couldn't find user X25519 key pair."
            case .noUserED25519KeyPair: return "Couldn't find user ED25519 key pair."
            case .invalidSignature: return "Invalid message signature."
            case .noData: return "Received an empty envelope."
            case .senderBlocked: return "Received a message from a blocked user."
            case .noThread: return "Couldn't find thread for message."
            case .selfSend: return "Message addressed at self."
            case .decryptionFailed: return "Decryption failed."
            
            // Shared sender keys
            case .noGroupKeyPair: return "Missing group key pair."
                
            case .invalidConfigMessageHandling: return "Invalid handling of a config message."
            case .requiredThreadNotInConfig: return "Required thread not in config."
            case .outdatedMessage: return "Message was sent before a config change which would have removed the message."
        }
    }
}
