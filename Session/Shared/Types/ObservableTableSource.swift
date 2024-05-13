// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Combine
import DifferenceKit
import SessionUtilitiesKit

// MARK: - ObservableTableSource

public protocol ObservableTableSource: AnyObject, SectionedTableData {
    typealias TargetObservation = TableObservation<[SectionModel]>
    typealias TargetPublisher = AnyPublisher<(([SectionModel], StagedChangeset<[SectionModel]>)), Error>
    
    var dependencies: Dependencies { get }
    var state: TableDataState<Section, TableItem> { get }
    var observableState: ObservableTableSourceState<Section, TableItem> { get }
    var observation: TargetObservation { get }
    
    // MARK: - Functions
    
    func didReturnFromBackground()
}

extension ObservableTableSource {
    public var pendingTableDataSubject: CurrentValueSubject<([SectionModel], StagedChangeset<[SectionModel]>), Never> {
        self.observableState.pendingTableDataSubject
    }
    public var observation: TargetObservation {
        ObservationBuilder.changesetSubject(self.observableState.pendingTableDataSubject)
    }
    
    public var tableDataPublisher: TargetPublisher { self.observation.finalPublisher(self, using: dependencies) }
    
    public func didReturnFromBackground() {}
    public func forceRefresh() { self.observableState._forcedRefresh.send(()) }
}

// MARK: - State Manager (ObservableTableSource)

public class ObservableTableSourceState<Section: SessionTableSection, TableItem: Hashable & Differentiable>: SectionedTableData {
    public let forcedRefresh: AnyPublisher<Void, Never>
    public let pendingTableDataSubject: CurrentValueSubject<([SectionModel], StagedChangeset<[SectionModel]>), Never>
    
    // MARK: - Internal Variables
    
    fileprivate var hasEmittedInitialData: Bool
    fileprivate let _forcedRefresh: PassthroughSubject<Void, Never> = PassthroughSubject()
    
    // MARK: - Initialization
    
    init() {
        self.hasEmittedInitialData = false
        self.forcedRefresh = _forcedRefresh.shareReplay(0)
        self.pendingTableDataSubject = CurrentValueSubject(([], StagedChangeset()))
    }
}

// MARK: - TableObservation

public struct TableObservation<T> {
    fileprivate let generatePublisher: (any ObservableTableSource, Dependencies) -> AnyPublisher<T, Error>
    fileprivate let generatePublisherWithChangeset: ((any ObservableTableSource, Dependencies) -> AnyPublisher<Any, Error>)?
    
    init(generatePublisher: @escaping (any ObservableTableSource, Dependencies) -> AnyPublisher<T, Error>) {
        self.generatePublisher = generatePublisher
        self.generatePublisherWithChangeset = nil
    }
    
    init(generatePublisherWithChangeset: @escaping (any ObservableTableSource, Dependencies) -> AnyPublisher<(T, StagedChangeset<T>), Error>) where T: Collection {
        self.generatePublisher = { _, _ in Fail(error: StorageError.invalidData).eraseToAnyPublisher() }
        self.generatePublisherWithChangeset = { source, dependencies in
            generatePublisherWithChangeset(source, dependencies).map { $0 as Any }.eraseToAnyPublisher()
        }
    }
    
    fileprivate func finalPublisher<S: ObservableTableSource>(
        _ source: S,
        using dependencies: Dependencies
    ) -> S.TargetPublisher {
        typealias TargetData = (([S.SectionModel], StagedChangeset<[S.SectionModel]>))
        
        switch (self, self.generatePublisherWithChangeset) {
            case (_, .some(let generatePublisherWithChangeset)):
                return generatePublisherWithChangeset(source, dependencies)
                    .tryMap { data -> TargetData in
                        guard let convertedData: TargetData = data as? TargetData else {
                            throw StorageError.invalidData
                        }
                        
                        return convertedData
                    }
                    .eraseToAnyPublisher()
                
            case (let validObservation as S.TargetObservation, _):
                // Doing `removeDuplicates` in case the conversion from the original data to [SectionModel]
                // can result in duplicate output even with some different inputs
                return validObservation.generatePublisher(source, dependencies)
                    .removeDuplicates()
                    .mapToSessionTableViewData(for: source)
                
            default: return Fail(error: StorageError.invalidData).eraseToAnyPublisher()
        }
    }
}

extension TableObservation: ExpressibleByArrayLiteral where T: Collection {
    public init(arrayLiteral elements: T.Element?...) {
        self.init(
            generatePublisher: { _, _ in
                guard let convertedElements: T = Array(elements.compactMap { $0 }) as? T else {
                    return Fail(error: StorageError.invalidData).eraseToAnyPublisher()
                }
                
                return Just(convertedElements)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
        )
    }
}

// MARK: - ObservationBuilder

public enum ObservationBuilder {
    /// The `subject` will emit immediately when there is a subscriber and store the most recent value to be emitted whenever a new subscriber is
    /// added
    static func subject<T: Equatable>(_ subject: CurrentValueSubject<T, Error>) -> TableObservation<T> {
        return TableObservation { _, _ in
            return subject
                .removeDuplicates()
                .eraseToAnyPublisher()
        }
    }
    
    /// The `subject` will emit immediately when there is a subscriber and store the most recent value to be emitted whenever a new subscriber is
    /// added
    static func subject<T: Equatable>(_ subject: CurrentValueSubject<T, Never>) -> TableObservation<T> {
        return TableObservation { _, _ in
            return subject
                .removeDuplicates()
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
    }
    
    /// The `ValueObserveration` will trigger whenever any of the data fetched in the closure is updated, please see the following link for tips
    /// to help optimise performance https://github.com/groue/GRDB.swift#valueobservation-performance
    static func databaseObservation<S: ObservableTableSource, T: Equatable>(_ source: S, fetch: @escaping (Database) throws -> T) -> TableObservation<T> {
        /// **Note:** This observation will be triggered twice immediately (and be de-duped by the `removeDuplicates`)
        /// this is due to the behaviour of `ValueConcurrentObserver.asyncStartObservation` which triggers it's own
        /// fetch (after the ones in `ValueConcurrentObserver.asyncStart`/`ValueConcurrentObserver.syncStart`)
        /// just in case the database has changed between the two reads - unfortunately it doesn't look like there is a way to prevent this
        return TableObservation { viewModel, dependencies in
            return ValueObservation
                .trackingConstantRegion(fetch)
                .removeDuplicates()
                .handleEvents(didFail: { SNLog("[\(type(of: viewModel))] Observation failed with error: \($0)") })
                .publisher(in: dependencies.storage, scheduling: dependencies.scheduler)
                .manualRefreshFrom(source.observableState.forcedRefresh)
        }
    }
    
    /// The `ValueObserveration` will trigger whenever any of the data fetched in the closure is updated, please see the following link for tips
    /// to help optimise performance https://github.com/groue/GRDB.swift#valueobservation-performance
    static func databaseObservation<S: ObservableTableSource, T: Equatable>(_ source: S, fetch: @escaping (Database) throws -> [T]) -> TableObservation<[T]> {
        /// **Note:** This observation will be triggered twice immediately (and be de-duped by the `removeDuplicates`)
        /// this is due to the behaviour of `ValueConcurrentObserver.asyncStartObservation` which triggers it's own
        /// fetch (after the ones in `ValueConcurrentObserver.asyncStart`/`ValueConcurrentObserver.syncStart`)
        /// just in case the database has changed between the two reads - unfortunately it doesn't look like there is a way to prevent this
        return TableObservation { viewModel, dependencies in
            return ValueObservation
                .trackingConstantRegion(fetch)
                .removeDuplicates()
                .handleEvents(didFail: { SNLog("[\(type(of: viewModel))] Observation failed with error: \($0)") })
                .publisher(in: dependencies.storage, scheduling: dependencies.scheduler)
                .manualRefreshFrom(source.observableState.forcedRefresh)
        }
    }
    
    /// The `changesetSubject` will emit immediately when there is a subscriber and store the most recent value to be emitted whenever a new subscriber is
    /// added
    static func changesetSubject<T>(
        _ subject: CurrentValueSubject<([T], StagedChangeset<[T]>), Never>
    ) -> TableObservation<[T]> {
        return TableObservation { viewModel, dependencies in
            subject
                .withPrevious(([], StagedChangeset()))
                .filter { prev, next in
                    /// Suppress events with no changes (these will be sent in order to clear out the `StagedChangeset` value as if we
                    /// don't do so then resubscribing will result in an attempt to apply an invalid changeset to the `tableView` resulting
                    /// in a crash)
                    !next.1.isEmpty
                }
                .map { _, current -> ([T], StagedChangeset<[T]>) in current }
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
    }
}

// MARK: - Convenience Transforms

public extension TableObservation {
    func map<R>(transform: @escaping (T) -> R) -> TableObservation<R> {
        return TableObservation<R> { viewModel, dependencies in
            self.generatePublisher(viewModel, dependencies).map(transform).eraseToAnyPublisher()
        }
    }
    
    func mapWithPrevious<R>(transform: @escaping (T?, T) -> R) -> TableObservation<R> {
        return TableObservation<R> { viewModel, dependencies in
            self.generatePublisher(viewModel, dependencies)
                .withPrevious()
                .map(transform)
                .eraseToAnyPublisher()
        }
    }
    
    func compactMapWithPrevious<R>(transform: @escaping (T?, T) -> R?) -> TableObservation<R> {
        return TableObservation<R> { viewModel, dependencies in
            self.generatePublisher(viewModel, dependencies)
                .withPrevious()
                .compactMap(transform)
                .eraseToAnyPublisher()
        }
    }
}

public extension Array {
    func mapToSessionTableViewData<S: ObservableTableSource>(
        for source: S?
    ) -> [ArraySection<S.Section, SessionCell.Info<S.TableItem>>] where Element == ArraySection<S.Section, SessionCell.Info<S.TableItem>> {
        // Update the data to include the proper position for each element
        return self.map { section in
            ArraySection(
                model: section.model,
                elements: section.elements.enumerated().map { index, element in
                    element.updatedPosition(for: index, count: section.elements.count)
                }
            )
        }
    }
}

public extension Publisher {
    func mapToSessionTableViewData<S: ObservableTableSource>(
        for source: S
    ) -> AnyPublisher<(Output, StagedChangeset<Output>), Failure> where Output == [ArraySection<S.Section, SessionCell.Info<S.TableItem>>] {
        return self
            .map { [weak source] updatedData -> (Output, StagedChangeset<Output>) in
                let updatedDataWithPositions: Output = updatedData
                    .mapToSessionTableViewData(for: source)
                
                // Generate an updated changeset
                let changeset = StagedChangeset(
                    source: (source?.state.tableData ?? []),
                    target: updatedDataWithPositions
                )
                
                return (updatedDataWithPositions, changeset)
            }
            .filter { [weak source] _, changeset in
                source?.observableState.hasEmittedInitialData == false ||   // Always emit at least once
                !changeset.isEmpty                                          // Do nothing if there were no changes
            }
            .handleEvents(receiveOutput: { [weak source] _ in
                source?.observableState.hasEmittedInitialData = true
            })
            .eraseToAnyPublisher()
    }
}
