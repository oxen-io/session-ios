// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB

// MARK: - Cache

internal extension Cache {
    static let transactionObserver: CacheConfig<TransactionObserverCacheType, TransactionObserverImmutableCacheType> = Dependencies.create(
        identifier: "transactionObserver",
        createInstance: { dependencies in Storage.TransactionObserverCache(using: dependencies) },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

public extension Database {
    func create<T>(
        table: T.Type,
        options: TableOptions = [],
        body: (TypedTableDefinition<T>) throws -> Void
    ) throws where T: TableRecord, T: ColumnExpressible {
        try create(table: T.databaseTableName, options: options) { tableDefinition in
            let typedDefinition: TypedTableDefinition<T> = TypedTableDefinition(definition: tableDefinition)
            
            try body(typedDefinition)
        }
    }
    
    func alter<T>(
        table: T.Type,
        body: (TypedTableAlteration<T>) -> Void
    ) throws where T: TableRecord, T: ColumnExpressible {
        try alter(table: T.databaseTableName) { tableAlteration in
            let typedAlteration: TypedTableAlteration<T> = TypedTableAlteration(alteration: tableAlteration)
            
            body(typedAlteration)
        }
    }
    
    func drop<T>(table: T.Type) throws where T: TableRecord {
        try drop(table: T.databaseTableName)
    }
    
    func createIndex<T>(
        withCustomName customName: String? = nil,
        on table: T.Type,
        columns: [T.Columns],
        options: IndexOptions = [],
        condition: (any SQLExpressible)? = nil
    ) throws where T: TableRecord, T: ColumnExpressible {
        guard !columns.isEmpty else { throw StorageError.invalidData }
        
        let indexName: String = (
            customName ??
            "\(T.databaseTableName)_on_\(columns.map { $0.name }.joined(separator: "_and_"))"
        )
        
        try create(
            index: indexName,
            on: T.databaseTableName,
            columns: columns.map { $0.name },
            options: options,
            condition: condition
        )
    }
    
    func makeFTS5Pattern<T>(rawPattern: String, forTable table: T.Type) throws -> FTS5Pattern where T: TableRecord, T: ColumnExpressible {
        return try makeFTS5Pattern(rawPattern: rawPattern, forTable: table.databaseTableName)
    }
    
    func interrupt() {
        guard sqliteConnection != nil else { return }
        
        sqlite3_interrupt(sqliteConnection)
    }
    
    /// This is a custom implementation of the `afterNextTransaction` method which executes the closures within their own
    /// transactions to allow for nesting of 'afterNextTransaction' actions
    ///
    /// **Note:** GRDB doesn't notify read-only transactions to transaction observers
    func afterNextTransactionNested(
        using dependencies: Dependencies,
        onCommit: @escaping (Database) -> Void,
        onRollback: @escaping (Database) -> Void = { _ in }
    ) {
        dependencies.mutate(cache: .transactionObserver) {
            $0.add(self, dedupeId: UUID().uuidString, onCommit: onCommit, onRollback: onRollback)
        }
    }
    
    func afterNextTransactionNestedOnce(
        dedupeId: String,
        using dependencies: Dependencies,
        onCommit: @escaping (Database) -> Void,
        onRollback: @escaping (Database) -> Void = { _ in }
    ) {
        dependencies.mutate(cache: .transactionObserver) {
            $0.add(self, dedupeId: dedupeId, onCommit: onCommit, onRollback: onRollback)
        }
    }
}

internal class TransactionHandler: TransactionObserver {
    private let dependencies: Dependencies
    private let identifier: String
    private let onCommit: (Database) -> Void
    private let onRollback: (Database) -> Void

    init(
        identifier: String,
        onCommit: @escaping (Database) -> Void,
        onRollback: @escaping (Database) -> Void,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.identifier = identifier
        self.onCommit = onCommit
        self.onRollback = onRollback
    }
    
    // Ignore changes
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
    func databaseDidChange(with event: DatabaseEvent) { }
    
    func databaseDidCommit(_ db: Database) {
        dependencies.mutate(cache: .transactionObserver) { $0.remove(for: identifier) }
        
        do {
            try db.inTransaction {
                onCommit(db)
                return .commit
            }
        }
        catch {
            Log.warn(.storage, "afterNextTransactionNested onCommit failed")
        }
    }
    
    func databaseDidRollback(_ db: Database) {
        dependencies.mutate(cache: .transactionObserver) { $0.remove(for: identifier) }
        onRollback(db)
    }
}

// MARK: - TransactionObserver Cache

internal extension Storage {
    class TransactionObserverCache: TransactionObserverCacheType {
        private let dependencies: Dependencies
        public var registeredHandlers: [String: TransactionHandler] = [:]
        
        // MARK: - Initialization
        
        public init(using dependencies: Dependencies) {
            self.dependencies = dependencies
        }
        
        // MARK: - Functions
        
        public func add(
            _ db: Database,
            dedupeId: String,
            onCommit: @escaping (Database) -> Void,
            onRollback: @escaping (Database) -> Void
        ) {
            // Only allow a single observer per `dedupeId` per transaction, this allows us to
            // schedule an action to run at most once per transaction (eg. auto-scheduling a ConfigSyncJob
            // when receiving messages)
            guard registeredHandlers[dedupeId] == nil else { return }
            
            let observer: TransactionHandler = TransactionHandler(
                identifier: dedupeId,
                onCommit: onCommit,
                onRollback: onRollback,
                using: dependencies
            )
            db.add(transactionObserver: observer, extent: .nextTransaction)
            registeredHandlers[dedupeId] = observer
        }
        
        public func remove(for identifier: String) {
            registeredHandlers.removeValue(forKey: identifier)
        }
    }
}

// MARK: - TransactionObserverCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
internal protocol TransactionObserverImmutableCacheType: ImmutableCacheType {
    var registeredHandlers: [String: TransactionHandler] { get }
}

internal protocol TransactionObserverCacheType: TransactionObserverImmutableCacheType, MutableCacheType {
    var registeredHandlers: [String: TransactionHandler] { get }
    
    func add(
        _ db: Database,
        dedupeId: String,
        onCommit: @escaping (Database) -> Void,
        onRollback: @escaping (Database) -> Void
    )
    func remove(for identifier: String)
}
