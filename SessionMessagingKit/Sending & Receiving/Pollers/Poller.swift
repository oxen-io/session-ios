// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - PollerType

public protocol PollerType {
    func start(using dependencies: Dependencies)
    func startIfNeeded(for publicKey: String, using dependencies: Dependencies)
    func stopAllPollers()
    func stopPolling(for publicKey: String)
    
    func poll(
        namespaces: [SnodeAPI.Namespace],
        for publicKey: String,
        calledFromBackgroundPoller: Bool,
        isBackgroundPollValid: @escaping () -> Bool,
        drainBehaviour: Atomic<SwarmDrainBehaviour>,
        using dependencies: Dependencies
    ) -> AnyPublisher<[ProcessedMessage], Error>
    func afterNextPoll(for publicKey: String, closure: @escaping ([ProcessedMessage]) -> ())
}

public extension PollerType {
    func poll(
        namespaces: [SnodeAPI.Namespace],
        for publicKey: String,
        drainBehaviour: Atomic<SwarmDrainBehaviour>,
        using dependencies: Dependencies
    ) -> AnyPublisher<[ProcessedMessage], Error> {
        return poll(
            namespaces: namespaces,
            for: publicKey,
            calledFromBackgroundPoller: false,
            isBackgroundPollValid: { true },
            drainBehaviour: drainBehaviour,
            using: dependencies
        )
    }
}

// MARK: - Poller

public class Poller: PollerType {
    private var cancellables: Atomic<[String: AnyCancellable]> = Atomic([:])
    private var pollResultCallbacks: Atomic<[String: [([ProcessedMessage]) -> ()]]> = Atomic([:])
    internal var isPolling: Atomic<[String: Bool]> = Atomic([:])
    internal var failureCount: Atomic<[String: Int]> = Atomic([:])
    internal var drainBehaviour: Atomic<[String: Atomic<SwarmDrainBehaviour>]> = Atomic([:])
    
    // MARK: - Settings
    
    /// The namespaces which this poller queries
    internal func namespaces(for publicKey: String) -> [SnodeAPI.Namespace] {
        preconditionFailure("abstract class - override in subclass")
    }
    
    /// The behaviour for how the poller should drain it's swarm when polling
    internal var pollDrainBehaviour: SwarmDrainBehaviour {
        preconditionFailure("abstract class - override in subclass")
    }

    // MARK: - Public API
    
    public func start(using dependencies: Dependencies) {
        preconditionFailure("abstract class - override in subclass")
    }
    
    public func startIfNeeded(for publicKey: String, using dependencies: Dependencies) {
        // Run on the 'pollerQueue' to ensure any 'Atomic' access doesn't block the main thread
        // on startup
        let drainBehaviour: Atomic<SwarmDrainBehaviour> = Atomic(pollDrainBehaviour)
        
        Threading.pollerQueue.async(using: dependencies) { [weak self] in
            guard self?.isPolling.wrappedValue[publicKey] != true else { return }
            
            // Might be a race condition that the setUpPolling finishes too soon,
            // and the timer is not created, if we mark the group as is polling
            // after setUpPolling. So the poller may not work, thus misses messages
            self?.isPolling.mutate { $0[publicKey] = true }
            self?.drainBehaviour.mutate { $0[publicKey] = drainBehaviour }
            self?.pollRecursively(for: publicKey, drainBehaviour: drainBehaviour, using: dependencies)
        }
    }
    
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
        cancellables.mutate { $0[publicKey]?.cancel() }
    }
    
    // MARK: - Abstract Methods
    
    /// The name for this poller to appear in the logs
    internal func pollerName(for publicKey: String) -> String {
        preconditionFailure("abstract class - override in subclass")
    }
    
    /// Calculate the delay which should occur before the next poll
    internal func nextPollDelay(for publicKey: String, using dependencies: Dependencies) -> TimeInterval {
        preconditionFailure("abstract class - override in subclass")
    }
    
    /// Perform and logic which should occur when the poll errors, will stop polling if `false` is returned
    internal func handlePollError(_ error: Error, for publicKey: String, using dependencies: Dependencies) -> Bool {
        preconditionFailure("abstract class - override in subclass")
    }

    // MARK: - Private API
    
    private func pollRecursively(
        for publicKey: String,
        drainBehaviour: Atomic<SwarmDrainBehaviour>,
        using dependencies: Dependencies
    ) {
        guard isPolling.wrappedValue[publicKey] == true else { return }
        
        let namespaces: [SnodeAPI.Namespace] = self.namespaces(for: publicKey)
        let lastPollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        let lastPollInterval: TimeInterval = nextPollDelay(for: publicKey, using: dependencies)
        
        // Store the publisher intp the cancellables dictionary
        cancellables.mutate { [weak self] cancellables in
            cancellables[publicKey] = self?
                .poll(
                    namespaces: namespaces,
                    for: publicKey,
                    drainBehaviour: drainBehaviour,
                    using: dependencies
                )
                .subscribe(on: Threading.pollerQueue, using: dependencies)
                .receive(on: Threading.pollerQueue, using: dependencies)
                .sink(
                    receiveCompletion: { result in
                        switch result {
                            case .failure(let error):
                                // Determine if the error should stop us from polling anymore
                                guard self?.handlePollError(error, for: publicKey, using: dependencies) == true else {
                                    return
                                }
                                
                            case .finished: break
                        }
                        
                        // Calculate the remaining poll delay
                        let currentTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                        let nextPollInterval: TimeInterval = (
                            self?.nextPollDelay(for: publicKey, using: dependencies) ??
                            lastPollInterval
                        )
                        let remainingInterval: TimeInterval = max(0, nextPollInterval - (currentTime - lastPollStart))
                        
                        // Schedule the next poll
                        guard remainingInterval > 0 else {
                            return Threading.pollerQueue.async(using: dependencies) {
                                self?.pollRecursively(for: publicKey, drainBehaviour: drainBehaviour, using: dependencies)
                            }
                        }
                        
                        Threading.pollerQueue.asyncAfter(deadline: .now() + .milliseconds(Int(remainingInterval * 1000)), qos: .default, using: dependencies) {
                            self?.pollRecursively(for: publicKey, drainBehaviour: drainBehaviour, using: dependencies)
                        }
                    },
                    receiveValue: { _ in }
                )
        }
    }
    
    /// Polls the specified namespaces and processes any messages, returning an array of messages that were
    /// successfully processed
    ///
    /// **Note:** The returned messages will have already been processed by the `Poller`, they are only returned
    /// for cases where we need explicit/custom behaviours to occur (eg. Onboarding)
    public func poll(
        namespaces: [SnodeAPI.Namespace],
        for publicKey: String,
        calledFromBackgroundPoller: Bool,
        isBackgroundPollValid: @escaping () -> Bool,
        drainBehaviour: Atomic<SwarmDrainBehaviour>,
        using dependencies: Dependencies
    ) -> AnyPublisher<[ProcessedMessage], Error> {
        // If the polling has been cancelled then don't continue
        guard
            (calledFromBackgroundPoller && isBackgroundPollValid()) ||
            isPolling.wrappedValue[publicKey] == true
        else {
            return Just([])
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        let pollerName: String = pollerName(for: publicKey)
        let configHashes: [String] = LibSession.configHashes(for: publicKey, using: dependencies)
        
        /// Fetch the messages
        ///
        /// **Note:**  We need a `writePublisher` here because we want to prune the `lastMessageHash` value when preparing
        /// the request
        return SnodeAPI.getSwarm(for: publicKey, using: dependencies)
            .tryFlatMapWithRandomSnode(drainBehaviour: drainBehaviour, using: dependencies) { snode -> AnyPublisher<HTTP.PreparedRequest<SnodeAPI.PollResponse>, Error> in
                dependencies[singleton: .storage]
                    .writePublisher(using: dependencies) { db -> HTTP.PreparedRequest<SnodeAPI.PollResponse> in
                        try SnodeAPI.preparedPoll(
                            db,
                            namespaces: namespaces,
                            refreshingConfigHashes: configHashes,
                            from: snode,
                            authMethod: try Authentication.with(
                                db,
                                sessionIdHexString: publicKey,
                                using: dependencies
                            ),
                            using: dependencies
                        )
                    }
            }
            .flatMap { $0.send(using: dependencies) }
            .flatMap { [weak self] (_: ResponseInfoType, namespacedResults: SnodeAPI.PollResponse) -> AnyPublisher<[ProcessedMessage], Error> in
                guard
                    (calledFromBackgroundPoller && isBackgroundPollValid()) ||
                    self?.isPolling.wrappedValue[publicKey] == true
                else {
                    return Just([])
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                // Get all of the messages and sort them by their required 'processingOrder'
                let sortedMessages: [(namespace: SnodeAPI.Namespace, messages: [SnodeReceivedMessage])] = namespacedResults
                    .compactMap { namespace, result in (result.data?.messages).map { (namespace, $0) } }
                    .sorted { lhs, rhs in lhs.namespace.processingOrder < rhs.namespace.processingOrder }
                let rawMessageCount: Int = sortedMessages.map { $0.messages.count }.reduce(0, +)
                
                // No need to do anything if there are no messages
                guard rawMessageCount > 0 else {
                    if !calledFromBackgroundPoller { SNLog("Received no new messages in \(pollerName)") }
                    
                    return Just([])
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
                var configMessageJobsToRun: [Job] = []
                var standardMessageJobsToRun: [Job] = []
                var pollerLogOutput: String = "\(pollerName) failed to process any messages"  // stringlint:disable
                
                dependencies[singleton: .storage].write { db in
                    let allProcessedMessages: [ProcessedMessage] = sortedMessages
                        .compactMap { namespace, messages -> [ProcessedMessage]? in
                            let processedMessages: [ProcessedMessage] = messages
                                .compactMap { message -> ProcessedMessage? in
                                    do {
                                        return try Message.processRawReceivedMessage(
                                            db,
                                            rawMessage: message,
                                            publicKey: publicKey,
                                            using: dependencies
                                        )
                                    }
                                    catch {
                                        switch error {
                                            /// Ignore duplicate & selfSend message errors (and don't bother logging them as there
                                            /// will be a lot since we each service node duplicates messages)
                                            case DatabaseError.SQLITE_CONSTRAINT_UNIQUE,
                                                MessageReceiverError.duplicateMessage,
                                                MessageReceiverError.duplicateControlMessage,
                                                MessageReceiverError.selfSend:
                                                break
                                                
                                            case MessageReceiverError.duplicateMessageNewSnode:
                                                hadValidHashUpdate = true
                                                break
                                                
                                            case DatabaseError.SQLITE_ABORT:
                                                /// In the background ignore 'SQLITE_ABORT' (it generally means the
                                                /// BackgroundPoller has timed out
                                                if !calledFromBackgroundPoller {
                                                    SNLog("Failed to the database being suspended (running in background with no background task).")
                                                }
                                                break
                                                
                                            default: SNLog("Failed to process raw message due to error: \(error).")
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
                                        sessionIdHexString: publicKey,
                                        messages: ConfigMessageReceiveJob
                                            .Details(
                                                messages: processedMessages,
                                                calledFromBackgroundPoller: false
                                            )
                                            .messages
                                    )
                                }
                                catch { SNLog("Failed to handle processed message to error: \(error).") }
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
                                    catch { SNLog("Failed to handle processed message to error: \(error).") }
                                }
                            }
                            
                            return nil
                        }
                        .flatMap { $0 }
                    
                    // Add a job to process the async config messages first
                    let configJobIds: [Int64] = allProcessedMessages
                        .filter { $0.isConfigMessage && !$0.namespace.shouldHandleSynchronously }
                        .grouped { $0.threadId }
                        .compactMap { threadId, threadMessages in
                            messageCount += threadMessages.count
                            processedMessages += threadMessages
                            
                            let jobToRun: Job? = Job(
                                variant: .configMessageReceive,
                                behaviour: .runOnce,
                                threadId: threadId,
                                details: ConfigMessageReceiveJob.Details(
                                    messages: threadMessages,
                                    calledFromBackgroundPoller: calledFromBackgroundPoller
                                )
                            )
                            configMessageJobsToRun = configMessageJobsToRun.appending(jobToRun)
                            
                            // If we are force-polling then add to the JobRunner so they are
                            // persistent and will retry on the next app run if they fail but
                            // don't let them auto-start
                            let updatedJob: Job? = dependencies[singleton: .jobRunner]
                                .add(
                                    db,
                                    job: jobToRun,
                                    canStartJob: !calledFromBackgroundPoller,
                                    using: dependencies
                                )
                                
                            return updatedJob?.id
                        }
                    
                    // Add jobs for processing async non-config messages which is dependant on the
                    // config message processing jobs
                    allProcessedMessages
                        .filter { !$0.isConfigMessage && !$0.namespace.shouldHandleSynchronously }
                        .grouped { $0.threadId }
                        .forEach { threadId, threadMessages in
                            messageCount += threadMessages.count
                            processedMessages += threadMessages
                            
                            let jobToRun: Job? = Job(
                                variant: .messageReceive,
                                behaviour: .runOnce,
                                threadId: threadId,
                                details: MessageReceiveJob.Details(
                                    messages: threadMessages,
                                    calledFromBackgroundPoller: calledFromBackgroundPoller
                                )
                            )
                            standardMessageJobsToRun = standardMessageJobsToRun.appending(jobToRun)
                            
                            // If we are force-polling then add to the JobRunner so they are
                            // persistent and will retry on the next app run if they fail but
                            // don't let them auto-start
                            let updatedJob: Job? = dependencies[singleton: .jobRunner]
                                .add(
                                    db,
                                    job: jobToRun,
                                    canStartJob: !calledFromBackgroundPoller,
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
                                    SNLog("Failed to add dependency between config processing and non-config processing messageReceive jobs.")
                                }
                            }
                        }
                    
                    // Set the output for logging
                    pollerLogOutput = "Received \(messageCount) new message\(messageCount == 1 ? "" : "s") in \(pollerName) (duplicates: \(rawMessageCount - messageCount))"  // stringlint:disable
                    
                    // Clean up message hashes and add some logs about the poll results
                    if sortedMessages.isEmpty && !hadValidHashUpdate {
                        pollerLogOutput = "Received \(rawMessageCount) new message\(rawMessageCount == 1 ? "" : "s") in \(pollerName), all duplicates - marking the hash we polled with as invalid" // stringlint:disable
                        
                        // Update the cached validity of the messages
                        try SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                            db,
                            potentiallyInvalidHashes: lastHashes,
                            otherKnownValidHashes: otherKnownHashes
                        )
                    }
                }
                
                // Only output logs if it isn't the background poller
                if !calledFromBackgroundPoller {
                    SNLog(pollerLogOutput)
                }
                
                // If we aren't runing in a background poller then just finish immediately
                guard calledFromBackgroundPoller else {
                    return Just(processedMessages)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                // We want to try to handle the receive jobs immediately in the background
                return Publishers
                    .MergeMany(
                        configMessageJobsToRun.map { job -> AnyPublisher<Void, Error> in
                            Deferred {
                                Future<Void, Error> { resolver in
                                    // Note: In the background we just want jobs to fail silently
                                    ConfigMessageReceiveJob.run(
                                        job,
                                        queue: Threading.pollerQueue,
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
                                standardMessageJobsToRun.map { job -> AnyPublisher<Void, Error> in
                                    Deferred {
                                        Future<Void, Error> { resolver in
                                            // Note: In the background we just want jobs to fail silently
                                            MessageReceiveJob.run(
                                                job,
                                                queue: Threading.pollerQueue,
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
                    .map { _ in processedMessages }
                    .eraseToAnyPublisher()
            }
            .handleEvents(
                receiveOutput: { [weak self] messages in
                    /// Run any poll result callbacks we registered
                    let callbacks: [([ProcessedMessage]) -> ()] = (self?.pollResultCallbacks
                        .mutate { callbacks in
                            let result: [([ProcessedMessage]) -> ()] = (callbacks[publicKey] ?? [])
                            callbacks.removeValue(forKey: publicKey)
                            return result
                        })
                        .defaulting(to: [])
                    
                    callbacks.forEach { $0(messages) }
                }
            )
            .eraseToAnyPublisher()
    }
    
    public func afterNextPoll(for publicKey: String, closure: @escaping ([ProcessedMessage]) -> ()) {
        pollResultCallbacks.mutate { callbacks in
            callbacks[publicKey] = (callbacks[publicKey] ?? []).appending(closure)
        }
    }
}
