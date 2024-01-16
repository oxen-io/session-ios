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
        using dependencies: Dependencies
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
            wasRead: LibSession.timestampAlreadyRead(
                threadId: threadId,
                threadVariant: threadVariant,
                timestampMs: (timestampMs * 1000),
                userSessionId: getUserSessionId(db, using: dependencies),
                openGroup: nil,
                using: dependencies
            ),
            expiresInSeconds: message.expiresInSeconds,
            expiresStartedAtMs: message.expiresStartedAtMs
        ).inserted(db)
    }
}
