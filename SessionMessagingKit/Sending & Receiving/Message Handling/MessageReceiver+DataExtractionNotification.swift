// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func handleDataExtractionNotification(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: DataExtractionNotification,
        serverExpirationTimestamp: TimeInterval?
    ) throws {
        guard
            threadVariant == .contact,
            let sender: String = message.sender,
            let messageKind: DataExtractionNotification.Kind = message.kind
        else { throw MessageReceiverError.invalidMessage }
        
        let timestampMs: Int64 = (
            message.sentTimestamp.map { Int64($0) } ??
            SnodeAPI.currentOffsetTimestampMs()
        )
        
        let wasRead: Bool = LibSession.timestampAlreadyRead(
            threadId: threadId,
            threadVariant: threadVariant,
            timestampMs: (timestampMs * 1000),
            userPublicKey: getUserHexEncodedPublicKey(db),
            openGroup: nil
        )
        let messageExpirationInfo: Message.MessageExpirationInfo = Message.getMessageExpirationInfo(
            wasRead: wasRead,
            serverExpirationTimestamp: serverExpirationTimestamp,
            expiresInSeconds: message.expiresInSeconds,
            expiresStartedAtMs: message.expiresStartedAtMs
        )
        _ = try Interaction(
            serverHash: message.serverHash,
            threadId: threadId,
            authorId: sender,
            variant: {
                switch messageKind {
                    case .screenshot: return .infoScreenshotNotification
                    case .mediaSaved: return .infoMediaSavedNotification
                }
            }(),
            timestampMs: timestampMs,
            wasRead: wasRead,
            expiresInSeconds: messageExpirationInfo.expiresInSeconds,
            expiresStartedAtMs: messageExpirationInfo.expiresStartedAtMs
        )
        .inserted(db)
        
        if messageExpirationInfo.shouldUpdateExpiry {
            Message.updateExpiryForDisappearAfterReadMessages(
                db,
                threadId: threadId,
                serverHash: message.serverHash,
                expiresInSeconds: messageExpirationInfo.expiresInSeconds,
                expiresStartedAtMs: messageExpirationInfo.expiresStartedAtMs
            )
        }
    }
}
