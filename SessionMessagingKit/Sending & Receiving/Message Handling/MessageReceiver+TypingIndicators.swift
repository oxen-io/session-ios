// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func handleTypingIndicator(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: TypingIndicator,
        using dependencies: Dependencies
    ) throws {
        guard try SessionThread.exists(db, id: threadId) else { return }
        
        switch message.kind {
            case .started:
                let currentUserSessionId: SessionId = dependencies[cache: .general].sessionId
                let threadIsBlocked: Bool = (
                    threadVariant == .contact &&
                    (try? Contact
                        .filter(id: threadId)
                        .select(.isBlocked)
                        .asRequest(of: Bool.self)
                        .fetchOne(db))
                        .defaulting(to: false)
                )
                let threadIsMessageRequest: Bool = (try? SessionThread
                    .filter(id: threadId)
                    .filter(SessionThread.isMessageRequest(
                        userSessionId: currentUserSessionId,
                        includeNonVisible: true
                    ))
                    .isEmpty(db))
                    .defaulting(to: false)
                let needsToStartTypingIndicator: Bool = dependencies[singleton: .typingIndicators].didStartTypingNeedsToStart(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    threadIsBlocked: threadIsBlocked,
                    threadIsMessageRequest: threadIsMessageRequest,
                    direction: .incoming,
                    timestampMs: message.sentTimestampMs.map { Int64($0) }
                )
                
                if needsToStartTypingIndicator {
                    dependencies[singleton: .typingIndicators].start(db, threadId: threadId, direction: .incoming)
                }
                
            case .stopped:
                dependencies[singleton: .typingIndicators].didStopTyping(db, threadId: threadId, direction: .incoming)
            
            default:
                SNLog("Unknown TypingIndicator Kind ignored")
                return
        }
    }
}
