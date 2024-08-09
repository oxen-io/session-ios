// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit

public final class BackgroundPoller {
    let currentUserPoller: CurrentUserPoller = CurrentUserPoller()
    var groupPollers: [Poller] = []
    var communityPollers: [OpenGroupAPI.Poller] = []
    
    public func poll(using dependencies: Dependencies) -> AnyPublisher<Void, Never> {
        let pollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        
        return dependencies.storage
            .readPublisher(using: dependencies) { db -> (Set<String>, Set<String>) in
                (
                    try ClosedGroup
                        .select(.threadId)
                        .joining(
                            required: ClosedGroup.members
                                .filter(GroupMember.Columns.profileId == getUserHexEncodedPublicKey(db))
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
            .catch { _ in Just(([], [])).eraseToAnyPublisher() }
            .handleEvents(
                receiveOutput: { groupIds, servers in
                    Log.info("[BackgroundPoller] Fetching Users: 1, Groups: \(groupIds.count), Communities: \(servers.count).")
                }
            )
            .map { [weak self] groupIds, servers -> ([(Poller, String)], [(OpenGroupAPI.Poller, String)]) in
                let groupPollerInfo: [(Poller, String)] = groupIds.map { (ClosedGroupPoller(), $0) }
                let communityPollerInfo: [(OpenGroupAPI.Poller, String)] = servers.map { (OpenGroupAPI.Poller(for: $0), $0) }
                self?.groupPollers = groupPollerInfo.map { poller, _ in poller }
                self?.communityPollers = communityPollerInfo.map { poller, _ in poller }
                
                return (groupPollerInfo, communityPollerInfo)
            }
            .flatMap { groupPollerInfo, communityPollerInfo in
                Publishers.MergeMany(
                    [BackgroundPoller.pollUserMessages(using: dependencies)]
                        .appending(contentsOf: BackgroundPoller.poll(pollerInfo: groupPollerInfo, using: dependencies))
                        .appending(contentsOf: BackgroundPoller.poll(pollerInfo: communityPollerInfo, using: dependencies))
                )
            }
            .collect()
            .map { _ in () }
            .handleEvents(
                receiveOutput: { _ in
                    let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                    let duration: TimeUnit = .seconds(endTime - pollStart)
                    Log.info("[BackgroundPoller] Finished polling after \(duration, unit: .s).")
                }
            )
            .eraseToAnyPublisher()
    }
    
    private static func pollUserMessages(
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Never> {
        let userPublicKey: String = getUserHexEncodedPublicKey(using: dependencies)
        
        let poller: Poller = CurrentUserPoller()
        let pollerName: String = poller.pollerName(for: userPublicKey)
        let pollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        
        return poller.pollFromBackground(
            namespaces: CurrentUserPoller.namespaces,
            for: userPublicKey,
            drainBehaviour: .alwaysRandom,
            using: dependencies
        )
        .handleEvents(
            receiveOutput: { _, _, validMessageCount, _ in
                let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                let duration: TimeUnit = .seconds(endTime - pollStart)
                Log.info("[BackgroundPoller] \(pollerName) received \(validMessageCount) valid message(s) after \(duration, unit: .s).")
            },
            receiveCompletion: { result in
                switch result {
                    case .finished: break
                    case .failure(let error):
                        let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                        let duration: TimeUnit = .seconds(endTime - pollStart)
                        Log.error("[BackgroundPoller] \(pollerName) failed after \(duration, unit: .s) due to error: \(error).")
                }
            }
        )
        .map { _ in () }
        .catch { _ in Just(()).eraseToAnyPublisher() }
        .eraseToAnyPublisher()
    }
    
    private static func poll(
        pollerInfo: [(poller: Poller, groupPublicKey: String)],
        using dependencies: Dependencies
    ) -> [AnyPublisher<Void, Never>] {
        // Fetch all closed groups (excluding any don't contain the current user as a
        // GroupMemeber as the user is no longer a member of those)
        return pollerInfo.map { poller, groupPublicKey in
            let pollerName: String = poller.pollerName(for: groupPublicKey)
            let pollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
            
            return poller.pollFromBackground(
                namespaces: ClosedGroupPoller.namespaces,
                for: groupPublicKey,
                drainBehaviour: .alwaysRandom,
                using: dependencies
            )
            .handleEvents(
                receiveOutput: { _, _, validMessageCount, _ in
                    let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                    let duration: TimeUnit = .seconds(endTime - pollStart)
                    Log.info("[BackgroundPoller] \(pollerName) received \(validMessageCount) valid message(s) after \(duration, unit: .s).")
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                            let duration: TimeUnit = .seconds(endTime - pollStart)
                            Log.error("[BackgroundPoller] \(pollerName) failed after \(duration, unit: .s) due to error: \(error).")
                    }
                }
            )
            .map { _ in () }
            .catch { _ in Just(()).eraseToAnyPublisher() }
            .eraseToAnyPublisher()
        }
    }
    
    private static func poll(
        pollerInfo: [(poller: OpenGroupAPI.Poller, server: String)],
        using dependencies: Dependencies
    ) -> [AnyPublisher<Void, Never>] {
        return pollerInfo.map { poller, server -> AnyPublisher<Void, Never> in
            let pollerName: String = "Community poller for server: \(server)"   // stringlint:disable
            let pollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
            
            return poller
                .pollFromBackground(using: dependencies)
                .handleEvents(
                    receiveOutput: { _ in
                        let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                        let duration: TimeUnit = .seconds(endTime - pollStart)
                        Log.info("[BackgroundPoller] \(pollerName) succeeded after \(duration, unit: .s).")
                    },
                    receiveCompletion: { result in
                        switch result {
                            case .finished: break
                            case .failure(let error):
                                let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                                let duration: TimeUnit = .seconds(endTime - pollStart)
                                Log.error("[BackgroundPoller] \(pollerName) failed after \(duration, unit: .s) due to error: \(error).")
                        }
                    }
                )
                .map { _ in () }
                .catch { _ in Just(()).eraseToAnyPublisher() }
                .eraseToAnyPublisher()
        }
    }
}
