// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let poller: Log.Category = .create("Poller", defaultLevel: .info)
}

// MARK: - PollerDestination

public enum PollerDestination {
    case swarm(String)
    case server(String)
    
    public var target: String {
        switch self {
            case .swarm(let value), .server(let value): return value
        }
    }
}

// MARK: - PollerErrorResponse

public enum PollerErrorResponse {
    case stopPolling
    case continuePolling
    case continuePollingInfo(String)
}

// MARK: - PollerType

public protocol PollerType: AnyObject {
    associatedtype PollResponse
    
    typealias PollResult = (
        response: PollResponse,
        rawMessageCount: Int,
        validMessageCount: Int,
        hadValidHashUpdate: Bool
    )
    
    var dependencies: Dependencies { get }
    var pollerQueue: DispatchQueue { get }
    var pollerName: String { get }
    var pollerDestination: PollerDestination { get }
    var logStartAndStopCalls: Bool { get }
    var receivedPollResponse: AnyPublisher<PollResponse, Never> { get }
    
    var isPolling: Bool { get set }
    var pollCount: Int { get set }
    var failureCount: Int { get set }
    var lastPollStart: TimeInterval { get set }
    var cancellable: AnyCancellable? { get set }
    
    init(
        pollerName: String,
        pollerQueue: DispatchQueue,
        pollerDestination: PollerDestination,
        pollerDrainBehaviour: SwarmDrainBehaviour,
        namespaces: [SnodeAPI.Namespace],
        failureCount: Int,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        customAuthMethod: AuthenticationMethod?,
        using dependencies: Dependencies
    )
    
    func startIfNeeded()
    func stop()
    
    func poll(forceSynchronousProcessing: Bool) -> AnyPublisher<PollResult, Error>
    func nextPollDelay() -> TimeInterval
    func handlePollError(_ error: Error, _ lastError: Error?) -> PollerErrorResponse
}

// MARK: - Default Implementations

public extension PollerType {
    func startIfNeeded() {
        pollerQueue.async(using: dependencies) { [weak self, pollerName] in
            guard self?.isPolling != true else { return }
            
            // Might be a race condition that the setUpPolling finishes too soon,
            // and the timer is not created, if we mark the group as is polling
            // after setUpPolling. So the poller may not work, thus misses messages
            self?.isPolling = true
            self?.pollRecursively(nil)
            
            if self?.logStartAndStopCalls == true {
                Log.info(.poller, "Started \(pollerName).")
            }
        }
    }
    
    func stop() {
        pollerQueue.async(using: dependencies) { [weak self, pollerName] in
            self?.isPolling = false
            self?.cancellable?.cancel()
            
            if self?.logStartAndStopCalls == true {
                Log.info(.poller, "Stopped \(pollerName).")
            }
        }
    }
    
    internal func pollRecursively(_ lastError: Error?) {
        guard isPolling else { return }
        
        self.lastPollStart = dependencies.dateNow.timeIntervalSince1970
        let fallbackPollDelay: TimeInterval = self.nextPollDelay()
        
        cancellable = poll(forceSynchronousProcessing: false)
            .subscribe(on: pollerQueue, using: dependencies)
            .receive(on: pollerQueue, using: dependencies)
            .asResult()
            .sink(
                receiveCompletion: { _ in },    // Never called
                receiveValue: { [weak self, pollerName, pollerQueue, lastPollStart, failureCount, dependencies] result in
                    // If the polling has been cancelled then don't continue
                    guard self?.isPolling == true else { return }
                    
                    let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                    let duration: TimeUnit = .seconds(endTime - lastPollStart)
                    let nextPollInterval: TimeUnit = .seconds((self?.nextPollDelay()).defaulting(to: fallbackPollDelay))
                    var errorFromPoll: Error?
                    
                    // Log information about the poll
                    switch result {
                        case .failure(let error):
                            // Increment the failure count
                            self?.failureCount = (failureCount + 1)
                            errorFromPoll = error
                            
                            // Determine if the error should stop us from polling anymore
                            switch self?.handlePollError(error, lastError) {
                                case .stopPolling: return
                                case .continuePollingInfo(let info):
                                    Log.error(.poller, "\(pollerName) failed to process any messages after \(duration, unit: .s) due to error: \(error). \(info). Setting failure count to \(failureCount). Next poll in \(nextPollInterval, unit: .s).")
                                    
                                case .continuePolling, .none:
                                    Log.error(.poller, "\(pollerName) failed to process any messages after \(duration, unit: .s) due to error: \(error). Setting failure count to \(failureCount). Next poll in \(nextPollInterval, unit: .s).")
                            }
                            
                        case .success(let response):
                            // Reset the failure count
                            self?.failureCount = 0
                            
                            switch (response.rawMessageCount, response.validMessageCount, response.hadValidHashUpdate) {
                                case (0, _, _):
                                    Log.info(.poller, "Received no new messages in \(pollerName) after \(duration, unit: .s). Next poll in \(nextPollInterval, unit: .s).")
                                    
                                case (_, 0, false):
                                    Log.info(.poller, "Received \(response.rawMessageCount) new message(s) in \(pollerName) after \(duration, unit: .s), all duplicates - marked the hash we polled with as invalid. Next poll in \(nextPollInterval, unit: .s).")
                                    
                                default:
                                    Log.info(.poller, "Received \(response.validMessageCount) new message(s) in \(pollerName) after \(duration, unit: .s) (duplicates: \(response.rawMessageCount - response.validMessageCount)). Next poll in \(nextPollInterval, unit: .s).")
                            }
                    }
                    
                    // Schedule the next poll
                    pollerQueue.asyncAfter(deadline: .now() + .milliseconds(Int(nextPollInterval.timeInterval * 1000)), qos: .default, using: dependencies) {
                        self?.pollRecursively(errorFromPoll)
                    }
                }
            )
    }
    
    /// This doesn't do anything functional _but_ does mean if we get a crash from the `BackgroundPoller` we can better distinguish
    /// it from a crash from a foreground poll
    func pollFromBackground() -> AnyPublisher<PollResult, Error> {
        return poll(forceSynchronousProcessing: true)
    }
}
