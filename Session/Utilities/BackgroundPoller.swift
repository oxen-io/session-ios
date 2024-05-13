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
        completionHandler: @escaping (UIBackgroundFetchResult) -> Void,
        using dependencies: Dependencies = Dependencies()
    ) {
        Publishers
            .MergeMany(
                [pollForMessages(using: dependencies)]
                    .appending(contentsOf: pollForClosedGroupMessages(using: dependencies))
                    .appending(
                        contentsOf: Storage.shared
                            .read { db in
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
                            }
                            .defaulting(to: [])
                            .map { server -> AnyPublisher<Void, Error> in
                                let poller: OpenGroupAPI.Poller = OpenGroupAPI.Poller(for: server)
                                poller.stop()
                                
                                return poller.poll(
                                    calledFromBackgroundPoller: true,
                                    isBackgroundPollerValid: { BackgroundPoller.isValid },
                                    isPostCapabilitiesRetry: false,
                                    using: dependencies
                                )
                            }
                    )
            )
            .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
            .receive(on: DispatchQueue.main, using: dependencies)
            .collect()
            .sinkUntilComplete(
                receiveCompletion: { result in
                    // If we have already invalidated the timer then do nothing (we essentially timed out)
                    guard BackgroundPoller.isValid else { return }
                    
                    switch result {
                        case .finished: completionHandler(.newData)
                        case .failure(let error):
                            SNLog("Background poll failed due to error: \(error)")
                            completionHandler(.failed)
                    }
                }
            )
    }
    
    private static func pollForMessages(
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        let userPublicKey: String = getUserHexEncodedPublicKey(using: dependencies)

        return CurrentUserPoller().poll(
            namespaces: CurrentUserPoller.namespaces,
            for: userPublicKey,
            calledFromBackgroundPoller: true,
            isBackgroundPollValid: { BackgroundPoller.isValid },
            drainBehaviour: .alwaysRandom,
            using: dependencies
        )
        .map { _ in () }
        .eraseToAnyPublisher()
    }
    
    private static func pollForClosedGroupMessages(
        using dependencies: Dependencies
    ) -> [AnyPublisher<Void, Error>] {
        // Fetch all closed groups (excluding any don't contain the current user as a
        // GroupMemeber as the user is no longer a member of those)
        return Storage.shared
            .read { db in
                try ClosedGroup
                    .select(.threadId)
                    .joining(
                        required: ClosedGroup.members
                            .filter(GroupMember.Columns.profileId == getUserHexEncodedPublicKey(db))
                    )
                    .asRequest(of: String.self)
                    .fetchAll(db)
            }
            .defaulting(to: [])
            .map { groupPublicKey in
                return ClosedGroupPoller()
                    .poll(
                        namespaces: ClosedGroupPoller.namespaces,
                        for: groupPublicKey,
                        calledFromBackgroundPoller: true,
                        isBackgroundPollValid: { BackgroundPoller.isValid },
                        drainBehaviour: .alwaysRandom,
                        using: dependencies
                    )
                    .map { _ in () }
                    .eraseToAnyPublisher()
            }
    }
}
