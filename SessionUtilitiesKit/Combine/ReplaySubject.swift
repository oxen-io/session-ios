// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

/// A subject that stores the last `bufferSize` emissions and emits them for every new subscriber
///
/// Note: This implementation was found here: https://github.com/sgl0v/OnSwiftWings
public final class ReplaySubject<Output, Failure: Error>: Subject {
    private var buffer: [Output] = [Output]()
    private let bufferSize: Int
    private let lock: NSRecursiveLock = NSRecursiveLock()
    private var subscriptions: Atomic<[ReplaySubjectSubscription<Output, Failure>]> = Atomic([])
    private var completion: Subscribers.Completion<Failure>?
    
    // MARK: - Initialization

    init(_ bufferSize: Int = 0) {
        self.bufferSize = bufferSize
    }
    
    // MARK: - Subject Methods
    
    /// Sends a value to the subscriber
    public func send(_ value: Output) {
        lock.lock(); defer { lock.unlock() }
        
        buffer.append(value)
        buffer = buffer.suffix(bufferSize)
        subscriptions.wrappedValue.forEach { $0.receive(value) }
    }
    
    /// Sends a completion signal to the subscriber
    public func send(completion: Subscribers.Completion<Failure>) {
        lock.lock(); defer { lock.unlock() }
        
        self.completion = completion
        subscriptions.wrappedValue.forEach { $0.receive(completion: completion) }
    }
    
    /// Provides this Subject an opportunity to establish demand for any new upstream subscriptions
    public func send(subscription: Subscription) {
        lock.lock(); defer { lock.unlock() }
        
        subscription.request(.unlimited)
    }
    
    /// This function is called to attach the specified `Subscriber` to the`Publisher
    public func receive<S>(subscriber: S) where S: Subscriber, Failure == S.Failure, Output == S.Input {
        lock.lock(); defer { lock.unlock() }
        
        /// According to the below comment the `subscriber.receive(subscription: subscription)` code runs asynchronously
        /// which aligns with testing (resulting in the `request(_ newDemand: Subscribers.Demand)` function getting called after this
        /// function returns
        ///
        /// Later in the thread it's mentioned that as of `iOS 13.3` this behaviour changed to be synchronous but as of writing the minimum
        /// deployment version is set to `iOS 13.0` which I assume is why we are seeing the async behaviour which results in `receiveValue`
        /// not being called in some cases
        ///
        /// When the project is eventually updated to have a minimum version higher than `iOS 13.3` we should re-test this behaviour to see if
        /// we can revert this change
        ///
        /// https://forums.swift.org/t/combine-receive-on-runloop-main-loses-sent-value-how-can-i-make-it-work/28631/20
        let subscription: ReplaySubjectSubscription = ReplaySubjectSubscription<Output, Failure>(downstream: AnySubscriber(subscriber)) { [weak self, buffer = buffer, completion = completion] subscription in
            self?.subscriptions.mutate { $0.append(subscription) }
            subscription.replay(buffer, completion: completion)
        }
        subscriber.receive(subscription: subscription)
    }
}

// MARK: -

public final class ReplaySubjectSubscription<Output, Failure: Error>: Subscription {
    private let downstream: AnySubscriber<Output, Failure>
    private var isCompleted: Bool = false
    private var demand: Subscribers.Demand = .none
    private var onInitialDemand: ((ReplaySubjectSubscription) -> ())?
    
    // MARK: - Initialization

    init(downstream: AnySubscriber<Output, Failure>, onInitialDemand: @escaping (ReplaySubjectSubscription) -> ()) {
        self.downstream = downstream
        self.onInitialDemand = onInitialDemand
    }
    
    // MARK: - Subscription

    public func request(_ newDemand: Subscribers.Demand) {
        demand += newDemand
        onInitialDemand?(self)
        onInitialDemand = nil
    }

    public func cancel() {
        isCompleted = true
    }
    
    // MARK: - Functions

    public func receive(_ value: Output) {
        guard !isCompleted, demand > 0 else { return }

        demand += downstream.receive(value)
        demand -= 1
    }

    public func receive(completion: Subscribers.Completion<Failure>) {
        guard !isCompleted else { return }
        
        isCompleted = true
        downstream.receive(completion: completion)
    }

    public func replay(_ values: [Output], completion: Subscribers.Completion<Failure>?) {
        guard !isCompleted else { return }
        
        values.forEach { value in receive(value) }
        
        if let completion = completion {
            receive(completion: completion)
        }
    }
}
