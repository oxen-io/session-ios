// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB

@testable import SessionUtilitiesKit

class SynchronousStorage: Storage {
    private let dependencies: Dependencies
    
    public init(
        customWriter: DatabaseWriter? = nil,
        migrationTargets: [MigratableTarget.Type]? = nil,
        migrations: [Storage.KeyedMigration]? = nil,
        using dependencies: Dependencies,
        initialData: ((Database) throws -> ())? = nil
    ) {
        self.dependencies = dependencies
        
        super.init(customWriter: customWriter, using: dependencies)
        
        // Process any migration targets first
        if let migrationTargets: [MigratableTarget.Type] = migrationTargets {
            perform(
                migrationTargets: migrationTargets,
                async: false,
                onProgressUpdate: nil,
                onMigrationRequirement: { _, _ in },
                onComplete: { _, _ in }
            )
        }
        
        // Then process any provided migration info
        if let migrations: [Storage.KeyedMigration] = migrations {
            perform(
                sortedMigrations: migrations,
                async: false,
                onProgressUpdate: nil,
                onMigrationRequirement: { _, _ in },
                onComplete: { _, _ in }
            )
        }
        
        write { db in try initialData?(db) }
    }
    
    @discardableResult override func write<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        updates: @escaping (Database) throws -> T?
    ) -> T? {
        guard isValid, let dbWriter: DatabaseWriter = testDbWriter else { return nil }
        
        // If 'forceSynchronous' is true then it's likely that we will access the database in
        // a reentrant way, the 'unsafeReentrant...' functions allow us to interact with the
        // database without worrying about reentrant access during tests because we can be
        // confident that the tests are running on the correct thread
        guard !dependencies.forceSynchronous else {
            let result: T?
            let didThrow: Bool
            do {
                result = try dbWriter.unsafeReentrantWrite(updates)
                didThrow = false
            }
            catch {
                result = nil
                didThrow = true
            }
            
            dbWriter.unsafeReentrantWrite { db in
                // Forcibly call the transaction observer when forcing synchronous logic
                dependencies.mutate(cache: .transactionObserver) { cache in
                    let handlers = cache.registeredHandlers
                    handlers.forEach { identifier, observer in
                        if didThrow {
                            observer.databaseDidRollback(db)
                        }
                        else {
                            observer.databaseDidCommit(db)
                        }
                        cache.remove(for: identifier)
                    }
                }
            }
            
            return result
        }
        
        return super.write(
            fileName: fileName,
            functionName: functionName,
            lineNumber: lineNumber,
            updates: updates
        )
    }
    
    @discardableResult override func read<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        _ value: @escaping (Database) throws -> T?
    ) -> T? {
        guard isValid, let dbWriter: DatabaseWriter = testDbWriter else { return nil }
        
        // If 'forceSynchronous' is true then it's likely that we will access the database in
        // a reentrant way, the 'unsafeReentrant...' functions allow us to interact with the
        // database without worrying about reentrant access during tests because we can be
        // confident that the tests are running on the correct thread
        guard !dependencies.forceSynchronous else {
            let result: T?
            let didThrow: Bool
            do {
                result = try dbWriter.unsafeReentrantRead(value)
                didThrow = false
            }
            catch {
                result = nil
                didThrow = true
            }
            
            try? dbWriter.unsafeReentrantRead { db in
                // Forcibly call the transaction observer when forcing synchronous logic
                dependencies.mutate(cache: .transactionObserver) { cache in
                    let handlers = cache.registeredHandlers
                    handlers.forEach { identifier, observer in
                        if didThrow {
                            observer.databaseDidRollback(db)
                        }
                        else {
                            observer.databaseDidCommit(db)
                        }
                        cache.remove(for: identifier)
                    }
                }
            }
            
            return result
        }
        
        return super.read(
            fileName: fileName,
            functionName: functionName,
            lineNumber: lineNumber,
            value
        )
    }
    
    // MARK: - Async Methods
    
    override func readPublisher<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        value: @escaping (Database) throws -> T
    ) -> AnyPublisher<T, Error> {
        guard isValid, let dbWriter: DatabaseWriter = testDbWriter else {
            return Fail(error: StorageError.generic)
                .eraseToAnyPublisher()
        }
        
        // If 'forceSynchronous' is true then it's likely that we will access the database in
        // a reentrant way, the 'unsafeReentrant...' functions allow us to interact with the
        // database without worrying about reentrant access during tests because we can be
        // confident that the tests are running on the correct thread
        guard !dependencies.forceSynchronous else {
            return Just(())
                .setFailureType(to: Error.self)
                .tryMap { _ in try dbWriter.unsafeReentrantRead(value) }
                .handleEvents(
                    receiveCompletion: { [dependencies] result in
                        try? dbWriter.unsafeReentrantRead { db in
                            // Forcibly call the transaction observer when forcing synchronous logic
                            dependencies.mutate(cache: .transactionObserver) { cache in
                                let handlers = cache.registeredHandlers
                                handlers.forEach { identifier, observer in
                                    switch result {
                                        case .finished: observer.databaseDidCommit(db)
                                        case .failure: observer.databaseDidRollback(db)
                                    }
                                    cache.remove(for: identifier)
                                }
                            }
                        }
                        
                    }
                )
                .eraseToAnyPublisher()
        }
        
        return super.readPublisher(fileName: fileName, functionName: functionName, lineNumber: lineNumber, value: value)
    }
    
    override func writeAsync<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        updates: @escaping (Database) throws -> T,
        completion: @escaping (Database, Result<T, Error>) throws -> Void
    ) {
        do {
            let result: T = try write(updates: updates) ?? { throw StorageError.failedToSave }()
            write { db in try completion(db, Result.success(result)) }
        }
        catch {
            write { db in try completion(db, Result.failure(error)) }
        }
    }
    
    override func writePublisher<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        updates: @escaping (Database) throws -> T
    ) -> AnyPublisher<T, Error> {
        guard isValid, let dbWriter: DatabaseWriter = testDbWriter else {
            return Fail(error: StorageError.generic)
                .eraseToAnyPublisher()
        }
        
        // If 'forceSynchronous' is true then it's likely that we will access the database in
        // a reentrant way, the 'unsafeReentrant...' functions allow us to interact with the
        // database without worrying about reentrant access during tests because we can be
        // confident that the tests are running on the correct thread
        guard !dependencies.forceSynchronous else {
            return Just(())
                .setFailureType(to: Error.self)
                .tryMap { _ in try dbWriter.unsafeReentrantWrite(updates) }
                .handleEvents(
                    receiveCompletion: { [dependencies] result in
                        dbWriter.unsafeReentrantWrite { db in
                            // Forcibly call the transaction observer when forcing synchronous logic
                            dependencies.mutate(cache: .transactionObserver) { cache in
                                let handlers = cache.registeredHandlers
                                handlers.forEach { identifier, observer in
                                    switch result {
                                        case .finished: observer.databaseDidCommit(db)
                                        case .failure: observer.databaseDidRollback(db)
                                    }
                                    cache.remove(for: identifier)
                                }
                            }
                        }
                        
                    }
                )
                .eraseToAnyPublisher()
        }
        
        return super.writePublisher(fileName: fileName, functionName: functionName, lineNumber: lineNumber, updates: updates)
    }
}
