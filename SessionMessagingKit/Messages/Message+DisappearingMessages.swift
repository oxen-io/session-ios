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
        expiresStartedAtMs: Double?
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
            
            let nowMs: Double = Double(SnodeAPI.currentOffsetTimestampMs())
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
        expireInSeconds: TimeInterval?
    ) {
        guard
            threadVariant != .community,
            variant == .standardOutgoing,
            let serverHash: String = serverHash,
            let expireInSeconds: TimeInterval = expireInSeconds,
            expireInSeconds > 0
        else { return }
        
        let startedAtTimestampMs: Double = Double(SnodeAPI.currentOffsetTimestampMs())
        
        JobRunner.add(
            db,
            job: Job(
                variant: .getExpiration,
                behaviour: .runOnce,
                threadId: threadId,
                details: GetExpirationJob.Details(
                    expirationInfo: [serverHash: expireInSeconds],
                    startedAtTimestampMs: startedAtTimestampMs
                )
            )
        )
    }
    
    public static func updateExpiryForDisappearAfterReadMessages(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        serverHash: String?,
        expiresInSeconds: TimeInterval?,
        expiresStartedAtMs: Double?
    ) {
        guard
            threadVariant != .community,
            let serverHash: String = serverHash,
            let expiresInSeconds: TimeInterval = expiresInSeconds,
            let expiresStartedAtMs: Double = expiresStartedAtMs
        else { return }
        
        let expirationTimestampMs: Int64 = Int64(expiresStartedAtMs + expiresInSeconds * 1000)
        JobRunner.add(
            db,
            job: Job(
                variant: .expirationUpdate,
                behaviour: .runOnce,
                threadId: threadId,
                details: ExpirationUpdateJob.Details(
                    serverHashes: [serverHash],
                    expirationTimestampMs: expirationTimestampMs
                )
            )
        )
    }
}
