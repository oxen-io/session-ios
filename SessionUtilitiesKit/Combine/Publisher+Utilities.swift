// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine

public protocol CombineCompatible {}

public enum PublisherError: Error, CustomStringConvertible {
    case targetPublisherIsNull
    case invalidCollectionType
    
    // stringlint:ignore_contents
    public var description: String {
        switch self {
            case .targetPublisherIsNull: return "The target publisher is null, likely due to a 'weak self' (PublisherError.targetPublisherIsNull)."
            case .invalidCollectionType: return "Failed to convert array literal to desired Publisher type (PublisherError.invalidCollectionType)."
        }
    }
}

public extension Publisher {
    /// Provides a subject that shares a single subscription to the upstream publisher and replays at most
    /// `bufferSize` items emitted by that publisher
    /// - Parameter bufferSize: limits the number of items that can be replayed
    func shareReplay(_ bufferSize: Int) -> AnyPublisher<Output, Failure> {
        return multicast(subject: ReplaySubject(bufferSize))
            .autoconnect()
            .eraseToAnyPublisher()
    }
    
    func sink(into subject: PassthroughSubject<Output, Failure>, includeCompletions: Bool = false) -> AnyCancellable {
        return sink(
            receiveCompletion: { completion in
                guard includeCompletions else { return }
                
                subject.send(completion: completion)
            },
            receiveValue: { value in subject.send(value) }
        )
    }
    
    func flatMapOptional<T, P>(
        maxPublishers: Subscribers.Demand = .unlimited,
        _ transform: @escaping (Self.Output) -> P?
    ) -> AnyPublisher<T, Error> where T == P.Output, P : Publisher, P.Failure == Error {
        return self
            .mapError { $0 }
            .flatMap(maxPublishers: maxPublishers) { output -> AnyPublisher<P.Output, Error> in
                do {
                    guard let result: AnyPublisher<T, Error> = transform(output)?.eraseToAnyPublisher() else {
                        throw PublisherError.targetPublisherIsNull
                    }
                    
                    return result
                }
                catch {
                    return Fail<P.Output, Error>(error: error)
                        .eraseToAnyPublisher()
                }
            }
            .eraseToAnyPublisher()
    }
    
    func tryFlatMap<T, P>(
        maxPublishers: Subscribers.Demand = .unlimited,
        _ transform: @escaping (Self.Output) throws -> P
    ) -> AnyPublisher<T, Error> where T == P.Output, P : Publisher, P.Failure == Error {
        return self
            .mapError { $0 }
            .flatMap(maxPublishers: maxPublishers) { output -> AnyPublisher<P.Output, Error> in
                do {
                    return try transform(output)
                        .eraseToAnyPublisher()
                }
                catch {
                    return Fail<P.Output, Error>(error: error)
                        .eraseToAnyPublisher()
                }
            }
            .eraseToAnyPublisher()
    }
    
    func tryFlatMapOptional<T, P>(
        maxPublishers: Subscribers.Demand = .unlimited,
        _ transform: @escaping (Self.Output) throws -> P?
    ) -> AnyPublisher<T, Error> where T == P.Output, P : Publisher, P.Failure == Error {
        return self
            .mapError { $0 }
            .flatMap(maxPublishers: maxPublishers) { output -> AnyPublisher<P.Output, Error> in
                do {
                    guard let result: AnyPublisher<T, Error> = try transform(output)?.eraseToAnyPublisher() else {
                        throw PublisherError.targetPublisherIsNull
                    }
                    
                    return result
                }
                catch {
                    return Fail<P.Output, Error>(error: error)
                        .eraseToAnyPublisher()
                }
            }
            .eraseToAnyPublisher()
    }
    
    func catchOptional<P>(
        _ handler: @escaping (Self.Failure) -> P?
    ) -> AnyPublisher<P.Output, Error> where P : Publisher, Self.Output == P.Output, P.Failure == Error {
        return self
            .catch { error in
                guard let result: AnyPublisher<P.Output, Error> = handler(error)?.eraseToAnyPublisher() else {
                    return Fail<P.Output, Error>(error: PublisherError.targetPublisherIsNull)
                        .eraseToAnyPublisher()
                }
                
                return result
            }
            .eraseToAnyPublisher()
    }
    
    func subscribe<S>(
        on scheduler: S,
        options: S.SchedulerOptions? = nil,
        using dependencies: Dependencies
    ) -> AnyPublisher<Output, Failure> where S: Scheduler {
        guard !dependencies.forceSynchronous else { return self.eraseToAnyPublisher() }
        
        return self.subscribe(on: scheduler, options: options)
            .eraseToAnyPublisher()
    }
    
    func receive<S>(
        on scheduler: S,
        options: S.SchedulerOptions? = nil,
        using dependencies: Dependencies
    ) -> AnyPublisher<Output, Failure> where S: Scheduler {
        guard !dependencies.forceSynchronous else { return self.eraseToAnyPublisher() }
        
        return self.receive(on: scheduler, options: options)
            .eraseToAnyPublisher()
    }
    
    func manualRefreshFrom(_ refreshTrigger: some Publisher<Void, Never>) -> AnyPublisher<Output, Failure> {
        return Publishers
            .CombineLatest(refreshTrigger.prepend(()).setFailureType(to: Failure.self), self)
            .map { _, value in value }
            .eraseToAnyPublisher()
    }
    
    func withPrevious() -> AnyPublisher<(previous: Output?, current: Output), Failure> {
        scan(Optional<(Output?, Output)>.none) { ($0?.1, $1) }
            .compactMap { $0 }
            .eraseToAnyPublisher()
    }
    
    func withPrevious(_ initialPreviousValue: Output) -> AnyPublisher<(previous: Output, current: Output), Failure> {
        scan((initialPreviousValue, initialPreviousValue)) { ($0.1, $1) }.eraseToAnyPublisher()
    }
}

// MARK: - Convenience

public extension Publisher {
    func sink(into subject: PassthroughSubject<Output, Failure>?, includeCompletions: Bool = false) -> AnyCancellable {
        guard let targetSubject: PassthroughSubject<Output, Failure> = subject else { return AnyCancellable {} }
        
        return sink(into: targetSubject, includeCompletions: includeCompletions)
    }
    
    /// Automatically retains the subscription until it emits a 'completion' event
    func sinkUntilComplete(
        receiveCompletion: ((Subscribers.Completion<Failure>) -> Void)? = nil,
        receiveValue: ((Output) -> Void)? = nil
    ) {
        var retainCycle: Cancellable? = nil
        retainCycle = self
            .sink(
                receiveCompletion: { result in
                    receiveCompletion?(result)
                    
                    // Redundant but without reading 'retainCycle' it will warn that the variable
                    // isn't used
                    if retainCycle != nil { retainCycle = nil }
                },
                receiveValue: (receiveValue ?? { _ in })
            )
    }
}

public extension Publisher {
    /// Converts the publisher to output a Result instead of throwing an error, can be used to ensure a subscription never
    /// closes due to a failure
    func asResult() -> AnyPublisher<Result<Output, Failure>, Never> {
        self
            .map { Result<Output, Failure>.success($0) }
            .catch { Just(Result<Output, Failure>.failure($0)).eraseToAnyPublisher() }
            .eraseToAnyPublisher()
    }
}

extension AnyPublisher: @retroactive ExpressibleByArrayLiteral where Output: RangeReplaceableCollection {
    public init(arrayLiteral elements: Output.Element...) {
        self = Just(Output(elements)).setFailureType(to: Failure.self).eraseToAnyPublisher()
    }
}
