// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

public class TypingIndicators {
    // MARK: - Direction
    
    public enum Direction {
        case outgoing
        case incoming
    }
    
    private class Indicator {
        fileprivate let threadId: String
        fileprivate let threadVariant: SessionThread.Variant
        fileprivate let direction: Direction
        fileprivate let timestampMs: Int64
        
        fileprivate var refreshTimer: Timer?
        fileprivate var stopTimer: Timer?
        
        init?(
            threadId: String,
            threadVariant: SessionThread.Variant,
            threadIsBlocked: Bool,
            threadIsMessageRequest: Bool,
            direction: Direction,
            timestampMs: Int64?,
            using dependencies: Dependencies = Dependencies()
        ) {
            // The `typingIndicatorsEnabled` flag reflects the user-facing setting in the app
            // preferences, if it's disabled we don't want to emit "typing indicator" messages
            // or show typing indicators for other users
            //
            // We also don't want to show/send typing indicators for message requests
            guard
                dependencies[singleton: .storage, key: .typingIndicatorsEnabled] &&
                !threadIsBlocked &&
                !threadIsMessageRequest
            else { return nil }
            
            // Don't send typing indicators in group threads
            guard
                threadVariant != .legacyGroup &&
                threadVariant != .group &&
                threadVariant != .community
            else { return nil }
            
            self.threadId = threadId
            self.threadVariant = threadVariant
            self.direction = direction
            self.timestampMs = (timestampMs ?? SnodeAPI.currentOffsetTimestampMs())
        }
        
        fileprivate func start(_ db: Database, using dependencies: Dependencies = Dependencies()) {
            // Start the typing indicator
            switch direction {
                case .outgoing:
                    scheduleRefreshCallback(db, shouldSend: (refreshTimer == nil), using: dependencies)
                    
                case .incoming:
                    try? ThreadTypingIndicator(
                        threadId: threadId,
                        timestampMs: timestampMs
                    )
                    .upsert(db)
            }
            
            // Refresh the timeout since we just started
            refreshTimeout(using: dependencies)
        }
        
        fileprivate func stop(_ db: Database, using dependencies: Dependencies = Dependencies()) {
            self.refreshTimer?.invalidate()
            self.refreshTimer = nil
            self.stopTimer?.invalidate()
            self.stopTimer = nil
            
            switch direction {
                case .outgoing:
                    try? MessageSender.send(
                        db,
                        message: TypingIndicator(kind: .stopped),
                        interactionId: nil,
                        threadId: threadId,
                        threadVariant: threadVariant,
                        using: dependencies
                    )
                    
                case .incoming:
                    _ = try? ThreadTypingIndicator
                        .filter(ThreadTypingIndicator.Columns.threadId == self.threadId)
                        .deleteAll(db)
            }
        }
        
        fileprivate func refreshTimeout(using dependencies: Dependencies) {
            let threadId: String = self.threadId
            let direction: Direction = self.direction
            
            // Schedule the 'stopCallback' to cancel the typing indicator
            stopTimer?.invalidate()
            stopTimer = Timer.scheduledTimerOnMainThread(
                withTimeInterval: (direction == .outgoing ? 3 : 5),
                repeats: false,
                using: dependencies
            ) { _ in
                dependencies[singleton: .storage].writeAsync { db in
                    TypingIndicators.didStopTyping(db, threadId: threadId, direction: direction)
                }
            }
        }
        
        private func scheduleRefreshCallback(
            _ db: Database,
            shouldSend: Bool = true,
            using dependencies: Dependencies
        ) {
            if shouldSend {
                try? MessageSender.send(
                    db,
                    message: TypingIndicator(kind: .started),
                    interactionId: nil,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    using: dependencies
                )
            }
            
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimerOnMainThread(
                withTimeInterval: 10,
                repeats: false
            ) { [weak self] _ in
                dependencies[singleton: .storage].writeAsync { db in
                    self?.scheduleRefreshCallback(db, using: dependencies)
                }
            }
        }
    }
    
    // MARK: - Variables
    
    public static let shared: TypingIndicators = TypingIndicators()
    
    private static var outgoing: Atomic<[String: Indicator]> = Atomic([:])
    private static var incoming: Atomic<[String: Indicator]> = Atomic([:])
    
    // MARK: - Functions
    
    public static func didStartTypingNeedsToStart(
        threadId: String,
        threadVariant: SessionThread.Variant,
        threadIsBlocked: Bool,
        threadIsMessageRequest: Bool,
        direction: Direction,
        timestampMs: Int64?,
        using dependencies: Dependencies = Dependencies()
    ) -> Bool {
        switch direction {
            case .outgoing:
                // If we already have an existing typing indicator for this thread then just
                // refresh it's timeout (no need to do anything else)
                if let existingIndicator: Indicator = outgoing.wrappedValue[threadId] {
                    existingIndicator.refreshTimeout(using: dependencies)
                    return false
                }
                
                let newIndicator: Indicator? = Indicator(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    threadIsBlocked: threadIsBlocked,
                    threadIsMessageRequest: threadIsMessageRequest,
                    direction: direction,
                    timestampMs: timestampMs
                )
                newIndicator?.refreshTimeout(using: dependencies)
                
                outgoing.mutate { $0[threadId] = newIndicator }
                return true
                
            case .incoming:
                // If we already have an existing typing indicator for this thread then just
                // refresh it's timeout (no need to do anything else)
                if let existingIndicator: Indicator = incoming.wrappedValue[threadId] {
                    existingIndicator.refreshTimeout(using: dependencies)
                    return false
                }
                
                let newIndicator: Indicator? = Indicator(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    threadIsBlocked: threadIsBlocked,
                    threadIsMessageRequest: threadIsMessageRequest,
                    direction: direction,
                    timestampMs: timestampMs
                )
                newIndicator?.refreshTimeout(using: dependencies)
                
                incoming.mutate { $0[threadId] = newIndicator }
                return true
        }
    }
    
    public static func start(_ db: Database, threadId: String, direction: Direction) {
        switch direction {
            case .outgoing: outgoing.wrappedValue[threadId]?.start(db)
            case .incoming: incoming.wrappedValue[threadId]?.start(db)
        }
    }
    
    public static func didStopTyping(_ db: Database, threadId: String, direction: Direction) {
        switch direction {
            case .outgoing:
                if let indicator: Indicator = outgoing.wrappedValue[threadId] {
                    indicator.stop(db)
                    outgoing.mutate { $0[threadId] = nil }
                }
                
            case .incoming:
                if let indicator: Indicator = incoming.wrappedValue[threadId] {
                    indicator.stop(db)
                    incoming.mutate { $0[threadId] = nil }
                }
        }
    }
}
