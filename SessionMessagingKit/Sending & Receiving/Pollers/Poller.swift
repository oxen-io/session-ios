// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - PollerType

public protocol PollerType {
    var swarmPublicKey: String { get }
    var receivedPollResult: AnyPublisher<Poller.PollResult, Never> { get }
    
    init(
        swarmPublicKey: String,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        customAuthMethod: AuthenticationMethod?,
        drainBehaviour: SwarmDrainBehaviour,
        using dependencies: Dependencies
    )
    
    func startIfNeeded()
    func stop()
    
    func poll(
        namespaces: [SnodeAPI.Namespace],
        calledFromBackgroundPoller: Bool,
        isBackgroundPollValid: @escaping () -> Bool
    ) -> AnyPublisher<Poller.PollResponse, Error>
}

public extension PollerType {
    func poll(namespaces: [SnodeAPI.Namespace]) -> AnyPublisher<Poller.PollResponse, Error> {
        return poll(
            namespaces: namespaces,
            calledFromBackgroundPoller: false,
            isBackgroundPollValid: { true }
        )
    }
}

// MARK: - Poller

public class Poller: PollerType {
    public typealias PollResponse = (
        messages: [ProcessedMessage],
        processingJobs: [Job],
        rawMessageCount: Int,
        validMessageCount: Int,
        hadValidHashUpdate: Bool
    )
    public typealias PollResult = (
        messages: [ProcessedMessage],
        processingJobs: [Job]
    )
    
    internal enum PollerErrorResponse {
        case stopPolling
        case continuePolling
        case continuePollingInfo(String)
    }
    
    internal let dependencies: Dependencies
    private let customAuthMethod: AuthenticationMethod?
    private let shouldStoreMessages: Bool
    private let logStartAndStopCalls: Bool
    private let receivedPollResultSubject: PassthroughSubject<PollResult, Never> = PassthroughSubject()
    internal var drainBehaviour: Atomic<SwarmDrainBehaviour>
    internal var cancellable: AnyCancellable?
    internal var pollCount: Int = 0
    internal var failureCount: Int = 0
    public var swarmPublicKey: String
    public var isPolling: Bool = false
    public var receivedPollResult: AnyPublisher<PollResult, Never> {
        receivedPollResultSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization
    
    required public init(
        swarmPublicKey: String,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        customAuthMethod: AuthenticationMethod? = nil,
        drainBehaviour: SwarmDrainBehaviour,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.swarmPublicKey = swarmPublicKey
        self.customAuthMethod = customAuthMethod
        self.shouldStoreMessages = shouldStoreMessages
        self.logStartAndStopCalls = logStartAndStopCalls
        self.drainBehaviour = Atomic(drainBehaviour)
    }
    
    // MARK: - Settings
    
    /// The queue this poller should run on
    internal var pollerQueue: DispatchQueue {
        preconditionFailure("abstract class - override in subclass")
    }
    
    /// The namespaces which this poller queries
    internal var namespaces: [SnodeAPI.Namespace] {
        preconditionFailure("abstract class - override in subclass")
    }
    
    /// The name for this poller to appear in the logs
    internal var pollerName: String {
        preconditionFailure("abstract class - override in subclass")
    }

    // MARK: - Functions
    
    public func startIfNeeded() {
        pollerQueue.async(using: dependencies) { [weak self, pollerName] in
            guard self?.isPolling != true else { return }
            
            // Might be a race condition that the setUpPolling finishes too soon,
            // and the timer is not created, if we mark the group as is polling
            // after setUpPolling. So the poller may not work, thus misses messages
            self?.isPolling = true
            self?.pollRecursively()
            
            if self?.logStartAndStopCalls == true {
                Log.info("[Poller] Started \(pollerName).")
            }
        }
    }
    
    public func stop() {
        pollerQueue.async(using: dependencies) { [weak self, pollerName] in
            self?.isPolling = false
            self?.cancellable?.cancel()
            
            if self?.logStartAndStopCalls == true {
                Log.info("[Poller] Stopped \(pollerName).")
            }
        }
    }
    
    // MARK: - Abstract Methods
    
    /// Calculate the delay which should occur before the next poll
    internal func nextPollDelay() -> TimeInterval {
        preconditionFailure("abstract class - override in subclass")
    }
    
    /// Perform and logic which should occur when the poll errors, will stop polling if `false` is returned
    internal func handlePollError(_ error: Error) -> PollerErrorResponse {
        preconditionFailure("abstract class - override in subclass")
    }

    // MARK: - Private API
    
    private func pollRecursively() {
        guard isPolling else { return }
        
        let lastPollStart: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        
        cancellable = poll(namespaces: namespaces)
            .subscribe(on: pollerQueue, using: dependencies)
            .receive(on: pollerQueue, using: dependencies)
            // FIXME: In iOS 14.0 a `flatMap` was added where the error type in `Never`, we should use that here
            .map { response -> Result<PollResponse, Error> in Result.success(response) }
            .catch { error -> AnyPublisher<Result<PollResponse, Error>, Error> in
                Just(Result.failure(error)).setFailureType(to: Error.self).eraseToAnyPublisher()
            }
            .sink(
                receiveCompletion: { _ in },    // Never called
                receiveValue: { [weak self, pollerName, pollerQueue, dependencies] result in
                    // If the polling has been cancelled then don't continue
                    guard self?.isPolling == true else { return }
                    
                    let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                    
                    // Log information about the poll
                    switch result {
                        case .failure(let error):
                            // Determine if the error should stop us from polling anymore
                            switch self?.handlePollError(error) {
                                case .stopPolling: return
                                case .continuePollingInfo(let info):
                                    Log.error("\(pollerName) failed to process any messages due to error: \(error). \(info)")
                                    
                                case .continuePolling, .none:
                                    Log.error("\(pollerName) failed to process any messages due to error: \(error).")
                            }
                            
                        case .success(let response):
                            let duration: TimeUnit = .seconds(endTime - lastPollStart)
                            
                            switch (response.rawMessageCount, response.validMessageCount, response.hadValidHashUpdate) {
                                case (0, _, _):
                                    Log.info("Received no new messages in \(pollerName) after \(duration, unit: .s).")
                                    
                                case (_, 0, false):
                                    Log.info("Received \(response.rawMessageCount) new message\(plural: response.rawMessageCount) in \(pollerName) after \(duration, unit: .s), all duplicates - marked the hash we polled with as invalid")
                                    
                                default:
                                    Log.info("Received \(response.validMessageCount) new message\(plural: response.validMessageCount) in \(pollerName) after \(duration, unit: .s) (duplicates: \(response.rawMessageCount - response.validMessageCount))")
                            }
                    }
                    
                    // Calculate the remaining poll delay and schedule the next poll
                    guard
                        self != nil,
                        let remainingInterval: TimeInterval = (self?.nextPollDelay())
                            .map({ nextPollInterval in max(0, nextPollInterval - (endTime - lastPollStart)) }),
                        remainingInterval > 0
                    else {
                        return pollerQueue.async(using: dependencies) {
                            self?.pollRecursively()
                        }
                    }
                    
                    pollerQueue.asyncAfter(deadline: .now() + .milliseconds(Int(remainingInterval * 1000)), qos: .default, using: dependencies) {
                        self?.pollRecursively()
                    }
                }
            )
    }
    
    /// Polls the specified namespaces and processes any messages, returning an array of messages that were
    /// successfully processed
    ///
    /// **Note:** The returned messages will have already been processed by the `Poller`, they are only returned
    /// for cases where we need explicit/custom behaviours to occur (eg. Onboarding)
    public func poll(
        namespaces: [SnodeAPI.Namespace],
        calledFromBackgroundPoller: Bool = false,
        isBackgroundPollValid: @escaping (() -> Bool) = { true }
    ) -> AnyPublisher<PollResponse, Error> {
        // If the polling has been cancelled then don't continue
        guard
            (calledFromBackgroundPoller && isBackgroundPollValid()) ||
            isPolling
        else {
            return Just(([], [], 0, 0, false))
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        let pollerQueue: DispatchQueue = self.pollerQueue
        let configHashes: [String] = LibSession.configHashes(for: swarmPublicKey, using: dependencies)
        
        /// Fetch the messages
        ///
        /// **Note:**  We need a `writePublisher` here because we want to prune the `lastMessageHash` value when preparing
        /// the request
        return dependencies[singleton: .network]
            .getSwarm(for: swarmPublicKey)
            .tryFlatMapWithRandomSnode(drainBehaviour: drainBehaviour, using: dependencies) { [swarmPublicKey, customAuthMethod, dependencies] snode -> AnyPublisher<Network.PreparedRequest<SnodeAPI.PollResponse>, Error> in
                dependencies[singleton: .storage].writePublisher { db -> Network.PreparedRequest<SnodeAPI.PollResponse> in
                    let authMethod: AuthenticationMethod = try (customAuthMethod ?? Authentication.with(
                        db,
                        swarmPublicKey: swarmPublicKey,
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
            .flatMap { [weak self, swarmPublicKey, shouldStoreMessages, dependencies] (_: ResponseInfoType, namespacedResults: SnodeAPI.PollResponse) -> AnyPublisher<PollResponse, Error> in
                guard
                    (calledFromBackgroundPoller && isBackgroundPollValid()) ||
                    self?.isPolling == true
                else {
                    return Just(([], [], 0, 0, false))
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
                    return Just(([], [], 0, 0, false))
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
                
                dependencies[singleton: .storage].write { db in
                    let allProcessedMessages: [ProcessedMessage] = sortedMessages
                        .compactMap { namespace, messages -> [ProcessedMessage]? in
                            let processedMessages: [ProcessedMessage] = messages
                                .compactMap { message -> ProcessedMessage? in
                                    do {
                                        return try Message.processRawReceivedMessage(
                                            db,
                                            rawMessage: message,
                                            swarmPublicKey: swarmPublicKey,
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
                                                /// In the background ignore 'SQLITE_ABORT' (it generally means the
                                                /// BackgroundPoller has timed out
                                                if !calledFromBackgroundPoller {
                                                    Log.warn("Failed to the database being suspended (running in background with no background task).")
                                                }
                                                break
                                                
                                            default: Log.error("Failed to deserialize envelope due to error: \(error).")
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
                                            swarmPublicKey: swarmPublicKey,
                                            messages: ConfigMessageReceiveJob
                                                .Details(
                                                    messages: processedMessages,
                                                    calledFromBackgroundPoller: false
                                                )
                                                .messages
                                        )
                                    }
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
                                            associatedWithProto: proto,
                                            using: dependencies
                                        )
                                    }
                                    catch { Log.error("Failed to handle processed message due to error: \(error).") }
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
                        return
                    }
                    
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
                            
                            // If we are force-polling then add to the JobRunner so they are
                            // persistent and will retry on the next app run if they fail but
                            // don't let them auto-start
                            let updatedJob: Job? = dependencies[singleton: .jobRunner].add(
                                db,
                                job: jobToRun,
                                canStartJob: !calledFromBackgroundPoller
                            )
                            
                            // Add to the array after it's been added to the JobRunner (as that's
                            // where the id gets set)
                            configMessageJobsToRun = configMessageJobsToRun.appending(updatedJob)
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
                            
                            // If we are force-polling then add to the JobRunner so they are
                            // persistent and will retry on the next app run if they fail but
                            // don't let them auto-start
                            let updatedJob: Job? = dependencies[singleton: .jobRunner].add(
                                db,
                                job: jobToRun,
                                canStartJob: !calledFromBackgroundPoller
                            )
                            
                            // Add to the array after it's been added to the JobRunner (as that's
                            // where the id gets set)
                            standardMessageJobsToRun = standardMessageJobsToRun.appending(jobToRun)
                            
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
                }
                
                // If we aren't runing in a background poller then just finish immediately
                guard calledFromBackgroundPoller else {
                    return Just((processedMessages, (configMessageJobsToRun + standardMessageJobsToRun), rawMessageCount, messageCount, hadValidHashUpdate))
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
                                standardMessageJobsToRun.map { job -> AnyPublisher<Void, Error> in
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
                    .map { _ in (processedMessages, [], rawMessageCount, messageCount, hadValidHashUpdate) }
                    .eraseToAnyPublisher()
            }
            .handleEvents(
                receiveOutput: { [weak self] (pollResponse: Poller.PollResponse) in
                    /// Notify any observers that we got a result
                    self?.receivedPollResultSubject.send((pollResponse.messages, pollResponse.processingJobs))
                }
            )
            .eraseToAnyPublisher()
    }
}
