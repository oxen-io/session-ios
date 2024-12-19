// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

public final class SnodeAPI {
    // MARK: - Settings
    
    public static let maxRetryCount: Int = 8

    // MARK: - Batching & Polling
    
    public typealias PollResponse = [SnodeAPI.Namespace: (info: ResponseInfoType, data: PreparedGetMessagesResponse?)]

    public static func preparedPoll(
        _ db: Database,
        namespaces: [SnodeAPI.Namespace],
        refreshingConfigHashes: [String] = [],
        from snode: LibSession.Snode,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<PollResponse> {
        // Determine the maxSize each namespace in the request should take up
        var requests: [any ErasedPreparedRequest] = []
        let namespaceMaxSizeMap: [SnodeAPI.Namespace: Int64] = SnodeAPI.Namespace.maxSizeMap(for: namespaces)
        let fallbackSize: Int64 = (namespaceMaxSizeMap.values.min() ?? 1)

        // If we have any config hashes to refresh TTLs then add those requests first
        if !refreshingConfigHashes.isEmpty {
            requests.append(
                try SnodeAPI.prepareRequest(
                    request: Request(
                        endpoint: .expire,
                        swarmPublicKey: authMethod.swarmPublicKey,
                        body: UpdateExpiryRequest(
                            messageHashes: refreshingConfigHashes,
                            expiryMs: UInt64(
                                dependencies[cache: .snodeAPI].currentOffsetTimestampMs() +
                                (30 * 24 * 60 * 60 * 1000) // 30 days
                            ),
                            extend: true,
                            authMethod: authMethod
                        )
                    ),
                    responseType: UpdateExpiryResponse.self,
                    using: dependencies
                )
            )
        }

        // Add the various 'getMessages' requests
        requests.append(
            contentsOf: try namespaces.map { namespace -> any ErasedPreparedRequest in
                try SnodeAPI.preparedGetMessages(
                    db,
                    namespace: namespace,
                    snode: snode,
                    maxSize: namespaceMaxSizeMap[namespace]
                        .defaulting(to: fallbackSize),
                    authMethod: authMethod,
                    using: dependencies
                )
            }
        )

        return try preparedBatch(
            requests: requests,
            requireAllBatchResponses: true,
            snode: snode,
            swarmPublicKey: authMethod.swarmPublicKey,
            using: dependencies
        )
        .map { (_: ResponseInfoType, batchResponse: Network.BatchResponse) -> [SnodeAPI.Namespace: (info: ResponseInfoType, data: PreparedGetMessagesResponse?)] in
            let messageResponses: [Network.BatchSubResponse<PreparedGetMessagesResponse>] = batchResponse
                .compactMap { $0 as? Network.BatchSubResponse<PreparedGetMessagesResponse> }
            
            /// Since we have extended the TTL for a number of messages we need to make sure we update the local
            /// `SnodeReceivedMessageInfo.expirationDateMs` values so we don't end up deleting them
            /// incorrectly before they actually expire on the swarm
            if
                !refreshingConfigHashes.isEmpty,
                let refreshTTLSubReponse: Network.BatchSubResponse<UpdateExpiryResponse> = batchResponse
                    .first(where: { $0 is Network.BatchSubResponse<UpdateExpiryResponse> })
                    .asType(Network.BatchSubResponse<UpdateExpiryResponse>.self),
                let refreshTTLResponse: UpdateExpiryResponse = refreshTTLSubReponse.body,
                let validResults: [String: UpdateExpiryResponseResult] = try? refreshTTLResponse.validResultMap(
                    swarmPublicKey: authMethod.swarmPublicKey,
                    validationData: refreshingConfigHashes,
                    using: dependencies
                ),
                let targetResult: UpdateExpiryResponseResult = validResults[snode.ed25519PubkeyHex],
                let groupedExpiryResult: [UInt64: [String]] = targetResult.changed
                    .updated(with: targetResult.unchanged)
                    .groupedByValue()
                    .nullIfEmpty()
            {
                dependencies[singleton: .storage].writeAsync { db in
                    try groupedExpiryResult.forEach { updatedExpiry, hashes in
                        try SnodeReceivedMessageInfo
                            .filter(hashes.contains(SnodeReceivedMessageInfo.Columns.hash))
                            .updateAll(
                                db,
                                SnodeReceivedMessageInfo.Columns.expirationDateMs
                                    .set(to: updatedExpiry)
                            )
                    }
                }
            }
            
            return zip(namespaces, messageResponses)
                .reduce(into: [:]) { result, next in
                    guard let messageResponse: PreparedGetMessagesResponse = next.1.body else { return }
                    
                    result[next.0] = (next.1, messageResponse)
                }

        }
    }
    
    public static func preparedBatch(
        requests: [any ErasedPreparedRequest],
        requireAllBatchResponses: Bool,
        snode: LibSession.Snode? = nil,
        swarmPublicKey: String,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        requestAndPathBuildTimeout: TimeInterval? = nil,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Network.BatchResponse> {
        return try SnodeAPI
            .prepareRequest(
                request: {
                    switch snode {
                        case .none:
                            return try Request(
                                endpoint: .batch,
                                swarmPublicKey: swarmPublicKey,
                                body: Network.BatchRequest(requestsKey: .requests, requests: requests)
                            )
                        
                        case .some(let snode):
                            return try Request(
                                endpoint: .batch,
                                snode: snode,
                                swarmPublicKey: swarmPublicKey,
                                body: Network.BatchRequest(requestsKey: .requests, requests: requests)
                            )
                    }
                }(),
                responseType: Network.BatchResponse.self,
                requireAllBatchResponses: requireAllBatchResponses,
                requestTimeout: requestTimeout,
                requestAndPathBuildTimeout: requestAndPathBuildTimeout,
                using: dependencies
            )
    }
    
    public static func preparedSequence(
        requests: [any ErasedPreparedRequest],
        requireAllBatchResponses: Bool,
        swarmPublicKey: String,
        snodeRetrievalRetryCount: Int,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        requestAndPathBuildTimeout: TimeInterval? = nil,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Network.BatchResponse> {
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .sequence,
                    swarmPublicKey: swarmPublicKey,
                    body: Network.BatchRequest(requestsKey: .requests, requests: requests),
                    snodeRetrievalRetryCount: snodeRetrievalRetryCount
                ),
                responseType: Network.BatchResponse.self,
                requireAllBatchResponses: requireAllBatchResponses,
                requestTimeout: requestTimeout,
                requestAndPathBuildTimeout: requestAndPathBuildTimeout,
                using: dependencies
            )
    }
    
    // MARK: - Retrieve
    
    public typealias PreparedGetMessagesResponse = (messages: [SnodeReceivedMessage], lastHash: String?)
    
    public static func preparedGetMessages(
        _ db: Database,
        namespace: SnodeAPI.Namespace,
        snode: LibSession.Snode,
        maxSize: Int64? = nil,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<PreparedGetMessagesResponse> {
        let maybeLastHash: String? = try SnodeReceivedMessageInfo
            .fetchLastNotExpired(
                db,
                for: snode,
                namespace: namespace,
                swarmPublicKey: authMethod.swarmPublicKey,
                using: dependencies
            )?
            .hash
        let preparedRequest: Network.PreparedRequest<GetMessagesResponse> = try {
            // Check if this namespace requires authentication
            guard namespace.requiresReadAuthentication else {
                return try SnodeAPI.prepareRequest(
                    request: Request(
                        endpoint: .getMessages,
                        swarmPublicKey: authMethod.swarmPublicKey,
                        body: LegacyGetMessagesRequest(
                            pubkey: authMethod.swarmPublicKey,
                            lastHash: (maybeLastHash ?? ""),
                            namespace: namespace,
                            maxCount: nil,
                            maxSize: maxSize
                        )
                    ),
                    responseType: GetMessagesResponse.self,
                    using: dependencies
                )
            }

            return try SnodeAPI.prepareRequest(
                request: Request(
                    endpoint: .getMessages,
                    swarmPublicKey: authMethod.swarmPublicKey,
                    body: GetMessagesRequest(
                        lastHash: (maybeLastHash ?? ""),
                        namespace: namespace,
                        authMethod: authMethod,
                        timestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs(),
                        maxSize: maxSize
                    )
                ),
                responseType: GetMessagesResponse.self,
                using: dependencies
            )
        }()
        
        return preparedRequest
            .map { _, response -> (messages: [SnodeReceivedMessage], lastHash: String?) in
                return (
                    response.messages.compactMap { rawMessage -> SnodeReceivedMessage? in
                        SnodeReceivedMessage(
                            snode: snode,
                            publicKey: authMethod.swarmPublicKey,
                            namespace: namespace,
                            rawMessage: rawMessage
                        )
                    },
                    maybeLastHash
                )
            }
    }
    
    public static func getSessionID(
        for onsName: String,
        using dependencies: Dependencies
    ) -> AnyPublisher<String, Error> {
        let validationCount = 3
        
        // The name must be lowercased
        let onsName = onsName.lowercased()
        
        // Hash the ONS name using BLAKE2b
        guard
            let nameAsData: [UInt8] = onsName.data(using: .utf8).map({ Array($0) }),
            let nameHash = dependencies[singleton: .crypto].generate(.hash(message: nameAsData))
        else {
            return Fail(error: SnodeAPIError.onsHashingFailed)
                .eraseToAnyPublisher()
        }
        
        // Ask 3 different snodes for the Session ID associated with the given name hash
        let base64EncodedNameHash = nameHash.toBase64()
        
        return dependencies[singleton: .network]
            .getRandomNodes(count: validationCount)
            .tryFlatMap { nodes in
                Publishers.MergeMany(
                    try nodes.map { snode in
                        try SnodeAPI
                            .prepareRequest(
                                request: Request(
                                    endpoint: .oxenDaemonRPCCall,
                                    snode: snode,
                                    body: OxenDaemonRPCRequest(
                                        endpoint: .daemonOnsResolve,
                                        body: ONSResolveRequest(
                                            type: 0, // type 0 means Session
                                            base64EncodedNameHash: base64EncodedNameHash
                                        )
                                    )
                                ),
                                responseType: ONSResolveResponse.self,
                                using: dependencies
                            )
                            .tryMap { _, response -> String in
                                try dependencies[singleton: .crypto].tryGenerate(
                                    .sessionId(name: onsName, response: response)
                                )
                            }
                            .send(using: dependencies)
                            .map { _, sessionId in sessionId }
                            .eraseToAnyPublisher()
                    }
                )
            }
            .collect()
            .tryMap { results -> String in
                guard results.count == validationCount, Set(results).count == 1 else {
                    throw SnodeAPIError.onsValidationFailed
                }
                
                return results[0]
            }
            .eraseToAnyPublisher()
    }
    
    public static func preparedGetExpiries(
        of serverHashes: [String],
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<GetExpiriesResponse> {
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .getExpiries,
                    swarmPublicKey: authMethod.swarmPublicKey,
                    body: GetExpiriesRequest(
                        messageHashes: serverHashes,
                        authMethod: authMethod,
                        timestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                    )
                ),
                responseType: GetExpiriesResponse.self,
                using: dependencies
            )
    }
    
    // MARK: - Store
    
    public static func preparedSendMessage(
        message: SnodeMessage,
        in namespace: Namespace,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<SendMessagesResponse> {
        let request: Network.PreparedRequest<SendMessagesResponse> = try {
            // Check if this namespace requires authentication
            guard namespace.requiresWriteAuthentication else {
                return try SnodeAPI.prepareRequest(
                    request: Request(
                        endpoint: .sendMessage,
                        swarmPublicKey: authMethod.swarmPublicKey,
                        body: LegacySendMessagesRequest(
                            message: message,
                            namespace: namespace
                        ),
                        snodeRetrievalRetryCount: 0   // The SendMessageJob already has a retry mechanism
                    ),
                    responseType: SendMessagesResponse.self,
                    requestAndPathBuildTimeout: Network.defaultTimeout,
                    using: dependencies
                )
            }
            
            return try SnodeAPI.prepareRequest(
                request: Request(
                    endpoint: .sendMessage,
                    swarmPublicKey: authMethod.swarmPublicKey,
                    body: SendMessageRequest(
                        message: message,
                        namespace: namespace,
                        authMethod: authMethod,
                        timestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                    ),
                    snodeRetrievalRetryCount: 0   // The SendMessageJob already has a retry mechanism
                ),
                responseType: SendMessagesResponse.self,
                requestAndPathBuildTimeout: Network.defaultTimeout,
                using: dependencies
            )
        }()
        
        return request
            .tryMap { _, response -> SendMessagesResponse in
                try response.validateResultMap(
                    swarmPublicKey: authMethod.swarmPublicKey,
                    using: dependencies
                )

                return response
            }
    }
    
    // MARK: - Edit
    
    public static func preparedUpdateExpiry(
        serverHashes: [String],
        updatedExpiryMs: Int64,
        shortenOnly: Bool? = nil,
        extendOnly: Bool? = nil,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<[String: UpdateExpiryResponseResult]> {
        // ShortenOnly and extendOnly cannot be true at the same time
        guard shortenOnly == nil || extendOnly == nil else { throw NetworkError.invalidPreparedRequest }
        
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .expire,
                    swarmPublicKey: authMethod.swarmPublicKey,
                    body: UpdateExpiryRequest(
                        messageHashes: serverHashes,
                        expiryMs: UInt64(updatedExpiryMs),
                        shorten: shortenOnly,
                        extend: extendOnly,
                        authMethod: authMethod
                    )
                ),
                responseType: UpdateExpiryResponse.self,
                using: dependencies
            )
            .tryMap { _, response -> [String: UpdateExpiryResponseResult] in
                try response.validResultMap(
                    swarmPublicKey: authMethod.swarmPublicKey,
                    validationData: serverHashes,
                    using: dependencies
                )
            }
    }
    
    public static func preparedRevokeSubaccounts(
        subaccountsToRevoke: [[UInt8]],
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Void> {
        let timestampMs: UInt64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .revokeSubaccount,
                    swarmPublicKey: authMethod.swarmPublicKey,
                    body: RevokeSubaccountRequest(
                        subaccountsToRevoke: subaccountsToRevoke,
                        authMethod: authMethod,
                        timestampMs: timestampMs
                    )
                ),
                responseType: RevokeSubaccountResponse.self,
                using: dependencies
            )
            .tryMap { _, response -> Void in
                try response.validateResultMap(
                    swarmPublicKey: authMethod.swarmPublicKey,
                    validationData: (subaccountsToRevoke, timestampMs),
                    using: dependencies
                )
                
                return ()
            }
    }
    
    public static func preparedUnrevokeSubaccounts(
        subaccountsToUnrevoke: [[UInt8]],
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Void> {
        let timestampMs: UInt64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .unrevokeSubaccount,
                    swarmPublicKey: authMethod.swarmPublicKey,
                    body: UnrevokeSubaccountRequest(
                        subaccountsToUnrevoke: subaccountsToUnrevoke,
                        authMethod: authMethod,
                        timestampMs: timestampMs
                    )
                ),
                responseType: UnrevokeSubaccountResponse.self,
                using: dependencies
            )
            .tryMap { _, response -> Void in
                try response.validateResultMap(
                    swarmPublicKey: authMethod.swarmPublicKey,
                    validationData: (subaccountsToUnrevoke, timestampMs),
                    using: dependencies
                )
                
                return ()
            }
    }
    
    // MARK: - Delete
    
    public static func preparedDeleteMessages(
        serverHashes: [String],
        requireSuccessfulDeletion: Bool,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<[String: Bool]> {
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .deleteMessages,
                    swarmPublicKey: authMethod.swarmPublicKey,
                    body: DeleteMessagesRequest(
                        messageHashes: serverHashes,
                        requireSuccessfulDeletion: requireSuccessfulDeletion,
                        authMethod: authMethod
                    )
                ),
                responseType: DeleteMessagesResponse.self,
                using: dependencies
            )
            .tryMap { _, response -> [String: Bool] in
                let validResultMap: [String: Bool] = try response.validResultMap(
                    swarmPublicKey: authMethod.swarmPublicKey,
                    validationData: serverHashes,
                    using: dependencies
                )
                
                // If `validResultMap` didn't throw then at least one service node
                // deleted successfully so we should mark the hash as invalid so we
                // don't try to fetch updates using that hash going forward (if we
                // do we would end up re-fetching all old messages)
                dependencies[singleton: .storage].writeAsync { db in
                    try? SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                        db,
                        potentiallyInvalidHashes: serverHashes
                    )
                }
                
                return validResultMap
            }
    }
    

    /// Clears all the user's data from their swarm. Returns a dictionary of snode public key to deletion confirmation.
    public static func preparedDeleteAllMessages(
        namespace: SnodeAPI.Namespace,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        requestAndPathBuildTimeout: TimeInterval? = nil,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<[String: Bool]> {
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .deleteAll,
                    swarmPublicKey: authMethod.swarmPublicKey,
                    requiresLatestNetworkTime: true,
                    body: DeleteAllMessagesRequest(
                        namespace: namespace,
                        authMethod: authMethod,
                        timestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                    ),
                    snodeRetrievalRetryCount: 0
                ),
                responseType: DeleteAllMessagesResponse.self,
                requestTimeout: requestTimeout,
                requestAndPathBuildTimeout: requestAndPathBuildTimeout,
                using: dependencies
            )
            .tryMap { info, response -> [String: Bool] in
                guard let targetInfo: LatestTimestampResponseInfo = info as? LatestTimestampResponseInfo else {
                    throw NetworkError.invalidResponse
                }
                
                return try response.validResultMap(
                    swarmPublicKey: authMethod.swarmPublicKey,
                    validationData: targetInfo.timestampMs,
                    using: dependencies
                )
            }
    }
    
    /// Clears all the user's data from their swarm. Returns a dictionary of snode public key to deletion confirmation.
    public static func preparedDeleteAllMessages(
        beforeMs: UInt64,
        namespace: SnodeAPI.Namespace,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<[String: Bool]> {
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .deleteAllBefore,
                    swarmPublicKey: authMethod.swarmPublicKey,
                    requiresLatestNetworkTime: true,
                    body: DeleteAllBeforeRequest(
                        beforeMs: beforeMs,
                        namespace: namespace,
                        authMethod: authMethod,
                        timestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                    )
                ),
                responseType: DeleteAllMessagesResponse.self,
                retryCount: maxRetryCount,
                using: dependencies
            )
            .tryMap { _, response -> [String: Bool] in
                try response.validResultMap(
                    swarmPublicKey: authMethod.swarmPublicKey,
                    validationData: beforeMs,
                    using: dependencies
                )
            }
    }
    
    // MARK: - Internal API
    
    public static func preparedGetNetworkTime(
        from snode: LibSession.Snode,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<UInt64> {
        return try SnodeAPI
            .prepareRequest(
                request: Request<SnodeRequest<[String: String]>, Endpoint>(
                    endpoint: .getInfo,
                    snode: snode,
                    body: [:]
                ),
                responseType: GetNetworkTimestampResponse.self,
                using: dependencies
            )
            .map { _, response in
                // Assume we've fetched the networkTime in order to send a message to the specified snode, in
                // which case we want to update the 'clockOffsetMs' value for subsequent requests
                let offset = (Int64(response.timestamp) - Int64(floor(dependencies.dateNow.timeIntervalSince1970 * 1000)))
                dependencies.mutate(cache: .snodeAPI) { $0.setClockOffsetMs(offset) }

                return response.timestamp
            }
    }
    
    // MARK: - Convenience
    
    private static func prepareRequest<T: Encodable, R: Decodable>(
        request: Request<T, Endpoint>,
        responseType: R.Type,
        requireAllBatchResponses: Bool = true,
        retryCount: Int = 0,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        requestAndPathBuildTimeout: TimeInterval? = nil,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<R> {
        return try Network.PreparedRequest<R>(
            request: request,
            responseType: responseType,
            requireAllBatchResponses: requireAllBatchResponses,
            retryCount: retryCount,
            requestTimeout: requestTimeout,
            requestAndPathBuildTimeout: requestAndPathBuildTimeout,
            using: dependencies
        )
        .handleEvents(
            receiveOutput: { _, response in
                switch response {
                    case let snodeResponse as SnodeResponse:
                        // Update the network offset based on the response so subsequent requests have
                        // the correct network offset time
                        let offset = (Int64(snodeResponse.timeOffset) - Int64(floor(dependencies.dateNow.timeIntervalSince1970 * 1000)))
                        dependencies.mutate(cache: .snodeAPI) {
                            $0.setClockOffsetMs(offset)
                            
                            // Extract and store hard fork information if returned
                            guard snodeResponse.hardForkVersion.count > 1 else { return }
                            
                            if snodeResponse.hardForkVersion[1] > $0.softfork {
                                $0.softfork = snodeResponse.hardForkVersion[1]
                                dependencies[defaults: .standard, key: .hardfork] = $0.softfork
                            }
                            
                            if snodeResponse.hardForkVersion[0] > $0.hardfork {
                                $0.hardfork = snodeResponse.hardForkVersion[0]
                                dependencies[defaults: .standard, key: .hardfork] = $0.hardfork
                                $0.softfork = snodeResponse.hardForkVersion[1]
                                dependencies[defaults: .standard, key: .softfork] = $0.softfork
                            }
                        }
                        
                    default: break
                }
            }
        )
    }
}

// MARK: - Publisher Convenience

public extension Publisher where Output == Set<LibSession.Snode> {
    func tryMapWithRandomSnode<T>(
        using dependencies: Dependencies,
        _ transform: @escaping (LibSession.Snode) throws -> T
    ) -> AnyPublisher<T, Error> {
        return self
            .tryMap { swarm -> T in
                var remainingSnodes: Set<LibSession.Snode> = swarm
                let snode: LibSession.Snode = try dependencies.popRandomElement(&remainingSnodes) ?? {
                    throw SnodeAPIError.insufficientSnodes
                }()
                
                return try transform(snode)
            }
            .eraseToAnyPublisher()
    }
    
    func tryFlatMapWithRandomSnode<T, P>(
        maxPublishers: Subscribers.Demand = .unlimited,
        retry retries: Int = 0,
        drainBehaviour: Atomic<SwarmDrainBehaviour> = .alwaysRandom,
        using dependencies: Dependencies,
        _ transform: @escaping (LibSession.Snode) throws -> P
    ) -> AnyPublisher<T, Error> where T == P.Output, P: Publisher, P.Failure == Error {
        return self
            .mapError { $0 }
            .flatMap(maxPublishers: maxPublishers) { swarm -> AnyPublisher<T, Error> in
                // If we don't want to reuse a specific snode multiple times then just grab a
                // random one from the swarm every time
                var remainingSnodes: Set<LibSession.Snode> = {
                    switch drainBehaviour.wrappedValue {
                        case .alwaysRandom: return swarm
                        case .limitedReuse(_, let targetSnode, _, let usedSnodes, let swarmHash):
                            // If we've used all of the snodes or the swarm has changed then reset the used list
                            guard swarmHash == swarm.hashValue && (targetSnode != nil || usedSnodes != swarm) else {
                                drainBehaviour.mutate { $0 = $0.reset() }
                                return swarm
                            }
                            
                            return swarm.subtracting(usedSnodes)
                    }
                }()
                var lastError: Error?
                
                return Just(())
                    .setFailureType(to: Error.self)
                    .tryFlatMap(maxPublishers: maxPublishers) { _ -> AnyPublisher<T, Error> in
                        let snode: LibSession.Snode = try {
                            switch drainBehaviour.wrappedValue {
                                case .limitedReuse(_, .some(let targetSnode), _, _, _): return targetSnode
                                default: break
                            }
                            
                            // Select the next snode
                            return try dependencies.popRandomElement(&remainingSnodes) ?? {
                                throw SnodeAPIError.ranOutOfRandomSnodes(lastError)
                            }()
                        }()
                        drainBehaviour.mutate { $0 = $0.use(snode: snode, from: swarm) }
                        
                        return try transform(snode)
                            .eraseToAnyPublisher()
                    }
                    .mapError { error in
                        // Prevent nesting the 'ranOutOfRandomSnodes' errors
                        switch error {
                            case SnodeAPIError.ranOutOfRandomSnodes: break
                            default: lastError = error
                        }
                        
                        return error
                    }
                    .retry(retries)
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
}

// MARK: - SnodeAPI Cache

public extension SnodeAPI {
    class Cache: SnodeAPICacheType {
        private let dependencies: Dependencies
        public var hardfork: Int
        public var softfork: Int
        public var clockOffsetMs: Int64 = 0
        
        init(using dependencies: Dependencies) {
            self.dependencies = dependencies
            self.hardfork = dependencies[defaults: .standard, key: .hardfork]
            self.softfork = dependencies[defaults: .standard, key: .softfork]
        }
        
        public func currentOffsetTimestampMs<T: Numeric>() -> T {
            let timestampNowMs: Int64 = (Int64(floor(dependencies.dateNow.timeIntervalSince1970 * 1000)) + clockOffsetMs)
            
            guard let convertedTimestampNowMs: T = T(exactly: timestampNowMs) else {
                Log.critical("[SnodeAPI.Cache] Failed to convert the timestamp to the desired type: \(type(of: T.self)).")
                return 0
            }
            
            return convertedTimestampNowMs
        }
        
        public func setClockOffsetMs(_ clockOffsetMs: Int64) {
            self.clockOffsetMs = clockOffsetMs
        }
    }
}

public extension Cache {
    static let snodeAPI: CacheConfig<SnodeAPICacheType, SnodeAPIImmutableCacheType> = Dependencies.create(
        identifier: "snodeAPI",
        createInstance: { dependencies in SnodeAPI.Cache(using: dependencies) },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - SnodeAPICacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol SnodeAPIImmutableCacheType: ImmutableCacheType {
    /// The last seen storage server hard fork version.
    var hardfork: Int { get }
    
    /// The last seen storage server soft fork version.
    var softfork: Int { get }

    /// The offset between the user's clock and the Service Node's clock. Used in cases where the
    /// user's clock is incorrect.
    var clockOffsetMs: Int64 { get }
    
    /// Tthe current user clock timestamp in milliseconds offset by the difference between the user's clock and the clock of the most
    /// recent Service Node's that was communicated with.
    func currentOffsetTimestampMs<T: Numeric>() -> T
}

public protocol SnodeAPICacheType: SnodeAPIImmutableCacheType, MutableCacheType {
    /// The last seen storage server hard fork version.
    var hardfork: Int { get set }
    
    /// The last seen storage server soft fork version.
    var softfork: Int { get set }

    /// A function to update the offset between the user's clock and the Service Node's clock.
    func setClockOffsetMs(_ clockOffsetMs: Int64)
}
