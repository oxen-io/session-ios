// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUIKit
import SessionUtilitiesKit

extension Message {
    public struct MessageExpirationInfo {
        let expiresStartedAtMs: Double?
        let expiresInSeconds: TimeInterval?
        let shouldUpdateExpiry: Bool
    }
    
    public static func getMessageExpirationInfo(
        threadVariant: SessionThread.Variant,
        wasRead: Bool,
        serverExpirationTimestamp: TimeInterval?,
        expiresInSeconds: TimeInterval?,
        expiresStartedAtMs: Double?,
        using dependencies: Dependencies
    ) -> MessageExpirationInfo {
        var shouldUpdateExpiry: Bool = false
        let expiresStartedAtMs: Double? = {
            guard threadVariant != .community else { return nil }
            
            // Disappear after sent
            guard expiresStartedAtMs == nil else {
                return expiresStartedAtMs
            }
            
            // Disappear after read
            guard
                let expiresInSeconds: TimeInterval = expiresInSeconds,
                expiresInSeconds > 0,
                wasRead,
                let serverExpirationTimestamp: TimeInterval = serverExpirationTimestamp
            else {
                return nil
            }
            
            let nowMs: Double = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
            let serverExpirationTimestampMs: Double = serverExpirationTimestamp * 1000
            let expiresInMs: Double = expiresInSeconds * 1000
            
            if serverExpirationTimestampMs <= (nowMs + expiresInMs) {
                // seems to have been shortened already
                return (serverExpirationTimestampMs - expiresInMs)
            } else {
                // consider that message unread
                shouldUpdateExpiry = true
                return (nowMs + expiresInSeconds)
            }
        }()
        
        return MessageExpirationInfo(
            expiresStartedAtMs: expiresStartedAtMs,
            expiresInSeconds: expiresInSeconds,
            shouldUpdateExpiry: shouldUpdateExpiry
        )
    }
    
    public static func getExpirationForOutgoingDisappearingMessages(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        variant: Interaction.Variant,
        serverHash: String?,
        expireInSeconds: TimeInterval?,
        using dependencies: Dependencies
    ) {
        guard
            threadVariant != .community,
            variant == .standardOutgoing,
            let serverHash: String = serverHash,
            let expireInSeconds: TimeInterval = expireInSeconds,
            expireInSeconds > 0
        else { return }
        
        dependencies[singleton: .jobRunner].add(
            db,
            job: Job(
                variant: .getExpiration,
                behaviour: .runOnce,
                threadId: threadId,
                details: GetExpirationJob.Details(
                    expirationInfo: [serverHash: expireInSeconds],
                    startedAtTimestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                )
            ),
            canStartJob: true
        )
    }
    
    public static func updateExpiryForDisappearAfterReadMessages(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        serverHash: String?,
        expiresInSeconds: TimeInterval?,
        expiresStartedAtMs: Double?,
        using dependencies: Dependencies
    ) {
        guard
            threadVariant != .community,
            let serverHash: String = serverHash,
            let expiresInSeconds: TimeInterval = expiresInSeconds,
            let expiresStartedAtMs: Double = expiresStartedAtMs
        else { return }
        
        let expirationTimestampMs: Int64 = Int64(expiresStartedAtMs + expiresInSeconds * 1000)
        
        dependencies[singleton: .jobRunner].add(
            db,
            job: Job(
                variant: .expirationUpdate,
                behaviour: .runOnce,
                threadId: threadId,
                details: ExpirationUpdateJob.Details(
                    serverHashes: [serverHash],
                    expirationTimestampMs: expirationTimestampMs
                )
            ),
            canStartJob: true
        )
    }
}
