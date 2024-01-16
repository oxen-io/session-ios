// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let currentUserPoller: SingletonConfig<PollerType> = Dependencies.create(
        identifier: "currentUserPoller",
        createInstance: { _ in CurrentUserPoller() }
    )
}

// MARK: - GroupPoller

public final class CurrentUserPoller: Poller {
    public static var namespaces: [SnodeAPI.Namespace] = [
        .default, .configUserProfile, .configContacts, .configConvoInfoVolatile, .configUserGroups
    ]

    // MARK: - Settings
    
    override func namespaces(for publicKey: String) -> [SnodeAPI.Namespace] { CurrentUserPoller.namespaces }
    
    /// After polling a given snode 6 times we always switch to a new one.
    ///
    /// The reason for doing this is that sometimes a snode will be giving us successful responses while
    /// it isn't actually getting messages from other snodes.
    override var pollDrainBehaviour: SwarmDrainBehaviour { .limitedReuse(count: 6) }
    
    private let pollInterval: TimeInterval = 1.5
    private let retryInterval: TimeInterval = 0.25
    private let maxRetryInterval: TimeInterval = 15
    
    // MARK: - Convenience Functions
    
    public override func start(using dependencies: Dependencies = Dependencies()) {
        let userSessionId: SessionId = getUserSessionId(using: dependencies)
        
        guard isPolling.wrappedValue[userSessionId.hexString] != true else { return }
        
        SNLog("Started polling.")
        super.startIfNeeded(for: userSessionId.hexString, using: dependencies)
    }
    
    public func stop() {
        SNLog("Stopped polling.")
        super.stopAllPollers()
    }
    
    // MARK: - Abstract Methods
    
    override func pollerName(for publicKey: String) -> String {
        return "Main Poller"    // stringlint:disable
    }
    
    override func nextPollDelay(for publicKey: String, using dependencies: Dependencies) -> TimeInterval {
        let failureCount: Double = Double(failureCount.wrappedValue[publicKey] ?? 0)
        
        // If there have been no failures then just use the 'minPollInterval'
        guard failureCount > 0 else { return pollInterval }
        
        // Otherwise use a simple back-off with the 'retryInterval'
        let nextDelay: TimeInterval = TimeInterval(retryInterval * (failureCount * 1.2))
                                       
        return min(maxRetryInterval, nextDelay)
    }
    
    override func handlePollError(_ error: Error, for publicKey: String, using dependencies: Dependencies) -> Bool {
        if !dependencies[defaults: .appGroup, key: .isMainAppActive] {
            // Do nothing when an error gets throws right after returning from the background (happens frequently)
        }
        else if
            let drainBehaviour: Atomic<SwarmDrainBehaviour> = drainBehaviour.wrappedValue[publicKey],
            case .limitedReuse(_, .some(let targetSnode), _, _, _) = drainBehaviour.wrappedValue
        {
            SNLog("Main Poller polling \(targetSnode) failed with error: \(error); dropping it and switching to next snode.")
            drainBehaviour.mutate { $0 = $0.clearTargetSnode() }
            SnodeAPI.dropSnodeFromSwarmIfNeeded(targetSnode, publicKey: publicKey, using: dependencies)
        }
        else {
            SNLog("Polling failed due to having no target service node.")
        }
        
        return true
    }
}
