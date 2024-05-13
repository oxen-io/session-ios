// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionMessagingKit

enum NotificationError: Error, CustomStringConvertible {
    case processing(PushNotificationAPI.ProcessResult)
    case messageProcessing
    case messageHandling(MessageReceiverError)
    
    public var description: String {
        switch self {
            case .processing(let result): return "Failed to process notification (\(result)) (NotificationError.processing)."
            case .messageProcessing: return "Failed to process message (NotificationError.messageProcessing)."
            case .messageHandling(let error): return "Failed to handle message (\(error)) (NotificationError.messageHandling)."
        }
    }
}
