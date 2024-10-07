// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - SwarmPollerType

public protocol SwarmPollerType {
    typealias PollResponse = [ProcessedMessage]
    
    var receivedPollResponse: AnyPublisher<PollResponse, Never> { get }
    
    func startIfNeeded()
    func stop()
}

// MARK: - SwarmPoller

public class SwarmPoller: SwarmPollerType & PollerType {
    public let dependencies: Dependencies
    public let pollerQueue: DispatchQueue
    public let pollerName: String
    public let pollerDestination: PollerDestination
    public let pollerDrainBehaviour: Atomic<SwarmDrainBehaviour>
    public let logStartAndStopCalls: Bool
    public var receivedPollResponse: AnyPublisher<PollResponse, Never> {
        receivedPollResponseSubject.eraseToAnyPublisher()
    }
    
    public var isPolling: Bool = false
    public var pollCount: Int = 0
    public var failureCount: Int
    public var lastPollStart: TimeInterval = 0
    public var cancellable: AnyCancellable?
    
    private let namespaces: [SnodeAPI.Namespace]
    private let customAuthMethod: AuthenticationMethod?
    private let shouldStoreMessages: Bool
    private let receivedPollResponseSubject: PassthroughSubject<PollResponse, Never> = PassthroughSubject()

    // MARK: - Initialization
    
    required public init(
        pollerName: String,
        pollerQueue: DispatchQueue,
        pollerDestination: PollerDestination,
        pollerDrainBehaviour: SwarmDrainBehaviour,
        namespaces: [SnodeAPI.Namespace],
        failureCount: Int = 0,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        customAuthMethod: AuthenticationMethod? = nil,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.pollerName = pollerName
        self.pollerQueue = pollerQueue
        self.pollerDestination = pollerDestination
        self.pollerDrainBehaviour = Atomic(pollerDrainBehaviour)
        self.namespaces = namespaces
        self.failureCount = failureCount
        self.customAuthMethod = customAuthMethod
        self.shouldStoreMessages = shouldStoreMessages
        self.logStartAndStopCalls = logStartAndStopCalls
    }
    
    // MARK: - Abstract Methods
    
    /// Calculate the delay which should occur before the next poll
    public func nextPollDelay() -> TimeInterval {
        preconditionFailure("abstract class - override in subclass")
    }
    
    /// Perform and logic which should occur when the poll errors, will stop polling if `false` is returned
    public func handlePollError(_ error: Error, _ lastError: Error?) -> PollerErrorResponse {
        preconditionFailure("abstract class - override in subclass")
    }

    // MARK: - Private API
    
    /// Polls based on it's configuration and processes any messages, returning an array of messages that were
    /// successfully processed
    ///
    /// **Note:** The returned messages will have already been processed by the `Poller`, they are only returned
    /// for cases where we need explicit/custom behaviours to occur (eg. Onboarding)
    public func poll(forceSynchronousProcessing: Bool) -> AnyPublisher<PollResult, Error> {
        let pollerQueue: DispatchQueue = self.pollerQueue
        let configHashes: [String] = dependencies.mutate(cache: .libSession) { $0.configHashes(for: pollerDestination.target) }
        
        /// Fetch the messages
        return dependencies[singleton: .network]
            .getSwarm(for: pollerDestination.target)
            .tryFlatMapWithRandomSnode(drainBehaviour: pollerDrainBehaviour, using: dependencies) { [pollerDestination, customAuthMethod, namespaces, dependencies] snode -> AnyPublisher<Network.PreparedRequest<SnodeAPI.PollResponse>, Error> in
                dependencies[singleton: .storage].readPublisher { db -> Network.PreparedRequest<SnodeAPI.PollResponse> in
                    let authMethod: AuthenticationMethod = try (customAuthMethod ?? Authentication.with(
                        db,
                        swarmPublicKey: pollerDestination.target,
                        using: dependencies
                    ))
                    
                    return try SnodeAPI.preparedPoll(
                        db,
                        namespaces: namespaces,
                        refreshingConfigHashes: configHashes,
                        from: snode,
                        authMethod: authMethod,
                        using: dependencies
                    )
                }
            }
            .flatMap { [dependencies] request in request.send(using: dependencies) }
            .flatMap { [pollerDestination, shouldStoreMessages, dependencies] (_: ResponseInfoType, namespacedResults: SnodeAPI.PollResponse) -> AnyPublisher<(configMessageJobs: [Job], standardMessageJobs: [Job], pollResult: PollResult), Error> in
                // Get all of the messages and sort them by their required 'processingOrder'
                let sortedMessages: [(namespace: SnodeAPI.Namespace, messages: [SnodeReceivedMessage])] = namespacedResults
                    .compactMap { namespace, result in (result.data?.messages).map { (namespace, $0) } }
                    .sorted { lhs, rhs in lhs.namespace.processingOrder < rhs.namespace.processingOrder }
                let rawMessageCount: Int = sortedMessages.map { $0.messages.count }.reduce(0, +)
                
                // No need to do anything if there are no messages
                guard rawMessageCount > 0 else {
                    return Just(([], [], ([], 0, 0, false)))
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                // Otherwise process the messages and add them to the queue for handling
                let lastHashes: [String] = namespacedResults
                    .compactMap { $0.value.data?.lastHash }
                let otherKnownHashes: [String] = namespacedResults
                    .filter { $0.key.shouldFetchSinceLastHash }
                    .compactMap { $0.value.data?.messages.map { $0.info.hash } }
                    .reduce([], +)
                var messageCount: Int = 0
                var processedMessages: [ProcessedMessage] = []
                var hadValidHashUpdate: Bool = false
                
                return dependencies[singleton: .storage].writePublisher { db -> (configMessageJobs: [Job], standardMessageJobs: [Job], pollResult: PollResult) in
                    let allProcessedMessages: [ProcessedMessage] = sortedMessages
                        .compactMap { namespace, messages -> [ProcessedMessage]? in
                            let processedMessages: [ProcessedMessage] = messages
                                .compactMap { message -> ProcessedMessage? in
                                    do {
                                        return try Message.processRawReceivedMessage(
                                            db,
                                            rawMessage: message,
                                            swarmPublicKey: pollerDestination.target,
                                            shouldStoreMessages: shouldStoreMessages,
                                            using: dependencies
                                        )
                                    }
                                    catch {
                                        switch error {
                                            /// Ignore duplicate & selfSend message errors (and don't bother logging them as there
                                            /// will be a lot since we each service node duplicates messages)
                                            case DatabaseError.SQLITE_CONSTRAINT_UNIQUE,
                                                DatabaseError.SQLITE_CONSTRAINT,    /// Sometimes thrown for UNIQUE
                                                MessageReceiverError.duplicateMessage,
                                                MessageReceiverError.duplicateControlMessage,
                                                MessageReceiverError.selfSend:
                                                break
                                                
                                            case MessageReceiverError.duplicateMessageNewSnode:
                                                hadValidHashUpdate = true
                                                break
                                                
                                            case DatabaseError.SQLITE_ABORT:
                                                Log.warn(.poller, "Failed to the database being suspended (running in background with no background task).")
                                                
                                            default: Log.error(.poller, "Failed to deserialize envelope due to error: \(error).")
                                        }
                                        
                                        return nil
                                    }
                                }
                            
                            /// If this message should be handled by this poller and should be handled  synchronously then do so here before
                            /// processing the next namespace
                            guard shouldStoreMessages && namespace.shouldHandleSynchronously else {
                                return processedMessages
                            }
                            
                            if namespace.isConfigNamespace {
                                do {
                                    /// Process config messages all at once in case they are multi-part messages
                                    try dependencies.mutate(cache: .libSession) {
                                        try $0.handleConfigMessages(
                                            db,
                                            swarmPublicKey: pollerDestination.target,
                                            messages: ConfigMessageReceiveJob
                                                .Details(messages: processedMessages)
                                                .messages
                                        )
                                    }
                                }
                                catch { Log.error(.poller, "Failed to handle processed config message due to error: \(error).") }
                            }
                            else {
                                /// Individually process non-config messages
                                processedMessages.forEach { processedMessage in
                                    guard case .standard(let threadId, let threadVariant, let proto, let messageInfo) = processedMessage else {
                                        return
                                    }
                                    
                                    do {
                                        try MessageReceiver.handle(
                                            db,
                                            threadId: threadId,
                                            threadVariant: threadVariant,
                                            message: messageInfo.message,
                                            serverExpirationTimestamp: messageInfo.serverExpirationTimestamp,
                                            associatedWithProto: proto,
                                            using: dependencies
                                        )
                                    }
                                    catch { Log.error(.poller, "Failed to handle processed message due to error: \(error).") }
                                }
                            }
                            
                            return nil
                        }
                        .flatMap { $0 }
                    
                    // If we don't want to store the messages then no need to continue (don't want
                    // to create message receive jobs or mess with cached hashes)
                    guard shouldStoreMessages else {
                        messageCount += allProcessedMessages.count
                        processedMessages += allProcessedMessages
                        return ([], [], (processedMessages, rawMessageCount, messageCount, hadValidHashUpdate))
                    }
                    
                    // Add a job to process the config messages first
                    var configMessageJobs: [Job] = allProcessedMessages
                        .filter { $0.isConfigMessage && !$0.namespace.shouldHandleSynchronously }
                        .grouped { $0.threadId }
                        .compactMap { threadId, threadMessages in
                            messageCount += threadMessages.count
                            processedMessages += threadMessages
                            
                            let job: Job? = Job(
                                variant: .configMessageReceive,
                                behaviour: .runOnce,
                                threadId: threadId,
                                details: ConfigMessageReceiveJob.Details(messages: threadMessages)
                            )
                            
                            // If we are force-polling then add to the JobRunner so they are
                            // persistent and will retry on the next app run if they fail but
                            // don't let them auto-start
                            return dependencies[singleton: .jobRunner].add(
                                db,
                                job: job,
                                canStartJob: (
                                    !forceSynchronousProcessing &&
                                    !dependencies[singleton: .appContext].isInBackground
                                )
                            )
                        }
                    let configJobIds: [Int64] = configMessageJobs.compactMap { $0.id }
                    
                    // Add jobs for processing non-config messages which are dependant on the config message
                    // processing jobs
                    var standardMessageJobs: [Job] = allProcessedMessages
                        .filter { !$0.isConfigMessage && !$0.namespace.shouldHandleSynchronously }
                        .grouped { $0.threadId }
                        .compactMap { threadId, threadMessages in
                            messageCount += threadMessages.count
                            processedMessages += threadMessages
                            
                            let job: Job? = Job(
                                variant: .messageReceive,
                                behaviour: .runOnce,
                                threadId: threadId,
                                details: MessageReceiveJob.Details(messages: threadMessages)
                            )
                            
                            // If we are force-polling then add to the JobRunner so they are
                            // persistent and will retry on the next app run if they fail but
                            // don't let them auto-start
                            let updatedJob: Job? = dependencies[singleton: .jobRunner].add(
                                db,
                                job: job,
                                canStartJob: (
                                    !forceSynchronousProcessing &&
                                    !dependencies[singleton: .appContext].isInBackground
                                )
                            )
                            
                            // Create the dependency between the jobs (config processing should happen before
                            // standard message processing)
                            if let updatedJobId: Int64 = updatedJob?.id {
                                do {
                                    try configJobIds.forEach { configJobId in
                                        try JobDependencies(
                                            jobId: updatedJobId,
                                            dependantId: configJobId
                                        )
                                        .insert(db)
                                    }
                                }
                                catch {
                                    Log.warn(.poller, "Failed to add dependency between config processing and non-config processing messageReceive jobs.")
                                }
                            }
                            
                            return updatedJob
                        }
                    
                    // Clean up message hashes and add some logs about the poll results
                    if sortedMessages.isEmpty && !hadValidHashUpdate {
                        // Update the cached validity of the messages
                        try SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                            db,
                            potentiallyInvalidHashes: lastHashes,
                            otherKnownValidHashes: otherKnownHashes
                        )
                    }
                    
                    return (configMessageJobs, standardMessageJobs, (processedMessages, rawMessageCount, messageCount, hadValidHashUpdate))
                }
            }
            .flatMap { [dependencies] (configMessageJobs: [Job], standardMessageJobs: [Job], pollResult: PollResult) -> AnyPublisher<PollResult, Error> in
                // If we don't want to forcible process the response synchronously then just finish immediately
                guard forceSynchronousProcessing else {
                    return Just(pollResult)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                // We want to try to handle the receive jobs immediately in the background
                return Publishers
                    .MergeMany(
                        configMessageJobs.map { job -> AnyPublisher<Void, Error> in
                            Deferred {
                                Future<Void, Error> { resolver in
                                    // Note: In the background we just want jobs to fail silently
                                    ConfigMessageReceiveJob.run(
                                        job,
                                        queue: pollerQueue,
                                        success: { _, _ in resolver(Result.success(())) },
                                        failure: { _, _, _ in resolver(Result.success(())) },
                                        deferred: { _ in resolver(Result.success(())) },
                                        using: dependencies
                                    )
                                }
                            }
                            .eraseToAnyPublisher()
                        }
                    )
                    .collect()
                    .flatMap { _ in
                        Publishers
                            .MergeMany(
                                standardMessageJobs.map { job -> AnyPublisher<Void, Error> in
                                    Deferred {
                                        Future<Void, Error> { resolver in
                                            // Note: In the background we just want jobs to fail silently
                                            MessageReceiveJob.run(
                                                job,
                                                queue: pollerQueue,
                                                success: { _, _ in resolver(Result.success(())) },
                                                failure: { _, _, _ in resolver(Result.success(())) },
                                                deferred: { _ in resolver(Result.success(())) },
                                                using: dependencies
                                            )
                                        }
                                    }
                                    .eraseToAnyPublisher()
                                }
                            )
                            .collect()
                    }
                    .map { _ in pollResult }
                    .eraseToAnyPublisher()
            }
            .handleEvents(
                receiveOutput: { [weak self] (pollResult: PollResult) in
                    /// Notify any observers that we got a result
                    self?.receivedPollResponseSubject.send(pollResult.response)
                }
            )
            .eraseToAnyPublisher()
    }
}
