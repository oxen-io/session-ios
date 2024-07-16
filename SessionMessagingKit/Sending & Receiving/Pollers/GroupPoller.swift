// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Cache

public extension Cache {
    static let groupPollers: CacheConfig<GroupPollerCacheType, GroupPollerImmutableCacheType> = Dependencies.create(
        identifier: "groupPollers",
        createInstance: { dependencies in GroupPoller.Cache(using: dependencies) },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - GroupPoller

public final class GroupPoller: Poller {
    public static var legacyNamespaces: [SnodeAPI.Namespace] = [.legacyClosedGroup ]
    public static var namespaces: [SnodeAPI.Namespace] = [
        .groupMessages, .configGroupInfo, .configGroupMembers, .configGroupKeys, .revokedRetrievableGroupMessages
    ]

    // MARK: - Settings
    
    private let minPollInterval: Double = 3
    private let maxPollInterval: Double = 30
    override var pollerQueue: DispatchQueue { Threading.groupPollerQueue }
    override var namespaces: [SnodeAPI.Namespace] {
        guard (try? SessionId.Prefix(from: swarmPublicKey)) == .group else {
            return GroupPoller.legacyNamespaces
        }
        
        return GroupPoller.namespaces
    }
    override var pollerName: String { "Closed group poller with public key: \(swarmPublicKey)" }   // stringlint:disable

    // MARK: - Abstract Methods

    override func nextPollDelay() -> TimeInterval {
        // Get the received date of the last message in the thread. If we don't have
        // any messages yet, pick some reasonable fake time interval to use instead
        let lastMessageDate: Date = dependencies[singleton: .storage]
            .read { [swarmPublicKey] db in
                try Interaction
                    .filter(Interaction.Columns.threadId == swarmPublicKey)
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
        let limit: Double = (12 * 60 * 60)
        let a: TimeInterval = ((maxPollInterval - minPollInterval) / limit)
        let nextPollInterval: TimeInterval = a * min(timeSinceLastMessage, limit) + minPollInterval
        
        return nextPollInterval
    }

    override func handlePollError(_ error: Error) -> PollerErrorResponse {
        return .continuePolling
    }
}

// MARK: - GroupPoller Cache

public extension GroupPoller {
    class Cache: GroupPollerCacheType {
        private let dependencies: Dependencies
        private var _pollers: [String: PollerType] = [:] // One for each swarm
        
        // MARK: - Initialization
        
        public init(using dependencies: Dependencies) {
            self.dependencies = dependencies
        }
        
        deinit {
            _pollers.forEach { _, poller in poller.stop() }
            _pollers.removeAll()
        }
        
        // MARK: - Functions
        
        public func startAllPollers() {
            // Fetch all closed groups (excluding any don't contain the current user as a
            // GroupMemeber and any which are in the 'invited' state)
            dependencies[singleton: .storage]
                .read { db -> Set<String> in
                    try ClosedGroup
                        .select(.threadId)
                        .filter(ClosedGroup.Columns.shouldPoll == true)
                        .asRequest(of: String.self)
                        .fetchSet(db)
                }?
                .forEach { swarmPublicKey in getOrCreatePoller(for: swarmPublicKey).startIfNeeded() }
        }
        
        @discardableResult public func getOrCreatePoller(for swarmPublicKey: String) -> PollerType {
            guard let poller: PollerType = _pollers[swarmPublicKey.lowercased()] else {
                let poller: Poller = GroupPoller(
                    swarmPublicKey: swarmPublicKey,
                    shouldStoreMessages: true,
                    logStartAndStopCalls: false,
                    drainBehaviour: .alwaysRandom,
                    using: dependencies
                )
                _pollers[swarmPublicKey.lowercased()] = poller
                return poller
            }
            
            return poller
        }
        
        public func stopAndRemovePoller(for swarmPublicKey: String) {
            _pollers[swarmPublicKey.lowercased()]?.stop()
            _pollers[swarmPublicKey.lowercased()] = nil
        }
        
        public func stopAndRemoveAllPollers() {
            _pollers.forEach { _, poller in poller.stop() }
            _pollers.removeAll()
        }
    }
}

// MARK: - GroupPollerCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol GroupPollerImmutableCacheType: ImmutableCacheType {}

public protocol GroupPollerCacheType: GroupPollerImmutableCacheType, MutableCacheType {
    func startAllPollers()
    @discardableResult func getOrCreatePoller(for swarmPublicKey: String) -> PollerType
    func stopAndRemovePoller(for swarmPublicKey: String)
    func stopAndRemoveAllPollers()
}
