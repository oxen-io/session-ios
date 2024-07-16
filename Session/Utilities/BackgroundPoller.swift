// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit

public final class BackgroundPoller {
    private static var publishers: [AnyPublisher<Void, Error>] = []
    public static var isValid: Bool = false

    public static func poll(
        using dependencies: Dependencies,
        completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let (groupIds, servers): (Set<String>, Set<String>) = dependencies[singleton: .storage]
            .read { db in
                (
                    try ClosedGroup
                        .select(.threadId)
                        .joining(
                            required: ClosedGroup.members
                                .filter(GroupMember.Columns.profileId == dependencies[cache: .general].sessionId.hexString)
                        )
                        .asRequest(of: String.self)
                        .fetchSet(db),
                    /// The default room promise creates an OpenGroup with an empty `roomToken` value, we
                    /// don't want to start a poller for this as the user hasn't actually joined a room
                    ///
                    /// We also want to exclude any rooms which have failed to poll too many times in a row from
                    /// the background poll as they are likely to fail again
                    try OpenGroup
                        .select(.server)
                        .filter(
                            OpenGroup.Columns.roomToken != "" &&
                            OpenGroup.Columns.isActive &&
                            OpenGroup.Columns.pollFailureCount < OpenGroupAPI.Poller.maxRoomFailureCountForBackgroundPoll
                        )
                        .distinct()
                        .asRequest(of: String.self)
                        .fetchSet(db)
                )
            }
            .defaulting(to: ([], []))
        
        Log.info("[BackgroundPoller] Fetching 1 User, \(groupIds.count) \("group", number: groupIds.count), \(servers.count) \("communit", number: servers.count, singular: "y", plural: "ies").")
        Publishers
            .MergeMany(
                [pollForMessages(using: dependencies)]
                    .appending(contentsOf: pollForClosedGroupMessages(groupIds: groupIds, using: dependencies))
                    .appending(contentsOf: pollForCommunityMessages(servers: servers, using: dependencies))
            )
            .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
            .receive(on: DispatchQueue.main, using: dependencies)
            .collect()
            .handleEvents(
                receiveOutput: { _ in
                    Log.info("[BackgroundPoller] Finished polling.")
                }
            )
            .sinkUntilComplete(
                receiveCompletion: { result in
                    // If we have already invalidated the timer then do nothing (we essentially timed out)
                    guard BackgroundPoller.isValid else { return }
                    
                    switch result {
                        case .finished: completionHandler(.newData)
                        case .failure(let error):
                            Log.error("[BackgroundPoller] Failed due to error: \(error).")
                            completionHandler(.failed)
                    }
                }
            )
    }
    
    private static func pollForMessages(
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        return dependencies[singleton: .currentUserPoller].poll(
            namespaces: CurrentUserPoller.namespaces,
            calledFromBackgroundPoller: true,
            isBackgroundPollValid: { BackgroundPoller.isValid }
        )
        .handleEvents(
            receiveOutput: { _, _, _, validMessageCount, _ in
                Log.info("[BackgroundPoller] Received \(validMessageCount) valid \("message", number: validMessageCount).")
            }
        )
        .map { _ in () }
        .eraseToAnyPublisher()
    }
    
    private static func pollForClosedGroupMessages(
        groupIds: Set<String>,
        using dependencies: Dependencies
    ) -> [AnyPublisher<Void, Error>] {
        // Fetch all closed groups (excluding any don't contain the current user as a
        // GroupMemeber as the user is no longer a member of those)
        return groupIds
            .map { publicKey in dependencies.mutate(cache: .groupPollers) { $0.getOrCreatePoller(for: publicKey) } }
            .map { poller in
                poller.poll(
                    namespaces: GroupPoller.namespaces,
                    calledFromBackgroundPoller: true,
                    isBackgroundPollValid: { BackgroundPoller.isValid }
                )
                .handleEvents(
                    receiveOutput: { _, _, _, validMessageCount, _ in
                        Log.info("[BackgroundPoller] Received \(validMessageCount) valid \("message", number: validMessageCount) for group: \(poller.swarmPublicKey).")
                    }
                )
                .map { _ in () }
                .eraseToAnyPublisher()
            }
    }
    
    private static func pollForCommunityMessages(
        servers: Set<String>,
        using dependencies: Dependencies
    ) -> [AnyPublisher<Void, Error>] {
        return servers.map { server -> AnyPublisher<Void, Error> in
            let poller: OpenGroupAPI.Poller = OpenGroupAPI.Poller(for: server)
            poller.stop()
            
            return poller.poll(
                calledFromBackgroundPoller: true,
                isBackgroundPollerValid: { BackgroundPoller.isValid },
                isPostCapabilitiesRetry: false,
                using: dependencies
            )
        }
    }
}
