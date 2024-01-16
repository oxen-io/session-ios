// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let groupsPoller: SingletonConfig<PollerType> = Dependencies.create(
        identifier: "groupsPoller",
        createInstance: { _ in GroupPoller() }
    )
}

// MARK: - GroupPoller

public final class GroupPoller: Poller {
    public static var legacyNamespaces: [SnodeAPI.Namespace] = [.legacyClosedGroup ]
    public static var namespaces: [SnodeAPI.Namespace] = [
        .groupMessages, .configGroupInfo, .configGroupMembers, .configGroupKeys, .revokedRetrievableGroupMessages
    ]

    // MARK: - Settings
    
    override func namespaces(for publicKey: String) -> [SnodeAPI.Namespace] {
        guard (try? SessionId.Prefix(from: publicKey)) == .group else {
            return GroupPoller.legacyNamespaces
        }
        
        return GroupPoller.namespaces
    }
    
    override var pollDrainBehaviour: SwarmDrainBehaviour { .alwaysRandom }
    
    private static let minPollInterval: Double = 3
    private static let maxPollInterval: Double = 30

    // MARK: - Public API
    
    public override func start(using dependencies: Dependencies = Dependencies()) {
        // Fetch all closed groups (excluding any don't contain the current user as a
        // GroupMemeber and any which are in the 'invited' state)
        dependencies[singleton: .storage]
            .read { db -> Set<String> in
                try ClosedGroup
                    .select(.threadId)
                    .filter(ClosedGroup.Columns.shouldPoll == true)                    
                    .asRequest(of: String.self)
                    .fetchSet(db)
            }
            .defaulting(to: [])
            .forEach { [weak self] publicKey in
                self?.startIfNeeded(for: publicKey, using: dependencies)
            }
    }

    // MARK: - Abstract Methods
    
    override func pollerName(for publicKey: String) -> String {
        return "closed group with public key: \(publicKey)" // stringlint:disable
    }

    override func nextPollDelay(for publicKey: String, using dependencies: Dependencies) -> TimeInterval {
        // Get the received date of the last message in the thread. If we don't have
        // any messages yet, pick some reasonable fake time interval to use instead
        let lastMessageDate: Date = dependencies[singleton: .storage]
            .read { db in
                try Interaction
                    .filter(Interaction.Columns.threadId == publicKey)
                    .select(.receivedAtTimestampMs)
                    .order(Interaction.Columns.timestampMs.desc)
                    .asRequest(of: Int64.self)
                    .fetchOne(db)
            }
            .map { receivedAtTimestampMs -> Date? in
                guard receivedAtTimestampMs > 0 else { return nil }
                
                return Date(timeIntervalSince1970: TimeInterval(Double(receivedAtTimestampMs) / 1000))
            }
            .defaulting(to: dependencies.dateNow.addingTimeInterval(-5 * 60))
        
        let timeSinceLastMessage: TimeInterval = dependencies.dateNow.timeIntervalSince(lastMessageDate)
        let minPollInterval: Double = GroupPoller.minPollInterval
        let limit: Double = (12 * 60 * 60)
        let a: TimeInterval = ((GroupPoller.maxPollInterval - minPollInterval) / limit)
        let nextPollInterval: TimeInterval = a * min(timeSinceLastMessage, limit) + minPollInterval
        SNLog("Next poll interval for closed group with public key: \(publicKey) is \(nextPollInterval) s.")
        
        return nextPollInterval
    }

    override func handlePollError(_ error: Error, for publicKey: String, using dependencies: Dependencies) -> Bool {
        SNLog("Polling failed for closed group with public key: \(publicKey) due to error: \(error).")
        return true
    }
}
