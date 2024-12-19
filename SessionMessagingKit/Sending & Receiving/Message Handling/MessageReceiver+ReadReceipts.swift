// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

extension MessageReceiver {
    internal static func handleReadReceipt(
        _ db: Database,
        message: ReadReceipt,
        serverExpirationTimestamp: TimeInterval?
    ) throws {
        guard let sender: String = message.sender else { return }
        guard let timestampMsValues: [Int64] = message.timestamps?.map({ Int64($0) }) else { return }
        guard let readTimestampMs: Int64 = message.receivedTimestampMs.map({ Int64($0) }) else { return }
        
        let pendingTimestampMs: Set<Int64> = try Interaction.markAsRecipientRead(
            db,
            threadId: sender,
            timestampMsValues: timestampMsValues,
            readTimestampMs: readTimestampMs
        )
        
        guard !pendingTimestampMs.isEmpty else { return }
        
        // We have some pending read receipts so store them in the database
        try pendingTimestampMs.forEach { timestampMs in
            try PendingReadReceipt(
                threadId: sender,
                interactionTimestampMs: timestampMs,
                readTimestampMs: readTimestampMs,
                serverExpirationTimestamp: (serverExpirationTimestamp ?? 0)
            ).upsert(db)
        }
    }
}
