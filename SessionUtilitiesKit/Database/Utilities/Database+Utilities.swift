// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB

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
        onCommit: @escaping (Database) -> Void,
        onRollback: @escaping (Database) -> Void = { _ in }
    ) {
        afterNextTransactionNestedOnce(
            dedupeId: UUID().uuidString,
            onCommit: onCommit,
            onRollback: onRollback
        )
    }
    
    func afterNextTransactionNestedOnce(
        dedupeId: String,
        onCommit: @escaping (Database) -> Void,
        onRollback: @escaping (Database) -> Void = { _ in }
    ) {
        // Only allow a single observer per `dedupeId` per transaction, this allows us to
        // schedule an action to run at most once per transaction (eg. auto-scheduling a ConfigSyncJob
        // when receiving messages)
        guard !TransactionHandler.registeredHandlers.wrappedValue.contains(dedupeId) else { return }
        
        add(
            transactionObserver: TransactionHandler(
                identifier: dedupeId,
                onCommit: onCommit,
                onRollback: onRollback
            ),
            extent: .nextTransaction
        )
    }
}

fileprivate class TransactionHandler: TransactionObserver {
    static var registeredHandlers: Atomic<Set<String>> = Atomic([])
    
    let identifier: String
    let onCommit: (Database) -> Void
    let onRollback: (Database) -> Void

    init(
        identifier: String,
        onCommit: @escaping (Database) -> Void,
        onRollback: @escaping (Database) -> Void
    ) {
        self.identifier = identifier
        self.onCommit = onCommit
        self.onRollback = onRollback
        
        TransactionHandler.registeredHandlers.mutate { $0.insert(identifier) }
    }
    
    // Ignore changes
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
    func databaseDidChange(with event: DatabaseEvent) { }
    
    func databaseDidCommit(_ db: Database) {
        TransactionHandler.registeredHandlers.mutate { $0.remove(identifier) }
        
        do {
            try db.inTransaction {
                onCommit(db)
                return .commit
            }
        }
        catch {
            Log.warn("[Database] afterNextTransactionNested onCommit failed")
        }
    }
    
    func databaseDidRollback(_ db: Database) {
        TransactionHandler.registeredHandlers.mutate { $0.remove(identifier) }
        onRollback(db)
    }
}
