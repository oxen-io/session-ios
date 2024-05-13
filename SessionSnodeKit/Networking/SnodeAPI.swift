// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import Sodium
import GRDB
import SessionUtilitiesKit

public extension Network.RequestType {
    static func message(
        _ message: SnodeMessage,
        in namespace: SnodeAPI.Namespace
    ) -> Network.RequestType<SendMessagesResponse> {
        return Network.RequestType(id: "snodeAPI.sendMessage", args: [message, namespace]) {
            SnodeAPI.sendMessage(message, in: namespace, using: $0)
        }
    }
}

public final class SnodeAPI {
    internal static let sodium: Atomic<Sodium> = Atomic(Sodium())
    
    /// The offset between the user's clock and the Service Node's clock. Used in cases where the
    /// user's clock is incorrect.
    ///
    /// - Note: Should only be accessed from `Threading.workQueue` to avoid race conditions.
    public static var clockOffsetMs: Atomic<Int64> = Atomic(0)
    
    // MARK: - Hardfork version
    
    public static var hardfork = UserDefaults.standard[.hardfork]
    public static var softfork = UserDefaults.standard[.softfork]

    // MARK: - Settings
    
    public static let maxRetryCount: Int = 8
    
    public static func currentOffsetTimestampMs() -> Int64 {
        return Int64(
            Int64(floor(Date().timeIntervalSince1970 * 1000)) +
            SnodeAPI.clockOffsetMs.wrappedValue
        )
    }

    // MARK: - Batching & Polling
    
    public static func poll(
        namespaces: [SnodeAPI.Namespace],
        refreshingConfigHashes: [String] = [],
        from snode: LibSession.Snode,
        swarmPublicKey: String,
        using dependencies: Dependencies
    ) -> AnyPublisher<[SnodeAPI.Namespace: (info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?)], Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        let userX25519PublicKey: String = getUserHexEncodedPublicKey(using: dependencies)
        
        // Prune expired message hashes for this namespace on this service node
        return Just(())
            .setFailureType(to: Error.self)
            .map { _ -> [SnodeAPI.Namespace: String] in
                namespaces.reduce(into: [:]) { result, namespace in
                    guard namespace.shouldFetchSinceLastHash else { return }
                    
                    // Prune expired message hashes for this namespace on this service node
                    SnodeReceivedMessageInfo.pruneExpiredMessageHashInfo(
                        for: snode,
                        namespace: namespace,
                        associatedWith: swarmPublicKey,
                        using: dependencies
                    )
                    
                    result[namespace] = SnodeReceivedMessageInfo
                        .fetchLastNotExpired(
                            for: snode,
                            namespace: namespace,
                            associatedWith: swarmPublicKey,
                            using: dependencies
                        )?
                        .hash
                }
            }
            .tryFlatMap { namespaceLastHash -> AnyPublisher<[SnodeAPI.Namespace: (info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?)], Error> in
                var requests: [any ErasedPreparedRequest] = []
                
                // If we have any config hashes to refresh TTLs then add those requests first
                if !refreshingConfigHashes.isEmpty {
                    requests.append(
                        try SnodeAPI.prepareRequest(
                            request: Request(
                                endpoint: .expire,
                                swarmPublicKey: swarmPublicKey,
                                body: UpdateExpiryRequest(
                                    messageHashes: refreshingConfigHashes,
                                    expiryMs: UInt64(
                                        SnodeAPI.currentOffsetTimestampMs() +
                                        (30 * 24 * 60 * 60 * 1000) // 30 days
                                    ),
                                    extend: true,
                                    pubkey: userX25519PublicKey,
                                    ed25519PublicKey: userED25519KeyPair.publicKey,
                                    ed25519SecretKey: userED25519KeyPair.secretKey,
                                    subkey: nil    // TODO: Need to get this
                                )
                            ),
                            responseType: UpdateExpiryResponse.self,
                            using: dependencies
                        )
                    )
                }
                
                // Determine the maxSize each namespace in the request should take up
                let namespaceMaxSizeMap: [SnodeAPI.Namespace: Int64] = SnodeAPI.Namespace.maxSizeMap(for: namespaces)
                let fallbackSize: Int64 = (namespaceMaxSizeMap.values.min() ?? 1)
                
                // Add the various 'getMessages' requests
                requests.append(
                    contentsOf: try namespaces.map { namespace -> any ErasedPreparedRequest in
                        // Check if this namespace requires authentication
                        guard namespace.requiresReadAuthentication else {
                            return try SnodeAPI.prepareRequest(
                                request: Request(
                                    endpoint: .getMessages,
                                    swarmPublicKey: swarmPublicKey,
                                    body: LegacyGetMessagesRequest(
                                        pubkey: swarmPublicKey,
                                        lastHash: (namespaceLastHash[namespace] ?? ""),
                                        namespace: namespace,
                                        maxCount: nil,
                                        maxSize: namespaceMaxSizeMap[namespace]
                                            .defaulting(to: fallbackSize)
                                    )
                                ),
                                responseType: GetMessagesResponse.self,
                                using: dependencies
                            )
                        }
                        
                        return try SnodeAPI.prepareRequest(
                            request: Request(
                                endpoint: .getMessages,
                                swarmPublicKey: swarmPublicKey,
                                body: GetMessagesRequest(
                                    lastHash: (namespaceLastHash[namespace] ?? ""),
                                    namespace: namespace,
                                    pubkey: swarmPublicKey,
                                    subkey: nil,    // TODO: Need to get this
                                    timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs()),
                                    ed25519PublicKey: userED25519KeyPair.publicKey,
                                    ed25519SecretKey: userED25519KeyPair.secretKey,
                                    maxSize: namespaceMaxSizeMap[namespace]
                                        .defaulting(to: fallbackSize)
                                )
                            ),
                            responseType: GetMessagesResponse.self,
                            using: dependencies
                        )
                    }
                )
                
                // Actually send the request
                return try SnodeAPI
                    .prepareRequest(
                        request: Request(
                            endpoint: .batch,
                            snode: snode,
                            swarmPublicKey: swarmPublicKey,
                            body: Network.BatchRequest(requestsKey: .requests, requests: requests)
                        ),
                        responseType: Network.BatchResponse.self,
                        requireAllBatchResponses: true,
                        using: dependencies
                    )
                    .send(using: dependencies)
                    .map { (_: ResponseInfoType, batchResponse: Network.BatchResponse) -> [SnodeAPI.Namespace: (info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?)] in
                        let messageResponses: [Network.BatchSubResponse<GetMessagesResponse>] = batchResponse
                            .compactMap { $0 as? Network.BatchSubResponse<GetMessagesResponse> }
                        
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
                                sodium: sodium.wrappedValue,
                                userX25519PublicKey: getUserHexEncodedPublicKey(),
                                validationData: refreshingConfigHashes
                            ),
                            let targetResult: UpdateExpiryResponseResult = validResults[snode.ed25519PubkeyHex],
                            let groupedExpiryResult: [UInt64: [String]] = targetResult.changed
                                .updated(with: targetResult.unchanged)
                                .groupedByValue()
                                .nullIfEmpty()
                        {
                            dependencies.storage.writeAsync { db in
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
                                guard let messageResponse: GetMessagesResponse = next.1.body else { return }
                                
                                let namespace: SnodeAPI.Namespace = next.0
                                
                                result[namespace] = (
                                    info: next.1,
                                    data: (
                                        messages: messageResponse.messages
                                            .compactMap { rawMessage -> SnodeReceivedMessage? in
                                                SnodeReceivedMessage(
                                                    snode: snode,
                                                    publicKey: swarmPublicKey,
                                                    namespace: namespace,
                                                    rawMessage: rawMessage
                                                )
                                            },
                                        lastHash: namespaceLastHash[namespace]
                                    )
                                )
                            }
                    }
                    .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
    }
    
    public static func preparedSequence(
        requests: [any ErasedPreparedRequest],
        requireAllBatchResponses: Bool,
        swarmPublicKey: String,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Network.BatchResponse> {
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .sequence,
                    swarmPublicKey: swarmPublicKey,
                    body: Network.BatchRequest(requestsKey: .requests, requests: requests)
                ),
                responseType: Network.BatchResponse.self,
                requireAllBatchResponses: requireAllBatchResponses,
                using: dependencies
            )
    }
    
    /// **Note:** This is the direct request to retrieve messages so should be retrieved automatically from the `poll()` method, in order to call
    /// this directly remove the `@available` line
    @available(*, unavailable, message: "Avoid using this directly, use the pre-built `poll()` method instead")
    public static func getMessages(
        in namespace: SnodeAPI.Namespace,
        from snode: LibSession.Snode,
        swarmPublicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<(info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?), Error> {
        return Deferred {
            Future<String?, Error> { resolver in
                // Prune expired message hashes for this namespace on this service node
                SnodeReceivedMessageInfo.pruneExpiredMessageHashInfo(
                    for: snode,
                    namespace: namespace,
                    associatedWith: swarmPublicKey,
                    using: dependencies
                )
                
                let maybeLastHash: String? = SnodeReceivedMessageInfo
                    .fetchLastNotExpired(
                        for: snode,
                        namespace: namespace,
                        associatedWith: swarmPublicKey,
                        using: dependencies
                    )?
                    .hash
                
                resolver(Result.success(maybeLastHash))
            }
        }
        .tryFlatMap { lastHash -> AnyPublisher<(info: ResponseInfoType, data: GetMessagesResponse?, lastHash: String?), Error> in
            guard namespace.requiresReadAuthentication else {
                return try SnodeAPI
                    .prepareRequest(
                        request: Request(
                            endpoint: .getMessages,
                            snode: snode,
                            swarmPublicKey: swarmPublicKey,
                            body: LegacyGetMessagesRequest(
                                pubkey: swarmPublicKey,
                                lastHash: (lastHash ?? ""),
                                namespace: namespace,
                                maxCount: nil,
                                maxSize: nil
                            )
                        ),
                        responseType: GetMessagesResponse.self,
                        using: dependencies
                    )
                    .send(using: dependencies)
                    .map { info, data in (info, data, lastHash) }
                    .eraseToAnyPublisher()
            }
            
            guard let userED25519KeyPair: KeyPair = Storage.shared.read({ db in Identity.fetchUserEd25519KeyPair(db) }) else {
                throw SnodeAPIError.noKeyPair
            }
            
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .getMessages,
                        snode: snode,
                        swarmPublicKey: swarmPublicKey,
                        body: GetMessagesRequest(
                            lastHash: (lastHash ?? ""),
                            namespace: namespace,
                            pubkey: swarmPublicKey,
                            subkey: nil,
                            timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs()),
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    responseType: GetMessagesResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
                .map { info, data in (info, data, lastHash) }
                .eraseToAnyPublisher()
        }
        .map { info, data, lastHash -> (info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?) in
            return (
                info: info,
                data: data.map { messageResponse -> (messages: [SnodeReceivedMessage], lastHash: String?) in
                    return (
                        messages: messageResponse.messages
                            .compactMap { rawMessage -> SnodeReceivedMessage? in
                                SnodeReceivedMessage(
                                    snode: snode,
                                    publicKey: swarmPublicKey,
                                    namespace: namespace,
                                    rawMessage: rawMessage
                                )
                            },
                        lastHash: lastHash
                    )
                }
            )
        }
        .eraseToAnyPublisher()
    }
    
    public static func getSessionID(
        for onsName: String,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<String, Error> {
        let validationCount = 3
        
        // The name must be lowercased
        let onsName = onsName.lowercased()
        
        // Hash the ONS name using BLAKE2b
        let nameAsData = [UInt8](onsName.data(using: String.Encoding.utf8)!)
        
        guard let nameHash = sodium.wrappedValue.genericHash.hash(message: nameAsData) else {
            return Fail(error: SnodeAPIError.onsHashingFailed)
                .eraseToAnyPublisher()
        }
        
        // Ask 3 different snodes for the Session ID associated with the given name hash
        let base64EncodedNameHash = nameHash.toBase64()
        
        return LibSession
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
                                try response.sessionId(
                                    sodium: sodium.wrappedValue,
                                    nameBytes: nameAsData,
                                    nameHashBytes: nameHash
                                )
                            }
                            .send(using: dependencies)
                            .retry(4)
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
    
    public static func getExpiries(
        swarmPublicKey: String,
        of serverHashes: [String],
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<(ResponseInfoType, GetExpiriesResponse), Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        let sendTimestamp: UInt64 = UInt64(SnodeAPI.currentOffsetTimestampMs())
        
        // FIXME: There is a bug on SS now that a single-hash lookup is not working. Remove it when the bug is fixed
        let serverHashes: [String] = serverHashes.appending("///////////////////////////////////////////") // Fake hash with valid length
        
        do {
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .getExpiries,
                        swarmPublicKey: swarmPublicKey,
                        body: GetExpiriesRequest(
                            messageHashes: serverHashes,
                            pubkey: swarmPublicKey,
                            subkey: nil,
                            timestampMs: sendTimestamp,
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    responseType: GetExpiriesResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    // MARK: - Store
    
    public static func preparedSendMessage(
        _ db: Database,
        message: SnodeMessage,
        in namespace: Namespace,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<SendMessagesResponse> {
        let swarmPublicKey: String = message.recipient
        let userX25519PublicKey: String = getUserHexEncodedPublicKey()
        
        let request: Network.PreparedRequest<SendMessagesResponse> = try {
            // Check if this namespace requires authentication
            guard namespace.requiresWriteAuthentication else {
                return try SnodeAPI.prepareRequest(
                    request: Request(
                        endpoint: .sendMessage,
                        swarmPublicKey: swarmPublicKey,
                        body: LegacySendMessagesRequest(
                            message: message,
                            namespace: namespace
                        )
                    ),
                    responseType: SendMessagesResponse.self,
                    using: dependencies
                )
            }
            
            guard let userED25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db) else {
                throw SnodeAPIError.noKeyPair
            }
            
            return try SnodeAPI.prepareRequest(
                request: Request(
                    endpoint: .sendMessage,
                    swarmPublicKey: swarmPublicKey,
                    body: SendMessageRequest(
                        message: message,
                        namespace: namespace,
                        subkey: nil,
                        timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs()),
                        ed25519PublicKey: userED25519KeyPair.publicKey,
                        ed25519SecretKey: userED25519KeyPair.secretKey
                    )
                ),
                responseType: SendMessagesResponse.self,
                using: dependencies
            )
        }()
        
        return request
            .tryMap { _, response -> SendMessagesResponse in
                try response.validateResultMap(
                    sodium: sodium.wrappedValue,
                    userX25519PublicKey: userX25519PublicKey
                )
                
                return response
            }
    }
    
    public static func sendMessage(
        _ message: SnodeMessage,
        in namespace: Namespace,
        using dependencies: Dependencies
    ) -> AnyPublisher<(ResponseInfoType, SendMessagesResponse), Error> {
        let swarmPublicKey: String = message.recipient
        let userX25519PublicKey: String = getUserHexEncodedPublicKey()
        
        do {
            let request: Network.PreparedRequest<SendMessagesResponse> = try {
                // Check if this namespace requires authentication
                guard namespace.requiresWriteAuthentication else {
                    return try SnodeAPI.prepareRequest(
                        request: Request(
                            endpoint: .sendMessage,
                            swarmPublicKey: swarmPublicKey,
                            body: LegacySendMessagesRequest(
                                message: message,
                                namespace: namespace
                            )
                        ),
                        responseType: SendMessagesResponse.self,
                        using: dependencies
                    )
                }
                
                guard let userED25519KeyPair: KeyPair = Storage.shared.read({ db in Identity.fetchUserEd25519KeyPair(db) }) else {
                    throw SnodeAPIError.noKeyPair
                }
                
                return try SnodeAPI.prepareRequest(
                    request: Request(
                        endpoint: .sendMessage,
                        swarmPublicKey: swarmPublicKey,
                        body: SendMessageRequest(
                            message: message,
                            namespace: namespace,
                            subkey: nil,
                            timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs()),
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    responseType: SendMessagesResponse.self,
                    using: dependencies
                )
            }()
            
            return request
                .tryMap { info, response -> SendMessagesResponse in
                    try response.validateResultMap(
                        sodium: sodium.wrappedValue,
                        userX25519PublicKey: userX25519PublicKey
                    )
                    
                    return response
                }
                .send(using: dependencies)
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    public static func sendConfigMessages(
        _ messages: [(message: SnodeMessage, namespace: Namespace)],
        allObsoleteHashes: [String],
        swarmPublicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Network.BatchResponse, Error> {
        guard !messages.isEmpty || !allObsoleteHashes.isEmpty else {
            return Fail(error: NetworkError.invalidPreparedRequest)
                .eraseToAnyPublisher()
        }
        // TODO: Need to get either the closed group subKey or the userEd25519 key for auth
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        do {
            let userX25519PublicKey: String = getUserHexEncodedPublicKey()
            var requests: [any ErasedPreparedRequest] = try messages
                .map { message, namespace in
                    // Check if this namespace requires authentication
                    guard namespace.requiresWriteAuthentication else {
                        return try SnodeAPI.prepareRequest(
                            request: Request(
                                endpoint: .sendMessage,
                                swarmPublicKey: swarmPublicKey,
                                body: LegacySendMessagesRequest(
                                    message: message,
                                    namespace: namespace
                                )
                            ),
                            responseType: SendMessagesResponse.self,
                            using: dependencies
                        )
                    }
                    
                    return try SnodeAPI.prepareRequest(
                        request: Request(
                            endpoint: .sendMessage,
                            swarmPublicKey: swarmPublicKey,
                            body: SendMessageRequest(
                                message: message,
                                namespace: namespace,
                                subkey: nil,    // TODO: Need to get this
                                timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs()),
                                ed25519PublicKey: userED25519KeyPair.publicKey,
                                ed25519SecretKey: userED25519KeyPair.secretKey
                            )
                        ),
                        responseType: SendMessagesResponse.self,
                        using: dependencies
                    )
                }
            
            // If we had any previous config messages then we should delete them
            if !allObsoleteHashes.isEmpty {
                requests.append(
                    try SnodeAPI.prepareRequest(
                        request: Request(
                            endpoint: .deleteMessages,
                            swarmPublicKey: swarmPublicKey,
                            body: DeleteMessagesRequest(
                                messageHashes: allObsoleteHashes,
                                requireSuccessfulDeletion: false,
                                swarmPublicKey: userX25519PublicKey,
                                ed25519PublicKey: userED25519KeyPair.publicKey,
                                ed25519SecretKey: userED25519KeyPair.secretKey
                            )
                        ),
                        responseType: DeleteMessagesResponse.self,
                        using: dependencies
                    )
                )
            }
            
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .sequence,
                        swarmPublicKey: swarmPublicKey,
                        body: Network.BatchRequest(requestsKey: .requests, requests: requests)
                    ),
                    responseType: Network.BatchResponse.self,
                    requireAllBatchResponses: false,
                    using: dependencies
                )
                .send(using: dependencies)
                .map { _, response in response }
                .eraseToAnyPublisher()
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    // MARK: - Edit
    
    public static func updateExpiry(
        swarmPublicKey: String,
        serverHashes: [String],
        updatedExpiryMs: Int64,
        shortenOnly: Bool? = nil,
        extendOnly: Bool? = nil,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<[String: UpdateExpiryResponseResult], Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        // ShortenOnly and extendOnly cannot be true at the same time
        guard shortenOnly == nil || extendOnly == nil else {
            return Fail(error: NetworkError.invalidPreparedRequest)
                .eraseToAnyPublisher()
        }
        
        // FIXME: There is a bug on SS now that a single-hash lookup is not working. Remove it when the bug is fixed
        let serverHashes: [String] = serverHashes.appending("///////////////////////////////////////////") // Fake hash with valid length
        
        do {
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .expire,
                        swarmPublicKey: swarmPublicKey,
                        body: UpdateExpiryRequest(
                            messageHashes: serverHashes,
                            expiryMs: UInt64(updatedExpiryMs),
                            shorten: shortenOnly,
                            extend: extendOnly,
                            pubkey: swarmPublicKey,
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey,
                            subkey: nil
                        )
                    ),
                    responseType: UpdateExpiryResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
                .tryMap { _, response -> [String: UpdateExpiryResponseResult] in
                    try response.validResultMap(
                        sodium: sodium.wrappedValue,
                        userX25519PublicKey: getUserHexEncodedPublicKey(),
                        validationData: serverHashes
                    )
                }
                .eraseToAnyPublisher()
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    public static func revokeSubkey(
        swarmPublicKey: String,
        subkeyToRevoke: String,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        do {
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .revokeSubaccount,
                        swarmPublicKey: swarmPublicKey,
                        body: RevokeSubkeyRequest(
                            subkeyToRevoke: subkeyToRevoke,
                            pubkey: swarmPublicKey,
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    responseType: RevokeSubkeyResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
                .tryMap { _, response -> Void in
                    try response.validateResultMap(
                        sodium: sodium.wrappedValue,
                        userX25519PublicKey: getUserHexEncodedPublicKey(),
                        validationData: subkeyToRevoke
                    )
                    
                    return ()
                }
                .eraseToAnyPublisher()
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    // MARK: Delete
    
    public static func preparedDeleteMessages(
        _ db: Database,
        swarmPublicKey: String,
        serverHashes: [String],
        requireSuccessfulDeletion: Bool,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<[String: Bool]> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair(db) else { throw SnodeAPIError.noKeyPair }
        
        return try SnodeAPI
            .prepareRequest(
                request: Request(
                    endpoint: .deleteMessages,
                    swarmPublicKey: swarmPublicKey,
                    body: DeleteMessagesRequest(
                        messageHashes: serverHashes,
                        requireSuccessfulDeletion: requireSuccessfulDeletion,
                        swarmPublicKey: swarmPublicKey,
                        ed25519PublicKey: userED25519KeyPair.publicKey,
                        ed25519SecretKey: userED25519KeyPair.secretKey
                    )
                ),
                responseType: DeleteMessagesResponse.self,
                using: dependencies
            )
            .tryMap { _, response -> [String: Bool] in
                let validResultMap: [String: Bool] = try response.validResultMap(
                    sodium: sodium.wrappedValue,
                    userX25519PublicKey: swarmPublicKey,
                    validationData: serverHashes
                )
                
                // If `validResultMap` didn't throw then at least one service node
                // deleted successfully so we should mark the hash as invalid so we
                // don't try to fetch updates using that hash going forward (if we
                // do we would end up re-fetching all old messages)
                Storage.shared.writeAsync { db in
                    try? SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                        db,
                        potentiallyInvalidHashes: serverHashes
                    )
                }
                
                return validResultMap
            }
    }
    
    public static func deleteMessages(
        swarmPublicKey: String,
        serverHashes: [String],
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<[String: Bool], Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        let userX25519PublicKey: String = getUserHexEncodedPublicKey(using: dependencies)
        
        do {
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .deleteMessages,
                        swarmPublicKey: swarmPublicKey,
                        body: DeleteMessagesRequest(
                            messageHashes: serverHashes,
                            requireSuccessfulDeletion: false,
                            swarmPublicKey: userX25519PublicKey,
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    responseType: DeleteMessagesResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
                .tryMap { _, response -> [String: Bool] in
                    let validResultMap: [String: Bool] = try response.validResultMap(
                        sodium: sodium.wrappedValue,
                        userX25519PublicKey: userX25519PublicKey,
                        validationData: serverHashes
                    )
                    
                    // If `validResultMap` didn't throw then at least one service node
                    // deleted successfully so we should mark the hash as invalid so we
                    // don't try to fetch updates using that hash going forward (if we
                    // do we would end up re-fetching all old messages)
                    Storage.shared.writeAsync { db in
                        try? SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                            db,
                            potentiallyInvalidHashes: serverHashes
                        )
                    }
                    
                    return validResultMap
                }
                .eraseToAnyPublisher()
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    /// Clears all the user's data from their swarm. Returns a dictionary of snode public key to deletion confirmation.
    public static func deleteAllMessages(
        namespace: SnodeAPI.Namespace,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<[String: Bool], Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        let userX25519PublicKey: String = getUserHexEncodedPublicKey()
        
        do {
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .deleteAll,
                        swarmPublicKey: userX25519PublicKey,
                        requiresLatestNetworkTime: true,
                        body: DeleteAllMessagesRequest(
                            namespace: namespace,
                            pubkey: userX25519PublicKey,
                            timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs()),
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    responseType: DeleteAllMessagesResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
                .tryMap { info, response -> [String: Bool] in
                    guard let targetInfo: LatestTimestampResponseInfo = info as? LatestTimestampResponseInfo else {
                        throw NetworkError.invalidResponse
                    }
                    
                    return try response.validResultMap(
                        sodium: sodium.wrappedValue,
                        userX25519PublicKey: userX25519PublicKey,
                        validationData: targetInfo.timestampMs
                    )
                }
                .eraseToAnyPublisher()
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    /// Clears all the user's data from their swarm. Returns a dictionary of snode public key to deletion confirmation.
    public static func deleteAllMessages(
        beforeMs: UInt64,
        namespace: SnodeAPI.Namespace,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<[String: Bool], Error> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Fail(error: SnodeAPIError.noKeyPair)
                .eraseToAnyPublisher()
        }
        
        let userX25519PublicKey: String = getUserHexEncodedPublicKey()
        
        do {
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .deleteAllBefore,
                        swarmPublicKey: userX25519PublicKey,
                        requiresLatestNetworkTime: true,
                        body: DeleteAllBeforeRequest(
                            beforeMs: beforeMs,
                            namespace: namespace,
                            pubkey: userX25519PublicKey,
                            timestampMs: UInt64(SnodeAPI.currentOffsetTimestampMs()),
                            ed25519PublicKey: userED25519KeyPair.publicKey,
                            ed25519SecretKey: userED25519KeyPair.secretKey
                        )
                    ),
                    responseType: DeleteAllBeforeResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
                .tryMap { _, response -> [String: Bool] in
                    try response.validResultMap(
                        sodium: sodium.wrappedValue,
                        userX25519PublicKey: userX25519PublicKey,
                        validationData: beforeMs
                    )
                }
                .eraseToAnyPublisher()
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    // MARK: - Internal API
    
    public static func getNetworkTime(
        from snode: LibSession.Snode,
        using dependencies: Dependencies
    ) -> AnyPublisher<UInt64, Error> {
        do {
            return try SnodeAPI
                .prepareRequest(
                    request: Request(
                        endpoint: .getInfo,
                        snode: snode,
                        body: [String: String]()
                    ),
                    responseType: GetNetworkTimestampResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
                .map { _, response in
                    // Assume we've fetched the networkTime in order to send a message to the specified snode, in
                    // which case we want to update the 'clockOffsetMs' value for subsequent requests
                    let offset = (Int64(response.timestamp) - Int64(floor(dependencies.dateNow.timeIntervalSince1970 * 1000)))
                    SnodeAPI.clockOffsetMs.mutate { $0 = offset }
                    
                    return response.timestamp
                }
                .eraseToAnyPublisher()
        }
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    // MARK: - Convenience
    
    private static func prepareRequest<T: Encodable, R: Decodable>(
        request: Request<T, Endpoint>,
        responseType: R.Type,
        requireAllBatchResponses: Bool = true,
        retryCount: Int = 0,
        timeout: TimeInterval = Network.defaultTimeout,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<R> {
        return Network.PreparedRequest<R>(
            request: request,
            urlRequest: try request.generateUrlRequest(using: dependencies),
            responseType: responseType,
            requireAllBatchResponses: requireAllBatchResponses,
            retryCount: retryCount,
            timeout: timeout
        )
        .handleEvents(
            receiveOutput: { _, response in
                switch response {
                    case let snodeResponse as SnodeResponse:
                        // Update the network offset based on the response so subsequent requests have
                        // the correct network offset time
                        let offset = (Int64(snodeResponse.timeOffset) - Int64(floor(dependencies.dateNow.timeIntervalSince1970 * 1000)))
                        SnodeAPI.clockOffsetMs.mutate { $0 = offset }
                        
                        // Extract and store hard fork information if returned
                        guard snodeResponse.hardFork.count > 1 else { break }
                        
                        if snodeResponse.hardFork[1] > softfork {
                            softfork = snodeResponse.hardFork[1]
                            UserDefaults.standard[.softfork] = softfork
                        }
                        
                        if snodeResponse.hardFork[0] > hardfork {
                            hardfork = snodeResponse.hardFork[0]
                            UserDefaults.standard[.hardfork] = hardfork
                            softfork = snodeResponse.hardFork[1]
                            UserDefaults.standard[.softfork] = softfork
                        }
                        
                    default: break
                }
            }
        )
    }
}

// MARK: - Publisher Convenience

public extension Publisher where Output == Set<LibSession.Snode> {
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

// MARK: - Request<T, EndpointType> Convenience

private extension Request {
    init<B: Encodable>(
        endpoint: SnodeAPI.Endpoint,
        swarmPublicKey: String,
        body: B,
        retryCount: Int = SnodeAPI.maxRetryCount
    ) where T == SnodeRequest<B>, Endpoint == SnodeAPI.Endpoint {
        self = Request(
            method: .post,
            endpoint: endpoint,
            swarmPublicKey: swarmPublicKey,
            body: SnodeRequest<B>(
                endpoint: endpoint,
                body: body
            ),
            retryCount: retryCount
        )
    }
    
    init<B: Encodable>(
        endpoint: SnodeAPI.Endpoint,
        snode: LibSession.Snode,
        swarmPublicKey: String? = nil,
        body: B,
        retryCount: Int = SnodeAPI.maxRetryCount
    ) where T == SnodeRequest<B>, Endpoint == SnodeAPI.Endpoint {
        self = Request(
            method: .post,
            endpoint: endpoint,
            snode: snode,
            body: SnodeRequest<B>(
                endpoint: endpoint,
                body: body
            ),
            swarmPublicKey: swarmPublicKey,
            retryCount: retryCount
        )
    }
    
    init<B>(
        endpoint: SnodeAPI.Endpoint,
        swarmPublicKey: String,
        requiresLatestNetworkTime: Bool,
        body: B,
        retryCount: Int = SnodeAPI.maxRetryCount
    ) where T == SnodeRequest<B>, Endpoint == SnodeAPI.Endpoint, B: Encodable & UpdatableTimestamp {
        self = Request(
            method: .post,
            endpoint: endpoint,
            swarmPublicKey: swarmPublicKey,
            requiresLatestNetworkTime: requiresLatestNetworkTime,
            body: SnodeRequest<B>(
                endpoint: endpoint,
                body: body
            ),
            retryCount: retryCount
        )
    }
}
