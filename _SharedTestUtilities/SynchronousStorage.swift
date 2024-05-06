// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB

@testable import SessionUtilitiesKit

class SynchronousStorage: Storage {
    public init(
        customWriter: DatabaseWriter? = nil,
        migrationTargets: [MigratableTarget.Type]? = nil,
        migrations: [Storage.KeyedMigration]? = nil,
        using dependencies: Dependencies,
        initialData: ((Database) throws -> ())? = nil
    ) {
        super.init(customWriter: customWriter, using: dependencies)
        
        // Process any migration targets first
        if let migrationTargets: [MigratableTarget.Type] = migrationTargets {
            perform(
                migrationTargets: migrationTargets,
                async: false,
                onProgressUpdate: nil,
                onMigrationRequirement: { _, _ in },
                onComplete: { _, _ in },
                using: dependencies
            )
        }
        
        // Then process any provided migration info
        if let migrations: [Storage.KeyedMigration] = migrations {
            perform(
                sortedMigrations: migrations,
                async: false,
                onProgressUpdate: nil,
                onMigrationRequirement: { _, _ in },
                onComplete: { _, _ in },
                using: dependencies
            )
        }
        
        write { db in try initialData?(db) }
    }
    
    @discardableResult override func write<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        using dependencies: Dependencies = Dependencies(),
        updates: @escaping (Database) throws -> T?
    ) -> T? {
        guard isValid, let dbWriter: DatabaseWriter = testDbWriter else { return nil }
        
        // If 'forceSynchronous' is true then it's likely that we will access the database in
        // a reentrant way, the 'unsafeReentrant...' functions allow us to interact with the
        // database without worrying about reentrant access during tests because we can be
        // confident that the tests are running on the correct thread
        guard !dependencies.forceSynchronous else {
            return try? dbWriter.unsafeReentrantWrite(updates)
        }
        
        return super.write(
            fileName: fileName,
            functionName: functionName,
            lineNumber: lineNumber,
            using: dependencies,
            updates: updates
        )
    }
    
    @discardableResult override func read<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        using dependencies: Dependencies = Dependencies(),
        _ value: @escaping (Database) throws -> T?
    ) -> T? {
        guard isValid, let dbWriter: DatabaseWriter = testDbWriter else { return nil }
        
        // If 'forceSynchronous' is true then it's likely that we will access the database in
        // a reentrant way, the 'unsafeReentrant...' functions allow us to interact with the
        // database without worrying about reentrant access during tests because we can be
        // confident that the tests are running on the correct thread
        guard !dependencies.forceSynchronous else {
            return try? dbWriter.unsafeReentrantRead(value)
        }
        
        return super.read(
            fileName: fileName,
            functionName: functionName,
            lineNumber: lineNumber,
            using: dependencies,
            value
        )
    }
    
    // MARK: - Async Methods
    
    override func readPublisher<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        using dependencies: Dependencies = Dependencies(),
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
                .eraseToAnyPublisher()
        }
        
        return super.readPublisher(fileName: fileName, functionName: functionName, lineNumber: lineNumber, using: dependencies, value: value)
    }
    
    override func writeAsync<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        using dependencies: Dependencies = Dependencies(),
        updates: @escaping (Database) throws -> T,
        completion: @escaping (Database, Result<T, Error>) throws -> Void
    ) {
        do {
            let result: T = try write(using: dependencies, updates: updates) ?? { throw StorageError.failedToSave }()
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
        using dependencies: Dependencies = Dependencies(),
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
                .eraseToAnyPublisher()
        }
        
        return super.writePublisher(fileName: fileName, functionName: functionName, lineNumber: lineNumber, using: dependencies, updates: updates)
    }
}
