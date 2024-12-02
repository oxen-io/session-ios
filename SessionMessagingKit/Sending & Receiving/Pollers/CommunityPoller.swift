// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Cache

public extension Cache {
    static let communityPollers: CacheConfig<CommunityPollerCacheType, CommunityPollerImmutableCacheType> = Dependencies.create(
        identifier: "communityPollers",
        createInstance: { dependencies in CommunityPoller.Cache(using: dependencies) },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - CommunityPollerType

public protocol CommunityPollerType {
    typealias PollResponse = (info: ResponseInfoType, data: Network.BatchResponseMap<OpenGroupAPI.Endpoint>)
    
    var isPolling: Bool { get }
    var receivedPollResponse: AnyPublisher<PollResponse, Never> { get }
    
    func startIfNeeded()
    func stop()
}

// MARK: - CommunityPoller

private typealias Capabilities = OpenGroupAPI.Capabilities

public final class CommunityPoller: CommunityPollerType & PollerType {
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
    
    // MARK: - PollerType
    
    public let dependencies: Dependencies
    public let pollerQueue: DispatchQueue
    public let pollerName: String
    public let pollerDestination: PollerDestination
    public let logStartAndStopCalls: Bool
    public var receivedPollResponse: AnyPublisher<PollResponse, Never> {
        receivedPollResponseSubject.eraseToAnyPublisher()
    }
    
    public var isPolling: Bool = false
    public var pollCount: Int = 0
    public var failureCount: Int
    public var lastPollStart: TimeInterval = 0
    public var cancellable: AnyCancellable?
    
    private let shouldStoreMessages: Bool
    private let receivedPollResponseSubject: PassthroughSubject<PollResponse, Never> = PassthroughSubject()
    
    // MARK: - Initialization
    
    required public init(
        pollerName: String,
        pollerQueue: DispatchQueue,
        pollerDestination: PollerDestination,
        pollerDrainBehaviour: SwarmDrainBehaviour = .alwaysRandom,
        namespaces: [SnodeAPI.Namespace] = [],
        failureCount: Int,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        customAuthMethod: AuthenticationMethod? = nil,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.pollerName = pollerName
        self.pollerQueue = pollerQueue
        self.pollerDestination = pollerDestination
        self.failureCount = failureCount
        self.shouldStoreMessages = shouldStoreMessages
        self.logStartAndStopCalls = logStartAndStopCalls
    }
    
    // MARK: - Abstract Methods

    public func nextPollDelay() -> TimeInterval {
        // Arbitrary backoff factor...
        return min(CommunityPoller.maxPollInterval, CommunityPoller.minPollInterval + pow(2, Double(failureCount)))
    }
    
    public func handlePollError(_ error: Error, _ lastError: Error?) -> PollerErrorResponse {
        /// We want to custom handle a '400' error code due to not having blinded auth as it likely means that we join the
        /// OpenGroup before blinding was enabled and need to update it's capabilities
        ///
        /// **Note:** To prevent an infinite loop caused by a server-side bug we want to prevent this capabilities request from
        /// happening multiple times in a row
        switch (error.isMissingBlindedAuthError, lastError?.isMissingBlindedAuthError) {
            case (true, .none), (true, false): break
            default:
                /// Save the updated failure count to the database
                dependencies[singleton: .storage].write { [pollerDestination, failureCount] db in
                    try OpenGroup
                        .filter(OpenGroup.Columns.server == pollerDestination.target)
                        .updateAll(
                            db,
                            OpenGroup.Columns.pollFailureCount.set(to: failureCount + 1)
                        )
                }
                return .continuePolling
        }
        
        /// Since we have gotten here we should update the SOGS capabilities before triggering the next poll
        let fallbackPollDelay: TimeInterval = self.nextPollDelay()
        
        cancellable = dependencies[singleton: .storage]
            .readPublisher { [pollerDestination, dependencies] db in
                try OpenGroupAPI.preparedCapabilities(
                    db,
                    server: pollerDestination.target,
                    forceBlinded: true,
                    using: dependencies
                )
            }
            .subscribe(on: pollerQueue, using: dependencies)
            .receive(on: pollerQueue, using: dependencies)
            .flatMap { [dependencies] request in request.send(using: dependencies) }
            .flatMapStorageWritePublisher(using: dependencies) { [pollerDestination] (db: Database, response: (info: ResponseInfoType, data: OpenGroupAPI.Capabilities)) in
                OpenGroupManager.handleCapabilities(
                    db,
                    capabilities: response.data,
                    on: pollerDestination.target
                )
            }
            .tryCatch { [pollerName, pollerDestination, failureCount, dependencies] error -> AnyPublisher<Void, Error> in
                /// Log the error first
                Log.error(.poller, "\(pollerName) failed to update capabilities due to error: \(error).")
                
                /// If the polling has failed 10+ times then try to prune any invalid rooms that
                /// aren't visible (they would have been added via config messages and will
                /// likely always fail but the user has no way to delete them)
                guard (failureCount + 1) > CommunityPoller.maxHiddenRoomFailureCount else {
                    /// Save the updated failure count to the database
                    dependencies[singleton: .storage].writeAsync { db in
                        try OpenGroup
                            .filter(OpenGroup.Columns.server == pollerDestination.target)
                            .updateAll(
                                db,
                                OpenGroup.Columns.pollFailureCount.set(to: failureCount + 1)
                            )
                    }
                    
                    throw error
                }
                
                return dependencies[singleton: .storage]
                    .writePublisher { db -> [String] in
                        /// Save the updated failure count to the database
                        try OpenGroup
                            .filter(OpenGroup.Columns.server == pollerDestination.target)
                            .updateAll(
                                db,
                                OpenGroup.Columns.pollFailureCount.set(to: failureCount + 1)
                            )
                        
                        /// Prune any hidden rooms
                        let roomIds: Set<String> = try OpenGroup
                            .filter(
                                OpenGroup.Columns.server == pollerDestination.target &&
                                OpenGroup.Columns.isActive == true
                            )
                            .select(.roomToken)
                            .asRequest(of: String.self)
                            .fetchSet(db)
                            .map { OpenGroup.idFor(roomToken: $0, server: pollerDestination.target) }
                            .asSet()
                        let hiddenRoomIds: Set<String> = try SessionThread
                            .select(.id)
                            .filter(ids: roomIds)
                            .filter(
                                SessionThread.Columns.shouldBeVisible == false ||
                                SessionThread.Columns.pinnedPriority == LibSession.hiddenPriority
                            )
                            .asRequest(of: String.self)
                            .fetchSet(db)

                        try hiddenRoomIds.forEach { id in
                            try dependencies[singleton: .openGroupManager].delete(
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

                        return Array(hiddenRoomIds)
                    }
                    .handleEvents(
                        receiveOutput: { hiddenRoomIds in
                            guard !hiddenRoomIds.isEmpty else { return }
                            
                            // Add a note to the logs that this happened
                            let rooms: String = hiddenRoomIds
                                .sorted()
                                .compactMap { $0.components(separatedBy: pollerDestination.target).last }
                                .joined(separator: ", ")
                            Log.error(.poller, "\(pollerName) failure count surpassed \(CommunityPoller.maxHiddenRoomFailureCount), removed hidden rooms [\(rooms)].")
                        }
                    )
                    .map { _ in () }
                    .eraseToAnyPublisher()
            }
            .asResult()
            .sink(receiveValue: { [weak self, pollerQueue, dependencies] _ in
                let nextPollInterval: TimeUnit = .seconds((self?.nextPollDelay()).defaulting(to: fallbackPollDelay))
                
                // Schedule the next poll
                pollerQueue.asyncAfter(deadline: .now() + .milliseconds(Int(nextPollInterval.timeInterval * 1000)), qos: .default, using: dependencies) {
                    self?.pollRecursively(error)
                }
            })
        
            /// Stop polling at this point (we will resume once the above publisher completes
            return .stopPolling
    }

    // MARK: - Polling
    
    /// Polls based on it's configuration and processes any messages, returning an array of messages that were
    /// successfully processed
    ///
    /// **Note:** The returned messages will have already been processed by the `Poller`, they are only returned
    /// for cases where we need explicit/custom behaviours to occur (eg. Onboarding)
    public func poll(forceSynchronousProcessing: Bool = false) -> AnyPublisher<PollResult, Error> {
        let timeSinceLastPoll: TimeInterval = (self.lastPollStart > 0 ?
            lastPollStart :
            dependencies.mutate(cache: .openGroupManager) { cache in
                cache.getTimeSinceLastOpen(using: dependencies)
            }
        )
        
        return dependencies[singleton: .storage]
            .readPublisher { [pollerDestination, pollCount, dependencies] db -> Network.PreparedRequest<Network.BatchResponseMap<OpenGroupAPI.Endpoint>> in
                try OpenGroupAPI.preparedPoll(
                    db,
                    server: pollerDestination.target,
                    hasPerformedInitialPoll: (pollCount > 0),
                    timeSinceLastPoll: timeSinceLastPoll,
                    using: dependencies
                )
            }
            .flatMap { [dependencies] request in request.send(using: dependencies) }
            .flatMapOptional { [weak self, failureCount, dependencies] info, response in
                self?.handlePollResponse(
                    info: info,
                    response: response,
                    failureCount: failureCount,
                    using: dependencies
                )
            }
            .eraseToAnyPublisher()
    }
    
    private func handlePollResponse(
        info: ResponseInfoType,
        response: Network.BatchResponseMap<OpenGroupAPI.Endpoint>,
        failureCount: Int,
        using dependencies: Dependencies
    ) -> AnyPublisher<PollResult, Error> {
        var rawMessageCount: Int = 0
        let validResponses: [OpenGroupAPI.Endpoint: Any] = response.data
            .filter { endpoint, data in
                switch endpoint {
                    case .capabilities:
                        guard (data as? Network.BatchSubResponse<Capabilities>)?.body != nil else {
                            Log.error(.poller, "\(pollerName) failed due to invalid capability data.")
                            return false
                        }
                        
                        return true
                        
                    case .roomPollInfo(let roomToken, _):
                        guard (data as? Network.BatchSubResponse<OpenGroupAPI.RoomPollInfo>)?.body != nil else {
                            switch (data as? Network.BatchSubResponse<OpenGroupAPI.RoomPollInfo>)?.code {
                                case 404: Log.error(.poller, "\(pollerName) failed to retrieve info for unknown room '\(roomToken)'.")
                                default: Log.error(.poller, "\(pollerName) failed due to invalid room info data.")
                            }
                            return false
                        }
                        
                        return true
                        
                    case .roomMessagesRecent(let roomToken), .roomMessagesBefore(let roomToken, _), .roomMessagesSince(let roomToken, _):
                        guard
                            let responseData: Network.BatchSubResponse<[Failable<OpenGroupAPI.Message>]> = data as? Network.BatchSubResponse<[Failable<OpenGroupAPI.Message>]>,
                            let responseBody: [Failable<OpenGroupAPI.Message>] = responseData.body
                        else {
                            switch (data as? Network.BatchSubResponse<[Failable<OpenGroupAPI.Message>]>)?.code {
                                case 404: Log.error(.poller, "\(pollerName) failed to retrieve messages for unknown room '\(roomToken)'.")
                                default: Log.error(.poller, "\(pollerName) failed due to invalid messages data.")
                            }
                            return false
                        }
                        
                        let successfulMessages: [OpenGroupAPI.Message] = responseBody.compactMap { $0.value }
                        rawMessageCount += successfulMessages.count
                        
                        if successfulMessages.count != responseBody.count {
                            let droppedCount: Int = (responseBody.count - successfulMessages.count)
                            
                            Log.info(.poller, "\(pollerName) dropped \(droppedCount) invalid open group message(s).")
                        }
                        
                        return !successfulMessages.isEmpty
                        
                    case .inbox, .inboxSince, .outbox, .outboxSince:
                        guard
                            let responseData: Network.BatchSubResponse<[OpenGroupAPI.DirectMessage]?> = data as? Network.BatchSubResponse<[OpenGroupAPI.DirectMessage]?>,
                            !responseData.failedToParseBody
                        else {
                            Log.error(.poller, "\(pollerName) failed due to invalid inbox/outbox data.")
                            return false
                        }
                        
                        // Double optional because the server can return a `304` with an empty body
                        let messages: [OpenGroupAPI.DirectMessage] = ((responseData.body ?? []) ?? [])
                        rawMessageCount += messages.count
                        
                        return !messages.isEmpty
                        
                    default: return false // No custom handling needed
                }
            }
        
        // If there are no remaining 'validResponses' and there hasn't been a failure then there is
        // no need to do anything else
        guard !validResponses.isEmpty || failureCount != 0 else {
            return Just(((info, response), rawMessageCount, 0, true))
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }

        // Retrieve the current capability & group info to check if anything changed
        let rooms: [String] = validResponses
            .keys
            .compactMap { endpoint -> String? in
                switch endpoint {
                    case .roomPollInfo(let roomToken, _): return roomToken
                    default: return nil
                }
            }
        
        return dependencies[singleton: .storage]
            .readPublisher { [pollerDestination] db -> (capabilities: OpenGroupAPI.Capabilities, groups: [OpenGroup]) in
                let allCapabilities: [Capability] = try Capability
                    .filter(Capability.Columns.openGroupServer == pollerDestination.target)
                    .fetchAll(db)
                let capabilities: OpenGroupAPI.Capabilities = OpenGroupAPI.Capabilities(
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
                    .map { OpenGroup.idFor(roomToken: $0, server: pollerDestination.target) }
                let groups: [OpenGroup] = try OpenGroup
                    .filter(ids: openGroupIds)
                    .fetchAll(db)
                
                return (capabilities, groups)
            }
            .flatMap { [pollerDestination, dependencies] (capabilities: OpenGroupAPI.Capabilities, groups: [OpenGroup]) -> AnyPublisher<PollResult, Error> in
                let changedResponses: [OpenGroupAPI.Endpoint: Any] = validResponses
                    .filter { endpoint, data in
                        switch endpoint {
                            case .capabilities:
                                guard
                                    let responseData: Network.BatchSubResponse<OpenGroupAPI.Capabilities> = data as? Network.BatchSubResponse<OpenGroupAPI.Capabilities>,
                                    let responseBody: OpenGroupAPI.Capabilities = responseData.body
                                else { return false }
                                
                                return (responseBody != capabilities)
                                
                            case .roomPollInfo(let roomToken, _):
                                guard
                                    let responseData: Network.BatchSubResponse<OpenGroupAPI.RoomPollInfo> = data as? Network.BatchSubResponse<OpenGroupAPI.RoomPollInfo>,
                                    let responseBody: OpenGroupAPI.RoomPollInfo = responseData.body
                                else { return false }
                                guard let existingOpenGroup: OpenGroup = groups.first(where: { $0.roomToken == roomToken }) else {
                                    return true
                                }
                                
                                return (
                                    responseBody.activeUsers != existingOpenGroup.userCount || (
                                        responseBody.details != nil &&
                                        responseBody.details?.infoUpdates != existingOpenGroup.infoUpdates
                                    ) ||
                                    OpenGroup.Permissions(roomInfo: responseBody) != existingOpenGroup.permissions
                                )
                            
                            default: return true
                        }
                    }
                
                // If there are no 'changedResponses' and there hasn't been a failure then there is
                // no need to do anything else
                guard !changedResponses.isEmpty || failureCount != 0 else {
                    return Just(((info, response), rawMessageCount, 0, true))
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                return dependencies[singleton: .storage]
                    .writePublisher { db in
                        // Reset the failure count
                        if failureCount > 0 {
                            try OpenGroup
                                .filter(OpenGroup.Columns.server == pollerDestination.target)
                                .updateAll(db, OpenGroup.Columns.pollFailureCount.set(to: 0))
                        }

                        try changedResponses.forEach { endpoint, data in
                            switch endpoint {
                                case .capabilities:
                                    guard
                                        let responseData: Network.BatchSubResponse<OpenGroupAPI.Capabilities> = data as? Network.BatchSubResponse<OpenGroupAPI.Capabilities>,
                                        let responseBody: OpenGroupAPI.Capabilities = responseData.body
                                    else { return }
                                    
                                    OpenGroupManager.handleCapabilities(
                                        db,
                                        capabilities: responseBody,
                                        on: pollerDestination.target
                                    )
                                    
                                case .roomPollInfo(let roomToken, _):
                                    guard
                                        let responseData: Network.BatchSubResponse<OpenGroupAPI.RoomPollInfo> = data as? Network.BatchSubResponse<OpenGroupAPI.RoomPollInfo>,
                                        let responseBody: OpenGroupAPI.RoomPollInfo = responseData.body
                                    else { return }
                                    
                                    try OpenGroupManager.handlePollInfo(
                                        db,
                                        pollInfo: responseBody,
                                        publicKey: nil,
                                        for: roomToken,
                                        on: pollerDestination.target,
                                        using: dependencies
                                    )
                                    
                                case .roomMessagesRecent(let roomToken), .roomMessagesBefore(let roomToken, _), .roomMessagesSince(let roomToken, _):
                                    guard
                                        let responseData: Network.BatchSubResponse<[Failable<OpenGroupAPI.Message>]> = data as? Network.BatchSubResponse<[Failable<OpenGroupAPI.Message>]>,
                                        let responseBody: [Failable<OpenGroupAPI.Message>] = responseData.body
                                    else { return }
                                    
                                    OpenGroupManager.handleMessages(
                                        db,
                                        messages: responseBody.compactMap { $0.value },
                                        for: roomToken,
                                        on: pollerDestination.target,
                                        using: dependencies
                                    )
                                    
                                case .inbox, .inboxSince, .outbox, .outboxSince:
                                    guard
                                        let responseData: Network.BatchSubResponse<[OpenGroupAPI.DirectMessage]?> = data as? Network.BatchSubResponse<[OpenGroupAPI.DirectMessage]?>,
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
                                        on: pollerDestination.target,
                                        using: dependencies
                                    )
                                    
                                default: break // No custom handling needed
                            }
                        }
                    }
                    .map { _ in ((info, response), rawMessageCount, rawMessageCount, true) }  // Assume all messages were handled
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
}
                    
// MARK: - Convenience

fileprivate extension Error {
    var isMissingBlindedAuthError: Bool {
        guard
            let networkError: NetworkError = self as? NetworkError,
            case .badRequest(let dataString, _) = networkError,
            dataString.contains("Invalid authentication: this server requires the use of blinded ids") // stringlint:ignore
        else { return false }
        
        return true
    }
}

// MARK: - GroupPoller Cache

public extension CommunityPoller {
    struct Info: Equatable, FetchableRecord, Decodable, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression {
            case server
            case pollFailureCount
        }
        
        public let server: String
        public let pollFailureCount: Int64
    }
    
    class Cache: CommunityPollerCacheType {
        private let dependencies: Dependencies
        private var _pollers: [String: CommunityPoller] = [:] // One for each server
        
        public var serversBeingPolled: Set<String> { Set(_pollers.keys) }
        public var allPollers: [CommunityPollerType] { Array(_pollers.values) }
        
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
            // On the communityPollerQueue fetch all SOGS and start the pollers
            Threading.communityPollerQueue.async(using: dependencies) { [dependencies] in
                dependencies[singleton: .storage]
                    .read { db -> [Info] in
                        // The default room promise creates an OpenGroup with an empty `roomToken` value,
                        // we don't want to start a poller for this as the user hasn't actually joined a room
                        try OpenGroup
                            .select(
                                OpenGroup.Columns.server,
                                max(OpenGroup.Columns.pollFailureCount).forKey(Info.Columns.pollFailureCount)
                            )
                            .filter(OpenGroup.Columns.isActive == true)
                            .filter(OpenGroup.Columns.roomToken != "")
                            .group(OpenGroup.Columns.server)
                            .asRequest(of: Info.self)
                            .fetchAll(db)
                    }?
                    .forEach { [weak self] info in self?.getOrCreatePoller(for: info).startIfNeeded() }
            }
        }
        
        @discardableResult public func getOrCreatePoller(for info: CommunityPoller.Info) -> CommunityPollerType {
            guard let poller: CommunityPoller = _pollers[info.server.lowercased()] else {
                let poller: CommunityPoller = CommunityPoller(
                    pollerName: "Community poller for: \(info.server)", // stringlint:ignore
                    pollerQueue: Threading.communityPollerQueue,
                    pollerDestination: .server(info.server),
                    failureCount: Int(info.pollFailureCount),
                    shouldStoreMessages: true,
                    logStartAndStopCalls: false,
                    using: dependencies
                )
                _pollers[info.server.lowercased()] = poller
                return poller
            }
            
            return poller
        }

        public func stopAndRemovePoller(for server: String) {
            _pollers[server.lowercased()]?.stop()
            _pollers[server.lowercased()] = nil
        }
        
        public func stopAndRemoveAllPollers() {
            _pollers.forEach { _, poller in poller.stop() }
            _pollers.removeAll()
        }
    }
}

// MARK: - GroupPollerCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol CommunityPollerImmutableCacheType: ImmutableCacheType {
    var serversBeingPolled: Set<String> { get }
    var allPollers: [CommunityPollerType] { get }
}

public protocol CommunityPollerCacheType: CommunityPollerImmutableCacheType, MutableCacheType {
    var serversBeingPolled: Set<String> { get }
    var allPollers: [CommunityPollerType] { get }
    
    func startAllPollers()
    @discardableResult func getOrCreatePoller(for info: CommunityPoller.Info) -> CommunityPollerType
    func stopAndRemovePoller(for server: String)
    func stopAndRemoveAllPollers()
}

public extension CommunityPollerCacheType {
    @discardableResult func getOrCreatePoller(for server: String) -> CommunityPollerType {
        return getOrCreatePoller(for: CommunityPoller.Info(server: server, pollFailureCount: 0))
    }
}
