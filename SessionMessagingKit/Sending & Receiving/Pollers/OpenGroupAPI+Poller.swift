// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

extension OpenGroupAPI {
    public protocol PollerType {
        func startIfNeeded(using dependencies: Dependencies)
        func stop()
    }
    
    public final class Poller: PollerType {
        typealias PollResponse = (info: ResponseInfoType, data: [OpenGroupAPI.Endpoint: Decodable])
        
        private let server: String
        private var recursiveLoopId: UUID = UUID()
        private var hasStarted: Bool = false
        private var isPolling: Bool = false

        // MARK: - Settings
        
        private static let minPollInterval: TimeInterval = 3
        private static let maxPollInterval: TimeInterval = (60 * 60)
        internal static let maxInactivityPeriod: TimeInterval = (14 * 24 * 60 * 60)
        
        /// If there are hidden rooms that we poll and they fail too many times we want to prune them (as it likely means they no longer
        /// exist, and since they are already hidden it's unlikely that the user will notice that we stopped polling for them)
        internal static let maxHiddenRoomFailureCount: Int64 = 10
        
        /// When doing a background poll we want to only fetch from rooms which are unlikely to timeout, in order to do this we exclude
        /// any rooms which have failed more than this threashold
        public static let maxRoomFailureCountForBackgroundPoll: Int64 = 15
        
        // MARK: - Lifecycle
        
        public init(for server: String) {
            self.server = server
        }
        
        public func startIfNeeded(using dependencies: Dependencies) {
            guard !hasStarted else { return }
            
            hasStarted = true
            recursiveLoopId = UUID()
            pollRecursively(using: dependencies)
        }

        @objc public func stop() {
            hasStarted = false
            recursiveLoopId = UUID()
        }

        // MARK: - Polling
        
        private func pollRecursively(using dependencies: Dependencies) {
            guard hasStarted else { return }
            
            let server: String = self.server
            let originalRecursiveLoopId: UUID = self.recursiveLoopId
            let lastPollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
            
            poll(using: dependencies)
                .subscribe(on: Threading.communityPollerQueue, using: dependencies)
                .receive(on: OpenGroupAPI.workQueue, using: dependencies)
                .sinkUntilComplete(
                    receiveCompletion: { [weak self] _ in
                        let minPollFailureCount: Int64 = dependencies[singleton: .storage]
                            .read { db in
                                try OpenGroup
                                    .filter(OpenGroup.Columns.server == server)
                                    .select(min(OpenGroup.Columns.pollFailureCount))
                                    .asRequest(of: Int64.self)
                                    .fetchOne(db)
                            }
                            .defaulting(to: 0)
                        
                        // Calculate the remaining poll delay
                        let currentTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                        let nextPollInterval: TimeInterval = Poller.getInterval(
                            for: minPollFailureCount,
                            minInterval: Poller.minPollInterval,
                            maxInterval: Poller.maxPollInterval
                        )
                        let remainingInterval: TimeInterval = max(0, nextPollInterval - (currentTime - lastPollStart))
                        
                        // Schedule the next poll
                        guard remainingInterval > 0 else {
                            return Threading.communityPollerQueue.async(using: dependencies) {
                                // If we started a new recursive loop then we don't want to double up so just let this
                                // one stop looping
                                guard originalRecursiveLoopId == self?.recursiveLoopId else { return }
                                
                                self?.pollRecursively(using: dependencies)
                            }
                        }
                        
                        Threading.communityPollerQueue.asyncAfter(deadline: .now() + .milliseconds(Int(remainingInterval * 1000)), qos: .default, using: dependencies) {
                            // If we started a new recursive loop then we don't want to double up so just let this
                            // one stop looping
                            guard originalRecursiveLoopId == self?.recursiveLoopId else { return }
                            
                            self?.pollRecursively(using: dependencies)
                        }
                    }
                )
        }

        public func poll(
            calledFromBackgroundPoller: Bool = false,
            isBackgroundPollerValid: @escaping (() -> Bool) = { true },
            isPostCapabilitiesRetry: Bool = false,
            using dependencies: Dependencies
        ) -> AnyPublisher<Void, Error> {
            guard !self.isPolling && self.hasStarted else {
                return Just(())
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            
            self.isPolling = true
            let server: String = self.server
            let pollStartTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
            let hasPerformedInitialPoll: Bool = (dependencies[cache: .openGroupManager].hasPerformedInitialPoll[server] == true)
            let timeSinceLastPoll: TimeInterval = (
                dependencies[cache: .openGroupManager].timeSinceLastPoll[server] ??
                dependencies.mutate(cache: .openGroupManager) { cache in
                    cache.getTimeSinceLastOpen(using: dependencies)
                }
            )
            
            return dependencies[singleton: .storage]
                .readPublisher { db -> (Int64, Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>>) in
                    let failureCount: Int64 = (try? OpenGroup
                        .filter(OpenGroup.Columns.server == server)
                        .select(max(OpenGroup.Columns.pollFailureCount))
                        .asRequest(of: Int64.self)
                        .fetchOne(db))
                        .defaulting(to: 0)
                    
                    return (
                        failureCount,
                        try OpenGroupAPI
                            .preparedPoll(
                                db,
                                server: server,
                                hasPerformedInitialPoll: hasPerformedInitialPoll,
                                timeSinceLastPoll: timeSinceLastPoll,
                                using: dependencies
                            )
                    )
                }
                .flatMap { failureCount, preparedRequest in
                    preparedRequest.send(using: dependencies)
                        .map { info, response in (failureCount, info, response) }
                }
                .handleEvents(
                    receiveOutput: { [weak self] failureCount, info, response in
                        guard !calledFromBackgroundPoller || isBackgroundPollerValid() else {
                            // If this was a background poll and the background poll is no longer valid
                            // then just stop
                            self?.isPolling = false
                            self?.hasStarted = false
                            return
                        }

                        self?.isPolling = false
                        self?.handlePollResponse(
                            info: info,
                            response: response,
                            failureCount: failureCount,
                            using: dependencies
                        )
                        
                        dependencies.mutate(cache: .openGroupManager) { cache in
                            cache.hasPerformedInitialPoll[server] = true
                            cache.timeSinceLastPoll[server] = dependencies.dateNow.timeIntervalSince1970
                            dependencies[defaults: .standard, key: .lastOpen] = dependencies.dateNow
                        }
                        
                        let pollEndTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                        Log.info("[OpenGroupPoller] Finished for \(server) in \(.seconds(pollEndTime - pollStartTime), unit: .s).")
                    }
                )
                .map { _ in () }
                .catch { [weak self] error -> AnyPublisher<Void, Error> in
                    guard
                        let strongSelf = self,
                        strongSelf.hasStarted,
                        (!calledFromBackgroundPoller || isBackgroundPollerValid())
                    else {
                        // If this was a background poll and the background poll is no longer valid
                        // then just stop
                        self?.isPolling = false
                        self?.hasStarted = false

                        return Just(())
                            .setFailureType(to: Error.self)
                            .eraseToAnyPublisher()
                    }

                    // If we are retrying then the error is being handled so no need to continue (this
                    // method will always resolve)
                    return strongSelf
                        .updateCapabilitiesAndRetryIfNeeded(
                            server: server,
                            calledFromBackgroundPoller: calledFromBackgroundPoller,
                            isBackgroundPollerValid: isBackgroundPollerValid,
                            isPostCapabilitiesRetry: isPostCapabilitiesRetry,
                            error: error,
                            using: dependencies
                        )
                        .handleEvents(
                            receiveOutput: { [weak self] didHandleError in
                                if !didHandleError && isBackgroundPollerValid() {
                                    // Increase the failure count
                                    let pollFailureCount: Int64 = dependencies[singleton: .storage]
                                        .read { db in
                                            try OpenGroup
                                                .filter(OpenGroup.Columns.server == server)
                                                .select(max(OpenGroup.Columns.pollFailureCount))
                                                .asRequest(of: Int64.self)
                                                .fetchOne(db)
                                        }
                                        .defaulting(to: 0)
                                    var prunedIds: [String] = []

                                    dependencies[singleton: .storage].writeAsync { db in
                                        struct Info: Decodable, FetchableRecord {
                                            let id: String
                                            let shouldBeVisible: Bool
                                        }
                                        
                                        let rooms: [String] = try OpenGroup
                                            .filter(
                                                OpenGroup.Columns.server == server &&
                                                OpenGroup.Columns.isActive == true
                                            )
                                            .select(.roomToken)
                                            .asRequest(of: String.self)
                                            .fetchAll(db)
                                        let roomsAreVisible: [Info] = try SessionThread
                                            .select(.id, .shouldBeVisible)
                                            .filter(
                                                ids: rooms.map {
                                                    OpenGroup.idFor(roomToken: $0, server: server)
                                                }
                                            )
                                            .asRequest(of: Info.self)
                                            .fetchAll(db)
                                        
                                        // Increase the failure count
                                        try OpenGroup
                                            .filter(OpenGroup.Columns.server == server)
                                            .updateAll(
                                                db,
                                                OpenGroup.Columns.pollFailureCount
                                                    .set(to: (pollFailureCount + 1))
                                            )
                                        
                                        /// If the polling has failed 10+ times then try to prune any invalid rooms that
                                        /// aren't visible (they would have been added via config messages and will
                                        /// likely always fail but the user has no way to delete them)
                                        guard pollFailureCount > Poller.maxHiddenRoomFailureCount else { return }
                                        
                                        prunedIds = roomsAreVisible
                                            .filter { !$0.shouldBeVisible }
                                            .map { $0.id }
                                        
                                        prunedIds.forEach { id in
                                            try? dependencies[singleton: .openGroupManager].delete(
                                                db,
                                                openGroupId: id,
                                                /// **Note:** We pass `calledFromConfig` as `userGroups`
                                                /// here because we want to avoid syncing this deletion as the room might
                                                /// not be in an invalid state on other devices - one of the other devices
                                                /// will eventually trigger a new config update which will re-add this room
                                                /// and hopefully at that time it'll work again
                                                calledFromConfig: .userGroups
                                            )
                                        }
                                    }
                                    
                                    let pollEndTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                                    Log.info("[OpenGroupPoller] Polling to \(server) failed in \(.seconds(pollEndTime - pollStartTime), unit: .s) due to error: \(error). Setting failure count to \(pollFailureCount + 1).")
                                    
                                    // Add a note to the logs that this happened
                                    if !prunedIds.isEmpty {
                                        let rooms: String = prunedIds
                                            .compactMap { $0.components(separatedBy: server).last }
                                            .joined(separator: ", ")
                                        Log.warn("[OpenGroupPoller] Hidden open group failure count surpassed \(Poller.maxHiddenRoomFailureCount), removed hidden rooms \(rooms).")
                                    }
                                }

                                self?.isPolling = false
                            }
                        )
                        .map { _ in () }
                        .eraseToAnyPublisher()
                }
                .eraseToAnyPublisher()
        }
        
        private func updateCapabilitiesAndRetryIfNeeded(
            server: String,
            calledFromBackgroundPoller: Bool,
            isBackgroundPollerValid: @escaping (() -> Bool) = { true },
            isPostCapabilitiesRetry: Bool,
            error: Error,
            using dependencies: Dependencies
        ) -> AnyPublisher<Bool, Error> {
            /// We want to custom handle a '400' error code due to not having blinded auth as it likely means that we join the
            /// OpenGroup before blinding was enabled and need to update it's capabilities
            ///
            /// **Note:** To prevent an infinite loop caused by a server-side bug we want to prevent this capabilities request from
            /// happening multiple times in a row
            guard
                !isPostCapabilitiesRetry,
                let error: NetworkError = error as? NetworkError,
                case .badRequest(let dataString, _) = error,
                dataString.contains("Invalid authentication: this server requires the use of blinded ids") // stringlint:disable
            else {
                return Just(false)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            
            return dependencies[singleton: .storage]
                .readPublisher { db in
                    try OpenGroupAPI.preparedCapabilities(
                        db,
                        server: server,
                        forceBlinded: true,
                        using: dependencies
                    )
                }
                .flatMap { $0.send(using: dependencies) }
                .flatMap { [weak self] _, responseBody -> AnyPublisher<Void, Error> in
                    guard let strongSelf = self, strongSelf.hasStarted, isBackgroundPollerValid() else {
                        return Just(())
                            .setFailureType(to: Error.self)
                            .eraseToAnyPublisher()
                    }
                    
                    // Handle the updated capabilities and re-trigger the poll
                    strongSelf.isPolling = false
                    
                    dependencies[singleton: .storage].write { db in
                        OpenGroupManager.handleCapabilities(
                            db,
                            capabilities: responseBody,
                            on: server
                        )
                    }
                    
                    // Regardless of the outcome we can just resolve this
                    // immediately as it'll handle it's own response
                    return strongSelf.poll(
                        calledFromBackgroundPoller: calledFromBackgroundPoller,
                        isBackgroundPollerValid: isBackgroundPollerValid,
                        isPostCapabilitiesRetry: true,
                        using: dependencies
                    )
                    .map { _ in () }
                    .eraseToAnyPublisher()
                }
                .map { _ in true }
                .catch { error -> AnyPublisher<Bool, Error> in
                    Log.error("[OpenGroupPoller] Updating capabilities for \(server) failed due to error: \(error).")
                    return Just(true)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                .eraseToAnyPublisher()
        }
        
        private func handlePollResponse(
            info: ResponseInfoType,
            response: Network.BatchResponseMap<OpenGroupAPI.Endpoint>,
            failureCount: Int64,
            using dependencies: Dependencies
        ) {
            let server: String = self.server
            let validResponses: [OpenGroupAPI.Endpoint: Any] = response.data
                .filter { endpoint, data in
                    switch endpoint {
                        case .capabilities:
                            guard (data as? Network.BatchSubResponse<Capabilities>)?.body != nil else {
                                Log.error("[OpenGroupPoller] Failed due to invalid capability data.")
                                return false
                            }
                            
                            return true
                            
                        case .roomPollInfo(let roomToken, _):
                            guard (data as? Network.BatchSubResponse<RoomPollInfo>)?.body != nil else {
                                switch (data as? Network.BatchSubResponse<RoomPollInfo>)?.code {
                                    case 404: Log.error("[OpenGroupPoller] Failed to retrieve info for unknown room '\(roomToken)'.")
                                    default: Log.error("[OpenGroupPoller] Failed due to invalid room info data.")
                                }
                                return false
                            }
                            
                            return true
                            
                        case .roomMessagesRecent(let roomToken), .roomMessagesBefore(let roomToken, _), .roomMessagesSince(let roomToken, _):
                            guard
                                let responseData: Network.BatchSubResponse<[Failable<Message>]> = data as? Network.BatchSubResponse<[Failable<Message>]>,
                                let responseBody: [Failable<Message>] = responseData.body
                            else {
                                switch (data as? Network.BatchSubResponse<[Failable<Message>]>)?.code {
                                    case 404: Log.error("[OpenPoller] Failed to retrieve messages for unknown room '\(roomToken)'.")
                                    default: Log.error("[OpenPoller] Failed due to invalid messages data.")
                                }
                                return false
                            }
                            
                            let successfulMessages: [Message] = responseBody.compactMap { $0.value }
                            
                            if successfulMessages.count != responseBody.count {
                                let droppedCount: Int = (responseBody.count - successfulMessages.count)
                                
                                Log.info("[OpenGroupPoller] Dropped \(droppedCount) invalid open group message\(plural: droppedCount).")
                            }
                            
                            return !successfulMessages.isEmpty
                            
                        case .inbox, .inboxSince, .outbox, .outboxSince:
                            guard
                                let responseData: Network.BatchSubResponse<[DirectMessage]?> = data as? Network.BatchSubResponse<[DirectMessage]?>,
                                !responseData.failedToParseBody
                            else {
                                Log.error("[OpenGroupPoller] Failed due to invalid inbox/outbox data.")
                                return false
                            }
                            
                            // Double optional because the server can return a `304` with an empty body
                            let messages: [OpenGroupAPI.DirectMessage] = ((responseData.body ?? []) ?? [])
                            
                            return !messages.isEmpty
                            
                        default: return false // No custom handling needed
                    }
                }
            
            // If there are no remaining 'validResponses' and there hasn't been a failure then there is
            // no need to do anything else
            guard !validResponses.isEmpty || failureCount != 0 else { return }
            
            // Retrieve the current capability & group info to check if anything changed
            let rooms: [String] = validResponses
                .keys
                .compactMap { endpoint -> String? in
                    switch endpoint {
                        case .roomPollInfo(let roomToken, _): return roomToken
                        default: return nil
                    }
                }
            let currentInfo: (capabilities: Capabilities, groups: [OpenGroup])? = dependencies[singleton: .storage].read { db in
                let allCapabilities: [Capability] = try Capability
                    .filter(Capability.Columns.openGroupServer == server)
                    .fetchAll(db)
                let capabilities: Capabilities = Capabilities(
                    capabilities: allCapabilities
                        .filter { !$0.isMissing }
                        .map { $0.variant },
                    missing: {
                        let missingCapabilities: [Capability.Variant] = allCapabilities
                            .filter { $0.isMissing }
                            .map { $0.variant }
                        
                        return (missingCapabilities.isEmpty ? nil : missingCapabilities)
                    }()
                )
                let openGroupIds: [String] = rooms
                    .map { OpenGroup.idFor(roomToken: $0, server: server) }
                let groups: [OpenGroup] = try OpenGroup
                    .filter(ids: openGroupIds)
                    .fetchAll(db)
                
                return (capabilities, groups)
            }
            let changedResponses: [OpenGroupAPI.Endpoint: Any] = validResponses
                .filter { endpoint, data in
                    switch endpoint {
                        case .capabilities:
                            guard
                                let responseData: Network.BatchSubResponse<Capabilities> = data as? Network.BatchSubResponse<Capabilities>,
                                let responseBody: Capabilities = responseData.body
                            else { return false }
                            
                            return (responseBody != currentInfo?.capabilities)
                            
                        case .roomPollInfo(let roomToken, _):
                            guard
                                let responseData: Network.BatchSubResponse<RoomPollInfo> = data as? Network.BatchSubResponse<RoomPollInfo>,
                                let responseBody: RoomPollInfo = responseData.body
                            else { return false }
                            guard let existingOpenGroup: OpenGroup = currentInfo?.groups.first(where: { $0.roomToken == roomToken }) else {
                                return true
                            }
                            
                            // Note: This might need to be updated in the future when we start tracking
                            // user permissions if changes to permissions don't trigger a change to
                            // the 'infoUpdates'
                            return (
                                responseBody.activeUsers != existingOpenGroup.userCount || (
                                    responseBody.details != nil &&
                                    responseBody.details?.infoUpdates != existingOpenGroup.infoUpdates
                                )
                            )
                        
                        default: return true
                    }
                }
            
            // If there are no 'changedResponses' and there hasn't been a failure then there is
            // no need to do anything else
            guard !changedResponses.isEmpty || failureCount != 0 else { return }
            
            dependencies[singleton: .storage].write { db in
                // Reset the failure count
                if failureCount > 0 {
                    try OpenGroup
                        .filter(OpenGroup.Columns.server == server)
                        .updateAll(db, OpenGroup.Columns.pollFailureCount.set(to: 0))
                }
                
                try changedResponses.forEach { endpoint, data in
                    switch endpoint {
                        case .capabilities:
                            guard
                                let responseData: Network.BatchSubResponse<Capabilities> = data as? Network.BatchSubResponse<Capabilities>,
                                let responseBody: Capabilities = responseData.body
                            else { return }
                            
                            OpenGroupManager.handleCapabilities(
                                db,
                                capabilities: responseBody,
                                on: server
                            )
                            
                        case .roomPollInfo(let roomToken, _):
                            guard
                                let responseData: Network.BatchSubResponse<RoomPollInfo> = data as? Network.BatchSubResponse<RoomPollInfo>,
                                let responseBody: RoomPollInfo = responseData.body
                            else { return }
                            
                            try OpenGroupManager.handlePollInfo(
                                db,
                                pollInfo: responseBody,
                                publicKey: nil,
                                for: roomToken,
                                on: server,
                                using: dependencies
                            )
                            
                        case .roomMessagesRecent(let roomToken), .roomMessagesBefore(let roomToken, _), .roomMessagesSince(let roomToken, _):
                            guard
                                let responseData: Network.BatchSubResponse<[Failable<Message>]> = data as? Network.BatchSubResponse<[Failable<Message>]>,
                                let responseBody: [Failable<Message>] = responseData.body
                            else { return }
                            
                            OpenGroupManager.handleMessages(
                                db,
                                messages: responseBody.compactMap { $0.value },
                                for: roomToken,
                                on: server,
                                using: dependencies
                            )
                            
                        case .inbox, .inboxSince, .outbox, .outboxSince:
                            guard
                                let responseData: Network.BatchSubResponse<[DirectMessage]?> = data as? Network.BatchSubResponse<[DirectMessage]?>,
                                !responseData.failedToParseBody
                            else { return }
                            
                            // Double optional because the server can return a `304` with an empty body
                            let messages: [OpenGroupAPI.DirectMessage] = ((responseData.body ?? []) ?? [])
                            let fromOutbox: Bool = {
                                switch endpoint {
                                    case .outbox, .outboxSince: return true
                                    default: return false
                                }
                            }()
                            
                            OpenGroupManager.handleDirectMessages(
                                db,
                                messages: messages,
                                fromOutbox: fromOutbox,
                                on: server,
                                using: dependencies
                            )
                            
                        default: break // No custom handling needed
                    }
                }
            }
        }
        
        // MARK: - Convenience

        fileprivate static func getInterval(for failureCount: Int64, minInterval: TimeInterval, maxInterval: TimeInterval) -> TimeInterval {
            // Arbitrary backoff factor...
            return min(maxInterval, minInterval + pow(2, Double(failureCount)))
        }
    }
}
