// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import Sodium
import SessionSnodeKit
import SessionUtilitiesKit

public class Poller {
    public typealias PollResponse = (
        messages: [ProcessedMessage],
        rawMessageCount: Int,
        validMessageCount: Int,
        hadValidHashUpdate: Bool
    )
    
    internal enum PollerErrorResponse {
        case stopPolling
        case continuePolling
        case continuePollingInfo(String)
    }
    
    private var cancellables: Atomic<[String: AnyCancellable]> = Atomic([:])
    internal var isPolling: Atomic<[String: Bool]> = Atomic([:])
    internal var pollCount: Atomic<[String: Int]> = Atomic([:])
    internal var failureCount: Atomic<[String: Int]> = Atomic([:])
    internal var drainBehaviour: Atomic<[String: Atomic<SwarmDrainBehaviour>]> = Atomic([:])
    
    // MARK: - Settings
    
    /// The namespaces which this poller queries
    internal var namespaces: [SnodeAPI.Namespace] {
        preconditionFailure("abstract class - override in subclass")
    }
    
    /// The queue this poller should run on
    internal var pollerQueue: DispatchQueue {
        preconditionFailure("abstract class - override in subclass")
    }
    
    /// The behaviour for how the poller should drain it's swarm when polling
    internal var pollDrainBehaviour: SwarmDrainBehaviour {
        preconditionFailure("abstract class - override in subclass")
    }

    // MARK: - Public API
    
    public init() {}
    
    public func stopAllPollers() {
        let pollers: [String] = Array(isPolling.wrappedValue.keys)
        
        pollers.forEach { groupPublicKey in
            self.stopPolling(for: groupPublicKey)
        }
    }
    
    public func stopPolling(for publicKey: String) {
        isPolling.mutate { $0[publicKey] = false }
        failureCount.mutate { $0[publicKey] = nil }
        drainBehaviour.mutate { $0[publicKey] = nil }
        cancellables.mutate {
            $0[publicKey]?.cancel()
            $0.removeAll()
        }
    }
    
    // MARK: - Abstract Methods
    
    /// The name for this poller to appear in the logs
    public func pollerName(for publicKey: String) -> String {
        preconditionFailure("abstract class - override in subclass")
    }
    
    /// Calculate the delay which should occur before the next poll
    internal func nextPollDelay(for publicKey: String, using dependencies: Dependencies) -> TimeInterval {
        preconditionFailure("abstract class - override in subclass")
    }
    
    /// Perform and logic which should occur when the poll errors, will stop polling if `false` is returned
    internal func handlePollError(_ error: Error, for publicKey: String, using dependencies: Dependencies) -> PollerErrorResponse {
        preconditionFailure("abstract class - override in subclass")
    }

    // MARK: - Private API
    
    internal func startIfNeeded(for publicKey: String, using dependencies: Dependencies) {
        // Run on the 'pollerQueue' to ensure any 'Atomic' access doesn't block the main thread
        // on startup
        let drainBehaviour: Atomic<SwarmDrainBehaviour> = Atomic(pollDrainBehaviour)
        
        pollerQueue.async { [weak self] in
            guard self?.isPolling.wrappedValue[publicKey] != true else { return }
            
            // Might be a race condition that the setUpPolling finishes too soon,
            // and the timer is not created, if we mark the group as is polling
            // after setUpPolling. So the poller may not work, thus misses messages
            self?.isPolling.mutate { $0[publicKey] = true }
            self?.drainBehaviour.mutate { $0[publicKey] = drainBehaviour }
            self?.pollRecursively(for: publicKey, drainBehaviour: drainBehaviour, using: dependencies)
        }
    }
    
    private func pollRecursively(
        for swarmPublicKey: String,
        drainBehaviour: Atomic<SwarmDrainBehaviour>,
        using dependencies: Dependencies
    ) {
        guard isPolling.wrappedValue[swarmPublicKey] == true else { return }
        
        let pollerName: String = pollerName(for: swarmPublicKey)
        let namespaces: [SnodeAPI.Namespace] = self.namespaces
        let pollerQueue: DispatchQueue = self.pollerQueue
        let lastPollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        let fallbackPollDelay: TimeInterval = self.nextPollDelay(for: swarmPublicKey, using: dependencies)
        
        // Store the publisher intp the cancellables dictionary
        cancellables.mutate { [weak self] cancellables in
            cancellables[swarmPublicKey]?.cancel()
            cancellables[swarmPublicKey] = self?.poll(
                    namespaces: namespaces,
                    for: swarmPublicKey,
                    drainBehaviour: drainBehaviour,
                    forceSynchronousProcessing: false,
                    using: dependencies
                )
                .subscribe(on: pollerQueue, using: dependencies)
                .receive(on: pollerQueue, using: dependencies)
                // FIXME: In iOS 14.0 a `flatMap` was added where the error type in `Never`, we should use that here
                .map { response -> Result<PollResponse, Error> in Result.success(response) }
                .catch { error -> AnyPublisher<Result<PollResponse, Error>, Error> in
                    Just(Result.failure(error)).setFailureType(to: Error.self).eraseToAnyPublisher()
                }
                .sink(
                    receiveCompletion: { _ in },    // Never called
                    receiveValue: { result in
                        // If the polling has been cancelled then don't continue
                        guard self?.isPolling.wrappedValue[swarmPublicKey] == true else { return }
                        
                        // Increment or reset the failureCount
                        let failureCount: Int
                        
                        switch result {
                            case .failure:
                                failureCount = (self?.failureCount
                                    .mutate {
                                        let updatedFailureCount: Int = (($0[swarmPublicKey] ?? 0) + 1)
                                        $0[swarmPublicKey] = updatedFailureCount
                                        return updatedFailureCount
                                    })
                                    .defaulting(to: -1)
                                
                            case .success:
                                failureCount = 0
                                self?.failureCount.mutate { $0.removeValue(forKey: swarmPublicKey) }
                        }
                        
                        // Log information about the poll
                        let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                        let duration: TimeUnit = .seconds(endTime - lastPollStart)
                        let nextPollInterval: TimeUnit = .seconds((self?.nextPollDelay(for: swarmPublicKey, using: dependencies))
                            .defaulting(to: fallbackPollDelay))
                        
                        switch result {
                            case .failure(let error):
                                // Determine if the error should stop us from polling anymore
                                switch self?.handlePollError(error, for: swarmPublicKey, using: dependencies) {
                                    case .stopPolling: return
                                    case .continuePollingInfo(let info):
                                        Log.error("\(pollerName) failed to process any messages after \(duration, unit: .s) due to error: \(error). \(info). Setting failure count to \(failureCount). Next poll in \(nextPollInterval, unit: .s).")
                                        
                                    case .continuePolling, .none:
                                        Log.error("\(pollerName) failed to process any messages after \(duration, unit: .s) due to error: \(error). Setting failure count to \(failureCount). Next poll in \(nextPollInterval, unit: .s).")
                                }
                                
                            case .success(let response):
                                switch (response.rawMessageCount, response.validMessageCount, response.hadValidHashUpdate) {
                                    case (0, _, _):
                                        Log.info("Received no new messages in \(pollerName) after \(duration, unit: .s). Next poll in \(nextPollInterval, unit: .s).")
                                        
                                    case (_, 0, false):
                                        Log.info("Received \(response.rawMessageCount) new message(s) in \(pollerName) after \(duration, unit: .s), all duplicates - marked the hash we polled with as invalid. Next poll in \(nextPollInterval, unit: .s).")
                                        
                                    default:
                                        Log.info("Received \(response.validMessageCount) new message(s) in \(pollerName) after \(duration, unit: .s) (duplicates: \(response.rawMessageCount - response.validMessageCount)). Next poll in \(nextPollInterval, unit: .s).")
                                }
                        }
                        
                        // Schedule the next poll
                        pollerQueue.asyncAfter(deadline: .now() + .milliseconds(Int(nextPollInterval.timeInterval * 1000)), qos: .default, using: dependencies) {
                            self?.pollRecursively(for: swarmPublicKey, drainBehaviour: drainBehaviour, using: dependencies)
                        }
                    }
                )
        }
    }
    
    /// This doesn't do anything functional _but_ does mean if we get a crash from the `BackgroundPoller` we can better distinguish
    /// it from a crash from a foreground poll
    public func pollFromBackground(
        namespaces: [SnodeAPI.Namespace],
        for swarmPublicKey: String,
        drainBehaviour: Atomic<SwarmDrainBehaviour>,
        using dependencies: Dependencies
    ) -> AnyPublisher<PollResponse, Error> {
        return poll(
            namespaces: namespaces,
            for: swarmPublicKey,
            drainBehaviour: drainBehaviour,
            forceSynchronousProcessing: true,
            using: dependencies
        )
    }
    
    /// Polls the specified namespaces and processes any messages, returning an array of messages that were
    /// successfully processed
    ///
    /// **Note:** The returned messages will have already been processed by the `Poller`, they are only returned
    /// for cases where we need explicit/custom behaviours to occur (eg. Onboarding)
    public func poll(
        namespaces: [SnodeAPI.Namespace],
        for swarmPublicKey: String,
        drainBehaviour: Atomic<SwarmDrainBehaviour>,
        forceSynchronousProcessing: Bool,
        using dependencies: Dependencies
    ) -> AnyPublisher<PollResponse, Error> {
        let pollerQueue: DispatchQueue = self.pollerQueue
        let configHashes: [String] = LibSession.configHashes(for: swarmPublicKey)
        
        // Fetch the messages
        return LibSession.getSwarm(swarmPublicKey: swarmPublicKey)
            .tryFlatMapWithRandomSnode(drainBehaviour: drainBehaviour, using: dependencies) { snode -> AnyPublisher<Network.PreparedRequest<SnodeAPI.PollResponse>, Error> in
                dependencies.storage.readPublisher(using: dependencies) { db in
                    try SnodeAPI.preparedPoll(
                        db,
                        namespaces: namespaces,
                        refreshingConfigHashes: configHashes,
                        from: snode,
                        swarmPublicKey: swarmPublicKey,
                        using: dependencies
                    )
                }
            }
            .flatMap { [dependencies] (request: Network.PreparedRequest<SnodeAPI.PollResponse>) -> AnyPublisher<(ResponseInfoType, SnodeAPI.PollResponse), Error> in
                request.send(using: dependencies)
            }
            .flatMap { (_: ResponseInfoType, namespacedResults: SnodeAPI.PollResponse) -> AnyPublisher<([Job], [Job], PollResponse), Error> in
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
                
                return dependencies.storage.writePublisher(using: dependencies) { db -> ([Job], [Job], PollResponse) in
                    let allProcessedMessages: [ProcessedMessage] = sortedMessages
                        .compactMap { namespace, messages -> [ProcessedMessage]? in
                            let processedMessages: [ProcessedMessage] = messages
                                .compactMap { message -> ProcessedMessage? in
                                    do {
                                        return try Message.processRawReceivedMessage(
                                            db,
                                            rawMessage: message,
                                            publicKey: swarmPublicKey,
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
                                                Log.warn("Failed to the database being suspended (running in background with no background task).")
                                                
                                            default: Log.error("Failed to deserialize envelope due to error: \(error).")
                                        }
                                        
                                        return nil
                                    }
                                }
                            
                            /// If this message should be handled synchronously then do so here before processing the next namespace
                            guard namespace.shouldHandleSynchronously else { return processedMessages }
                            
                            if namespace.isConfigNamespace {
                                do {
                                    /// Process config messages all at once in case they are multi-part messages
                                    try LibSession.handleConfigMessages(
                                        db,
                                        messages: ConfigMessageReceiveJob
                                            .Details(messages: processedMessages)
                                            .messages,
                                        publicKey: swarmPublicKey
                                    )
                                }
                                catch { Log.error("Failed to handle processed config message due to error: \(error).") }
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
                                            associatedWithProto: proto
                                        )
                                    }
                                    catch { Log.error("Failed to handle processed message due to error: \(error).") }
                                }
                            }
                            
                            return nil
                        }
                        .flatMap { $0 }
                    
                    // Add a job to process the config messages first
                    var configMessageJobs: [Job] = []
                    let configJobIds: [Int64] = allProcessedMessages
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
                            configMessageJobs = configMessageJobs.appending(job)
                            
                            // If we are force-polling then add to the JobRunner so they are
                            // persistent and will retry on the next app run if they fail but
                            // don't let them auto-start
                            let updatedJob: Job? = dependencies.jobRunner
                                .add(
                                    db,
                                    job: job,
                                    canStartJob: (
                                        !forceSynchronousProcessing &&
                                        (Singleton.hasAppContext && !Singleton.appContext.isInBackground)
                                    ),
                                    using: dependencies
                                )
                            
                            return updatedJob?.id
                        }
                    
                    // Add jobs for processing non-config messages which are dependant on the config message
                    // processing jobs
                    var standardMessageJobs: [Job] = []
                    allProcessedMessages
                        .filter { !$0.isConfigMessage && !$0.namespace.shouldHandleSynchronously }
                        .grouped { $0.threadId }
                        .forEach { threadId, threadMessages in
                            messageCount += threadMessages.count
                            processedMessages += threadMessages
                            
                            let job: Job? = Job(
                                variant: .messageReceive,
                                behaviour: .runOnce,
                                threadId: threadId,
                                details: MessageReceiveJob.Details(messages: threadMessages)
                            )
                            standardMessageJobs = standardMessageJobs.appending(job)
                            
                            // If we are force-polling then add to the JobRunner so they are
                            // persistent and will retry on the next app run if they fail but
                            // don't let them auto-start
                            let updatedJob: Job? = dependencies.jobRunner
                                .add(
                                    db,
                                    job: job,
                                    canStartJob: (
                                        !forceSynchronousProcessing &&
                                        (Singleton.hasAppContext && !Singleton.appContext.isInBackground)
                                    ),
                                    using: dependencies
                                )
                            
                            // Create the dependency between the jobs
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
                                    Log.warn("Failed to add dependency between config processing and non-config processing messageReceive jobs.")
                                }
                            }
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
            .flatMap { (configMessageJobs: [Job], standardMessageJobs: [Job], pollResponse: PollResponse) -> AnyPublisher<PollResponse, Error> in
                // If we don't want to forcible process the response synchronously then just finish immediately
                guard forceSynchronousProcessing else {
                    return Just(pollResponse)
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
                                        success: { _, _, _ in resolver(Result.success(())) },
                                        failure: { _, _, _, _ in resolver(Result.success(())) },
                                        deferred: { _, _ in resolver(Result.success(())) },
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
                                                success: { _, _, _ in resolver(Result.success(())) },
                                                failure: { _, _, _, _ in resolver(Result.success(())) },
                                                deferred: { _, _ in resolver(Result.success(())) },
                                                using: dependencies
                                            )
                                        }
                                    }
                                    .eraseToAnyPublisher()
                                }
                            )
                            .collect()
                    }
                    .map { _ in pollResponse }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
}
