// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Quick
import Nimble
import SessionUtil
import SessionUIKit
import SessionSnodeKit

@testable import Session
@testable import SessionMessagingKit
@testable import SessionUtilitiesKit

class DatabaseSpec: QuickSpec {
    fileprivate static let ignoredTables: Set<String> = [
        "sqlite_sequence", "grdb_migrations", "*_fts*"
    ]
    
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
            }
        )
        @TestState(cache: .libSession, in: dependencies) var libSessionCache: LibSession.Cache! = LibSession.Cache()
        @TestState var initialResult: Result<Void, Error>! = nil
        @TestState var finalResult: Result<Void, Error>! = nil
        
        let allMigrations: [Storage.KeyedMigration] = SynchronousStorage.sortedMigrationInfo(
            migrationTargets: [
                SNUtilitiesKit.self,
                SNSnodeKit.self,
                SNMessagingKit.self,
                SNUIKit.self
            ]
        )
        let dynamicTests: [MigrationTest] = MigrationTest.extractTests(allMigrations)
        let allDatabaseTypes: [(TableRecord & FetchableRecord).Type] = MigrationTest.extractDatabaseTypes(allMigrations)
        MigrationTest.explicitValues = [
            // Specific enum values needed
            TableColumn(SessionThread.self, .notificationSound): 1000,
            TableColumn(ConfigDump.self, .variant): "userProfile",
            
            // libSession will throw if we try to insert a community with an invalid
            // 'server' value or a room that is too long
            TableColumn(OpenGroup.self, .server): "https://www.oxen.io",
            TableColumn(OpenGroup.self, .roomToken): "testRoom",
            
            // libSession will fail to load state if the ConfigDump data is invalid
            TableColumn(ConfigDump.self, .data): Data()
        ]
        
        // MARK: - a Database
        describe("a Database") {
            // MARK: -- can be created from an empty state
            it("can be created from an empty state") {
                mockStorage.perform(
                    migrationTargets: [
                        SNUtilitiesKit.self,
                        SNSnodeKit.self,
                        SNMessagingKit.self,
                        SNUIKit.self
                    ],
                    async: false,
                    onProgressUpdate: nil,
                    onMigrationRequirement: { [dependencies = dependencies!] db, requirement in
                        MigrationTest.handleRequirements(db, requirement: requirement, using: dependencies)
                    },
                    onComplete: { result, _ in initialResult = result },
                    using: dependencies
                )
                
                expect(initialResult).to(beSuccess())
            }
            
            // MARK: -- can still parse the database types
            it("can still parse the database types") {
                mockStorage.perform(
                    sortedMigrations: allMigrations,
                    async: false,
                    onProgressUpdate: nil,
                    onMigrationRequirement: { [dependencies = dependencies!] db, requirement in
                        MigrationTest.handleRequirements(db, requirement: requirement, using: dependencies)
                    },
                    onComplete: { result, _ in initialResult = result },
                    using: dependencies
                )
                expect(initialResult).to(beSuccess())
                
                // Generate dummy data (fetching below won't do anything)
                expect(try MigrationTest.generateDummyData(mockStorage, nullsWherePossible: false))
                    .toNot(throwError())
                
                // Fetch the records which are required by the migrations or were modified by them to
                // ensure the decoding is also still working correctly
                mockStorage.read { db in
                    allDatabaseTypes.forEach { table in
                        expect { try table.fetchAll(db) }.toNot(throwError())
                    }
                }
            }
            
            // MARK: -- can still parse the database types setting null where possible
            it("can still parse the database types setting null where possible") {
                mockStorage.perform(
                    sortedMigrations: allMigrations,
                    async: false,
                    onProgressUpdate: nil,
                    onMigrationRequirement: { [dependencies = dependencies!] db, requirement in
                        MigrationTest.handleRequirements(db, requirement: requirement, using: dependencies)
                    },
                    onComplete: { result, _ in initialResult = result },
                    using: dependencies
                )
                expect(initialResult).to(beSuccess())
                
                // Generate dummy data (fetching below won't do anything)
                expect(try MigrationTest.generateDummyData(mockStorage, nullsWherePossible: true))
                    .toNot(throwError())
                
                // Fetch the records which are required by the migrations or were modified by them to
                // ensure the decoding is also still working correctly
                mockStorage.read { db in
                    allDatabaseTypes.forEach { table in
                        expect { try table.fetchAll(db) }.toNot(throwError())
                    }
                }
            }
            
            // MARK: -- can migrate from X to Y
            dynamicTests.forEach { test in
                it("can migrate from \(test.initialMigrationKey) to \(test.finalMigrationKey)") {
                    mockStorage.perform(
                        sortedMigrations: test.initialMigrations,
                        async: false,
                        onProgressUpdate: nil,
                        onMigrationRequirement: { [dependencies = dependencies!] db, requirement in
                            MigrationTest.handleRequirements(db, requirement: requirement, using: dependencies)
                        },
                        onComplete: { result, _ in initialResult = result },
                        using: dependencies
                    )
                    expect(initialResult).to(beSuccess())
                    
                    // Generate dummy data (otherwise structural issues or invalid foreign keys won't error)
                    expect(try MigrationTest.generateDummyData(mockStorage, nullsWherePossible: false))
                        .toNot(throwError())
                    
                    // Peform the target migrations to ensure the migrations themselves worked correctly
                    mockStorage.perform(
                        sortedMigrations: test.migrationsToTest,
                        async: false,
                        onProgressUpdate: nil,
                        onMigrationRequirement: { [dependencies = dependencies!] db, requirement in
                            MigrationTest.handleRequirements(db, requirement: requirement, using: dependencies)
                        },
                        onComplete: { result, _ in finalResult = result },
                        using: dependencies
                    )
                    expect(finalResult).to(beSuccess())
                    
                    /// Ensure all of the `fetchedTables` records can still be decoded correctly after the migrations have completed (since
                    /// we perform multiple migrations above it's possible these won't work after the `initialMigrations` but actually will
                    /// work when required as an intermediate migration could have satisfied the data requirements)
                    mockStorage.read { db in
                        test.migrationsToTest.forEach { _, _, migration in
                            migration.fetchedTables.forEach { table in
                                expect { try table.fetchAll(db) }.toNot(throwError())
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Convenience

private extension Database.ColumnType {
    init(rawValue: Any) {
        switch rawValue as? String {
            case .some(let value): self = Database.ColumnType(rawValue: value)
            case .none: self = Database.ColumnType.any
        }
    }
}

private struct TableColumn: Hashable {
    let tableName: String
    let columnName: String
    
    init<T: TableRecord & ColumnExpressible>(_ type: T.Type, _ column: T.Columns) {
        self.tableName = T.databaseTableName
        self.columnName = column.name
    }
    
    init?(_ tableName: String, _ columnName: Any?) {
        guard let finalColumnName: String = columnName as? String else { return nil }
        
        self.tableName = tableName
        self.columnName = finalColumnName
    }
}

private class MigrationTest {
    static var explicitValues: [TableColumn: (any DatabaseValueConvertible)] = [:]
    
    let initialMigrations: [Storage.KeyedMigration]
    let migrationsToTest: [Storage.KeyedMigration]
    
    var initialMigrationKey: String { return (initialMigrations.last?.key ?? "an empty database") }
    var finalMigrationKey: String { return (migrationsToTest.last?.key ?? "invalid") }

    private init(
        initialMigrations: [Storage.KeyedMigration],
        migrationsToTest: [Storage.KeyedMigration]
    ) {
        self.initialMigrations = initialMigrations
        self.migrationsToTest = migrationsToTest
    }
    
    // MARK: - Test Data
    
    static func extractTests(_ allMigrations: [Storage.KeyedMigration]) -> [MigrationTest] {
        return (0..<(allMigrations.count - 1))
            .flatMap { index -> [MigrationTest] in
                ((index + 1)..<allMigrations.count).map { targetMigrationIndex -> MigrationTest in
                    MigrationTest(
                        initialMigrations: Array(allMigrations[0..<index]),
                        migrationsToTest: Array(allMigrations[index..<targetMigrationIndex])
                    )
                }
            }
    }
    
    static func extractDatabaseTypes(_ allMigrations: [Storage.KeyedMigration]) -> [(TableRecord & FetchableRecord).Type] {
        return allMigrations
            .reduce(into: [:]) { result, next in
                next.migration.fetchedTables.forEach { table in
                    result[ObjectIdentifier(table).hashValue] = table
                }
                
                next.migration.createdOrAlteredTables.forEach { table in
                    result[ObjectIdentifier(table).hashValue] = table
                }
            }
            .values
            .asArray()
    }
    
    static func handleRequirements(_ db: Database, requirement: MigrationRequirement, using dependencies: Dependencies) {
        switch requirement {
            case .libSessionStateLoaded:
                guard Identity.userExists(db, using: dependencies) else { return }
                
                // After the migrations have run but before the migration completion we load the
                // LibSession state
                LibSession.loadState(db, using: dependencies)
        }
    }
    
    // MARK: - Mock Data
    
    static func generateDummyData(_ storage: Storage, nullsWherePossible: Bool) throws {
        var generationError: Error? = nil
        
        // The `PRAGMA foreign_keys` is a no-op within a transaction so we have to do it outside of one
        try storage.testDbWriter?.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA foreign_keys = OFF") }
        storage.write { db in
            do {
                try MigrationTest.generateDummyData(db, nullsWherePossible: nullsWherePossible)
                try db.checkForeignKeys()
            }
            catch { generationError = error }
        }
        try storage.testDbWriter?.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        
        // Throw the error if there was one
        if let error: Error = generationError { throw error }
    }
    
    private static func generateDummyData(_ db: Database, nullsWherePossible: Bool) throws {
        // Fetch table schema information
        let disallowedPrefixes: Set<String> = DatabaseSpec.ignoredTables
            .filter { $0.hasPrefix("*") && !$0.hasSuffix("*") }
            .map { String($0[$0.index(after: $0.startIndex)...]) }
            .asSet()
        let disallowedSuffixes: Set<String> = DatabaseSpec.ignoredTables
            .filter { $0.hasSuffix("*") && !$0.hasPrefix("*") }
            .map { String($0[$0.startIndex..<$0.index(before: $0.endIndex)]) }
            .asSet()
        let disallowedContains: Set<String> = DatabaseSpec.ignoredTables
            .filter { $0.hasPrefix("*") && $0.hasSuffix("*") }
            .map { String($0[$0.index(after: $0.startIndex)..<$0.index(before: $0.endIndex)]) }
            .asSet()
        let tables: [Row] = try Row
            .fetchAll(db, sql: "SELECT * from sqlite_schema WHERE type = 'table'")
            .filter { tableInfo -> Bool in
                guard let name: String = tableInfo["name"] else { return false }
                
                return (
                    !DatabaseSpec.ignoredTables.contains(name) &&
                    !disallowedPrefixes.contains(where: { name.hasPrefix($0) }) &&
                    !disallowedSuffixes.contains(where: { name.hasSuffix($0) }) &&
                    !disallowedContains.contains(where: { name.contains($0) })
                )
            }
        
        // Generate data via schema inspection for all other tables
        try tables.forEach { tableInfo in
            switch tableInfo["name"] as? String {
                case .none: throw StorageError.generic
                
                case Identity.databaseTableName:
                    // If there is an 'Identity' table then insert "proper" identity info (otherwise mock
                    // data might get deleted as invalid in libSession migrations)
                    try [
                        Identity(variant: .x25519PublicKey, data: Data.data(fromHex: TestConstants.publicKey)!),
                        Identity(variant: .x25519PrivateKey, data: Data.data(fromHex: TestConstants.privateKey)!),
                        Identity(variant: .ed25519PublicKey, data: Data.data(fromHex: TestConstants.edPublicKey)!),
                        Identity(variant: .ed25519SecretKey, data: Data.data(fromHex: TestConstants.edSecretKey)!)
                    ].forEach { try $0.insert(db) }
                    
                case .some(let name):
                    // No need to insert dummy data if it already exists in the table
                    guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM '\(name)'") == 0 else { return }
                    
                    let columnInfo: [Row] = try Row.fetchAll(db, sql: "PRAGMA table_info('\(name)');")
                    let validNames: [String] = columnInfo.compactMap { $0["name"].map { "'\($0)'" } }
                    let columnNames: String = validNames.joined(separator: ", ")
                    let columnArgs: String = validNames.map { _ in "?" }.joined(separator: ", ")
                    
                    try db.execute(
                        sql: "INSERT INTO \(name) (\(columnNames)) VALUES (\(columnArgs))",
                        arguments: StatementArguments(columnInfo.map { column in
                            // If we want to allow setting nulls (and the column is nullable but not a primary
                            // key) then use null for it's value
                            guard !nullsWherePossible || column["notnull"] != 0 || column["pk"] == 1 else {
                                return nil
                            }
                            
                            // If this column has an explicitly defined value then use that
                            if
                                let key: TableColumn = TableColumn(name, column["name"]),
                                let explicitValue: (any DatabaseValueConvertible) = MigrationTest.explicitValues[key]
                            {
                                return explicitValue
                            }
                            
                            // Otherwise generate some mock data (trying to use potentially real values in case
                            // something is a primary/foreign key)
                            switch Database.ColumnType(rawValue: column["type"]) {
                                case .text: return "05\(TestConstants.publicKey)"
                                case .blob: return Data([1, 2, 3])
                                case .boolean: return false
                                case .integer, .numeric, .double, .real: return 1
                                case .date, .datetime: return Date(timeIntervalSince1970: 1234567890)
                                case .any: return nil
                                default: return nil
                            }
                        })
                    )
            }
        }
    }
}
