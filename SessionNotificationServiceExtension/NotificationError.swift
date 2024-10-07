// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionMessagingKit

enum NotificationError: Error, CustomStringConvertible {
    case processing(PushNotificationAPI.ProcessResult)
    case ignorableMessage
    case messageHandling(MessageReceiverError)
    case other(Error)
    
    public var description: String {
        switch self {
            case .processing(let result): return "Failed to process notification (\(result)) (NotificationError.processing)."
            case .ignorableMessage: return "Ignorable message (NotificationError.ignorableMessage)."
            case .messageHandling(let error): return "Failed to handle message (\(error)) (NotificationError.messageHandling)."
            case .other(let error): return "Error occurred when processing the notification: \(error) (NotificationError.other)."
        }
    }
}
