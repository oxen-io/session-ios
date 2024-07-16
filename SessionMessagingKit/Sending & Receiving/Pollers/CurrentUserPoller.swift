// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let currentUserPoller: SingletonConfig<PollerType> = Dependencies.create(
        identifier: "currentUserPoller",
        createInstance: { dependencies in
            /// After polling a given snode 6 times we always switch to a new one.
            ///
            /// The reason for doing this is that sometimes a snode will be giving us successful responses while
            /// it isn't actually getting messages from other snodes.
            return CurrentUserPoller(
                swarmPublicKey: dependencies[cache: .general].sessionId.hexString,
                shouldStoreMessages: true,
                logStartAndStopCalls: true,
                drainBehaviour: .limitedReuse(count: 6),
                using: dependencies
            )
        }
    )
}

// MARK: - GroupPoller

public final class CurrentUserPoller: Poller {
    public static var namespaces: [SnodeAPI.Namespace] = [
        .default, .configUserProfile, .configContacts, .configConvoInfoVolatile, .configUserGroups
    ]

    // MARK: - Settings
    
    private let pollInterval: TimeInterval = 1.5
    private let retryInterval: TimeInterval = 0.25
    private let maxRetryInterval: TimeInterval = 15
    override var pollerQueue: DispatchQueue { Threading.pollerQueue }
    override var namespaces: [SnodeAPI.Namespace] { CurrentUserPoller.namespaces }
    override var pollerName: String { "Main Poller" }   // stringlint:disable
    
    // MARK: - Abstract Methods
    
    override func nextPollDelay() -> TimeInterval {
        // If there have been no failures then just use the 'minPollInterval'
        guard failureCount > 0 else { return pollInterval }
        
        // Otherwise use a simple back-off with the 'retryInterval'
        let nextDelay: TimeInterval = TimeInterval(retryInterval * (Double(failureCount) * 1.2))
        
        return min(maxRetryInterval, nextDelay)
    }
    
    override func handlePollError(_ error: Error) -> PollerErrorResponse {
        if !dependencies[defaults: .appGroup, key: .isMainAppActive] {
            // Do nothing when an error gets throws right after returning from the background (happens frequently)
        }
        else if case .limitedReuse(_, .some(let targetSnode), _, _, _) = drainBehaviour.wrappedValue {
            drainBehaviour.mutate { $0 = $0.clearTargetSnode() }
            return .continuePollingInfo("Switching from \(targetSnode) to next snode.")
        }
        else {
            return .continuePollingInfo("Had no target snode.")
        }
        
        return .continuePolling
    }
}
