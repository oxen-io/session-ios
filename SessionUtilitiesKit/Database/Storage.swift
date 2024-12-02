// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit
import CryptoKit
import Combine
import GRDB

// MARK: - Singleton

public extension Singleton {
    static let storage: SingletonConfig<Storage> = Dependencies.create(
        identifier: "storage",
        createInstance: { dependencies in Storage(using: dependencies) }
    )
    static let scheduler: SingletonConfig<ValueObservationScheduler> = Dependencies.create(
        identifier: "scheduler",
        createInstance: { _ in AsyncValueObservationScheduler.async(onQueue: .main) }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let storage: Log.Category = .create("Storage", defaultLevel: .info)
}

// MARK: - KeychainStorage

public extension KeychainStorage.DataKey { static let dbCipherKeySpec: Self = "GRDBDatabaseCipherKeySpec" }

// MARK: - Storage

open class Storage {
    public static let queuePrefix: String = "SessionDatabase"
    private static let dbFileName: String = "Session.sqlite"
    private static let SQLCipherKeySpecLength: Int = 48
    
    /// If a transaction takes longer than this duration a warning will be logged but the transaction will continue to run
    private static let slowTransactionThreshold: TimeInterval = 3
    
    /// When attempting to do a write the transaction will wait this long to acquite a lock before failing
    private static let writeTransactionStartTimeout: TimeInterval = 5
    
    private static var sharedDatabaseDirectoryPath: String { "\(SessionFileManager.nonInjectedAppSharedDataDirectoryPath)/database" }
    private static var databasePath: String { "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)" }
    private static var databasePathShm: String { "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)-shm" }
    private static var databasePathWal: String { "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)-wal" }
    
    private let dependencies: Dependencies
    private var startupError: Error?
    fileprivate var dbWriter: DatabaseWriter?
    internal var testDbWriter: DatabaseWriter? { dbWriter }
    private var unprocessedMigrationRequirements: Atomic<[MigrationRequirement]> = Atomic(MigrationRequirement.allCases)
    private var migrationProgressUpdater: Atomic<((String, CGFloat) -> ())>?
    private var migrationRequirementProcesser: Atomic<(Database, MigrationRequirement) -> ()>?
    
    // MARK: - Database State Variables
    
    public private(set) var isValid: Bool = false
    public private(set) var isSuspended: Bool = false
    public var isDatabasePasswordAccessible: Bool { ((try? getDatabaseCipherKeySpec()) != nil) }
    
    /// This property gets set the first time we successfully read from the database
    public private(set) var hasSuccessfullyRead: Bool = false
    
    /// This property gets set the first time we successfully write to the database
    public private(set) var hasSuccessfullyWritten: Bool = false
    
    private let migrationsCompleted: Atomic<Bool> = Atomic(false)
    internal let internalCurrentlyRunningMigration: Atomic<(identifier: TargetMigrations.Identifier, migration: Migration.Type)?> = Atomic(nil)
    public var hasCompletedMigrations: Bool { migrationsCompleted.wrappedValue }
    public var currentlyRunningMigration: (identifier: TargetMigrations.Identifier, migration: Migration.Type)? {
        internalCurrentlyRunningMigration.wrappedValue
    }
    
    // MARK: - Initialization
    
    public init(customWriter: DatabaseWriter? = nil, using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        configureDatabase(customWriter: customWriter)
    }
    
    private func configureDatabase(customWriter: DatabaseWriter? = nil) {
        // Create the database directory if needed and ensure it's protection level is set before attempting to
        // create the database KeySpec or the database itself
        try? dependencies[singleton: .fileManager].ensureDirectoryExists(at: Storage.sharedDatabaseDirectoryPath)
        try? dependencies[singleton: .fileManager].protectFileOrFolder(at: Storage.sharedDatabaseDirectoryPath)
        
        // If a custom writer was provided then use that (for unit testing)
        guard customWriter == nil else {
            dbWriter = customWriter
            isValid = true
            return
        }
        
        /// Generate the database KeySpec if needed (this MUST be done before we try to access the database as a different thread
        /// might attempt to access the database before the key is successfully created)
        ///
        /// We reset the bytes immediately after generation to ensure the database key doesn't hang around in memory unintentionally
        ///
        /// **Note:** If we fail to get/generate the keySpec then don't bother continuing to setup the Database as it'll just be invalid,
        /// in this case the App/Extensions will have logic that checks the `isValid` flag of the database
        do {
            var tmpKeySpec: Data = try getOrGenerateDatabaseKeySpec()
            tmpKeySpec.resetBytes(in: 0..<tmpKeySpec.count)
        }
        catch { return }
        
        // Configure the database and create the DatabasePool for interacting with the database
        var config = Configuration()
        config.label = Storage.queuePrefix
        config.maximumReaderCount = 10                   /// Increase the max read connection limit - Default is 5

        /// It seems we should do this per https://github.com/groue/GRDB.swift/pull/1485 but with this change
        /// we then need to define how long a write transaction should wait for before timing out (read transactions always run
        /// in`DEFERRED` mode so won't be affected by these settings)
        config.defaultTransactionKind = .immediate
        config.busyMode = .timeout(Storage.writeTransactionStartTimeout)

        /// Load in the SQLCipher keys
        config.prepareDatabase { [weak self] db in
            var keySpec: Data = try self?.getOrGenerateDatabaseKeySpec() ?? { throw StorageError.invalidKeySpec }()
            defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
            
            // Use a raw key spec, where the 96 hexadecimal digits are provided
            // (i.e. 64 hex for the 256 bit key, followed by 32 hex for the 128 bit salt)
            // using explicit BLOB syntax, e.g.:
            //
            // x'98483C6EB40B6C31A448C22A66DED3B5E5E8D5119CAC8327B655C8B5C483648101010101010101010101010101010101'
            keySpec = try (keySpec.toHexString().data(using: .utf8) ?? { throw StorageError.invalidKeySpec }())
            keySpec.insert(contentsOf: [120, 39], at: 0)    // "x'" prefix
            keySpec.append(39)                              // "'" suffix
            
            try db.usePassphrase(keySpec)
            
            // According to the SQLCipher docs iOS needs the 'cipher_plaintext_header_size' value set to at least
            // 32 as iOS extends special privileges to the database and needs this header to be in plaintext
            // to determine the file type
            //
            // For more info see: https://www.zetetic.net/sqlcipher/sqlcipher-api/#cipher_plaintext_header_size
            try db.execute(sql: "PRAGMA cipher_plaintext_header_size = 32")
        }
        
        // Create the DatabasePool to allow us to connect to the database and mark the storage as valid
        do {
            do {
                dbWriter = try DatabasePool(
                    path: "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)",
                    configuration: config
                )
            }
            catch {
                switch error {
                    case DatabaseError.SQLITE_BUSY:
                        /// According to the docs in GRDB there are a few edge-cases where opening the database
                        /// can fail due to it reporting a "busy" state, by changing the behaviour from `immediateError`
                        /// to `timeout(1)` we give the database a 1 second grace period to deal with it's issues
                        /// and get back into a valid state - adding this helps the database resolve situations where it
                        /// can get confused due to crashing mid-transaction
                        config.busyMode = .timeout(1)
                        Log.warn(.storage, "Database reported busy state during statup, adding grace period to allow startup to continue")
                        
                        // Try to initialise the dbWriter again (hoping the above resolves the lock)
                        dbWriter = try DatabasePool(
                            path: "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)",
                            configuration: config
                        )
                        
                    default: throw error
                }
            }
            isValid = true
        }
        catch { startupError = error }
    }
    
    // MARK: - Migrations
    
    public typealias KeyedMigration = (key: String, identifier: TargetMigrations.Identifier, migration: Migration.Type)
    
    public static func appliedMigrationIdentifiers(_ db: Database) -> Set<String> {
        let migrator: DatabaseMigrator = DatabaseMigrator()
        
        return (try? migrator.appliedIdentifiers(db))
            .defaulting(to: [])
    }
    
    public static func sortedMigrationInfo(migrationTargets: [MigratableTarget.Type]) -> [KeyedMigration] {
        typealias MigrationInfo = (identifier: TargetMigrations.Identifier, migrations: TargetMigrations.MigrationSet)
        
        return migrationTargets
            .map { target -> TargetMigrations in target.migrations() }
            .sorted()
            .reduce(into: [[MigrationInfo]]()) { result, next in
                next.migrations.enumerated().forEach { index, migrationSet in
                    if result.count <= index {
                        result.append([])
                    }

                    result[index] = (result[index] + [(next.identifier, migrationSet)])
                }
            }
            .reduce(into: []) { result, next in
                next.forEach { identifier, migrations in
                    result.append(contentsOf: migrations.map { (identifier.key(with: $0), identifier, $0) })
                }
            }
    }
    
    public func perform(
        migrationTargets: [MigratableTarget.Type],
        async: Bool = true,
        onProgressUpdate: ((CGFloat, TimeInterval) -> ())?,
        onMigrationRequirement: @escaping (Database, MigrationRequirement) -> (),
        onComplete: @escaping (Result<Void, Error>, Bool) -> ()
    ) {
        perform(
            sortedMigrations: Storage.sortedMigrationInfo(migrationTargets: migrationTargets),
            async: async,
            onProgressUpdate: onProgressUpdate,
            onMigrationRequirement: onMigrationRequirement,
            onComplete: onComplete
        )
    }
    
    internal func perform(
        sortedMigrations: [KeyedMigration],
        async: Bool,
        onProgressUpdate: ((CGFloat, TimeInterval) -> ())?,
        onMigrationRequirement: @escaping (Database, MigrationRequirement) -> (),
        onComplete: @escaping (Result<Void, Error>, Bool) -> ()
    ) {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else {
            let error: Error = (startupError ?? StorageError.startupFailed)
            Log.error(.storage, "Statup failed with error: \(error)")
            onComplete(.failure(error), false)
            return
        }
        
        // Setup and run any required migrations
        var migrator: DatabaseMigrator = DatabaseMigrator()
        sortedMigrations.forEach { _, identifier, migration in
            migrator.registerMigration(
                self,
                targetIdentifier: identifier,
                migration: migration,
                using: dependencies
            )
        }
        
        // Determine which migrations need to be performed and gather the relevant settings needed to
        // inform the app of progress/states
        let completedMigrations: [String] = (try? dbWriter.read { db in try migrator.completedMigrations(db) })
            .defaulting(to: [])
        let unperformedMigrations: [KeyedMigration] = sortedMigrations
            .reduce(into: []) { result, next in
                guard !completedMigrations.contains(next.key) else { return }
                
                result.append(next)
            }
        let migrationToDurationMap: [String: TimeInterval] = unperformedMigrations
            .reduce(into: [:]) { result, next in
                result[next.key] = next.migration.minExpectedRunDuration
            }
        let unperformedMigrationDurations: [TimeInterval] = unperformedMigrations
            .map { _, _, migration in migration.minExpectedRunDuration }
        let totalMinExpectedDuration: TimeInterval = migrationToDurationMap.values.reduce(0, +)
        let needsConfigSync: Bool = unperformedMigrations
            .contains(where: { _, _, migration in migration.needsConfigSync })
        
        self.migrationProgressUpdater = Atomic({ targetKey, progress in
            guard let migrationIndex: Int = unperformedMigrations.firstIndex(where: { key, _, _ in key == targetKey }) else {
                return
            }
            
            let completedExpectedDuration: TimeInterval = (
                (migrationIndex > 0 ? unperformedMigrationDurations[0..<migrationIndex].reduce(0, +) : 0) +
                (unperformedMigrationDurations[migrationIndex] * progress)
            )
            let totalProgress: CGFloat = (completedExpectedDuration / totalMinExpectedDuration)
            
            DispatchQueue.main.async {
                onProgressUpdate?(totalProgress, totalMinExpectedDuration)
            }
        })
        self.migrationRequirementProcesser = Atomic(onMigrationRequirement)
        
        // Store the logic to run when the migration completes
        let migrationCompleted: (Result<Void, Error>) -> () = { [weak self, migrator, dbWriter] result in
            // Make sure to transition the progress updater to 100% for the final migration (just
            // in case the migration itself didn't update to 100% itself)
            if let lastMigrationKey: String = unperformedMigrations.last?.key {
                self?.migrationProgressUpdater?.wrappedValue(lastMigrationKey, 1)
            }
            
            // Process any unprocessed requirements which need to be processed before completion
            // then clear out the state
            let requirementProcessor: ((Database, MigrationRequirement) -> ())? = self?.migrationRequirementProcesser?.wrappedValue
            let remainingMigrationRequirements: [MigrationRequirement] = (self?.unprocessedMigrationRequirements.wrappedValue
                .filter { $0.shouldProcessAtCompletionIfNotRequired })
                .defaulting(to: [])
            self?.migrationsCompleted.mutate { $0 = true }
            self?.migrationProgressUpdater = nil
            self?.migrationRequirementProcesser = nil
            
            // Process any remaining migration requirements
            if !remainingMigrationRequirements.isEmpty && requirementProcessor != nil {
                self?.write { db in
                    remainingMigrationRequirements.forEach { requirementProcessor?(db, $0) }
                }
            }
            
            // Reset in case there is a requirement on a migration which runs when returning from
            // the background
            self?.unprocessedMigrationRequirements.mutate { $0 = MigrationRequirement.allCases }
            
            // Don't log anything in the case of a 'success' or if the database is suspended (the
            // latter will happen if the user happens to return to the background too quickly on
            // launch so is unnecessarily alarming, it also gets caught and logged separately by
            // the 'write' functions anyway)
            switch result {
                case .success: break
                case .failure(DatabaseError.SQLITE_ABORT): break
                case .failure(let error):
                    let completedMigrations: [String] = (try? dbWriter
                        .read { db in try migrator.completedMigrations(db) })
                        .defaulting(to: [])
                    let failedMigrationName: String = migrator.migrations
                        .filter { !completedMigrations.contains($0) }
                        .first
                        .defaulting(to: "Unknown")
                    Log.critical(.migration, "Migration '\(failedMigrationName)' failed with error: \(error)")
            }
            
            onComplete(result, needsConfigSync)
        }
        
        // if there aren't any migrations to run then just complete immediately (this way the migrator
        // doesn't try to execute on the DBWrite thread so returning from the background can't get blocked
        // due to some weird endless process running)
        guard !unperformedMigrations.isEmpty else {
            migrationCompleted(.success(()))
            return
        }
        
        // If we have an unperformed migration then trigger the progress updater immediately
        if let firstMigrationKey: String = unperformedMigrations.first?.key {
            self.migrationProgressUpdater?.wrappedValue(firstMigrationKey, 0)
        }
        
        // Note: The non-async migration should only be used for unit tests
        guard async else { return migrationCompleted(Result(catching: { try migrator.migrate(dbWriter) })) }
        
        migrator.asyncMigrate(dbWriter) { result in
            let finalResult: Result<Void, Error> = {
                switch result {
                    case .failure(let error): return .failure(error)
                    case .success: return .success(())
                }
            }()
            
            // Note: We need to dispatch this to the next run toop to prevent any potential re-entrancy
            // issues since the 'asyncMigrate' returns a result containing a DB instance
            DispatchQueue.global(qos: .userInitiated).async {
                migrationCompleted(finalResult)
            }
        }
    }
    
    public func willStartMigration(_ db: Database, _ migration: Migration.Type) {
        guard let largestMigrationRequirement: MigrationRequirement = migration.requirements.max() else { return }
        
        // Get all requirements that are earlier than the largest requirement on the migration and find
        // any that haven't yet been run
        let unprocessedRequirements: [MigrationRequirement] = MigrationRequirement.allCases
            .filter { $0 <= largestMigrationRequirement }
            .asSet()
            .intersection(unprocessedMigrationRequirements.wrappedValue.asSet())
            .sorted()
        
        // No need to do anything if there are no unprocessed requirements
        guard !unprocessedRequirements.isEmpty else { return }
        
        // Process all of the requirements for this migration
        unprocessedRequirements.forEach { migrationRequirementProcesser?.wrappedValue(db, $0) }
        
        // Remove any processed requirements from the list (don't want to process them multiple times)
        unprocessedMigrationRequirements.mutate {
            $0 = Array($0.asSet().subtracting(unprocessedRequirements.asSet()))
        }
    }
    
    public static func update(
        progress: CGFloat,
        for migration: Migration.Type,
        in target: TargetMigrations.Identifier,
        using dependencies: Dependencies
    ) {
        // In test builds ignore any migration progress updates (we run in a custom database writer anyway)
        guard !SNUtilitiesKit.isRunningTests else { return }
        
        dependencies[singleton: .storage].migrationProgressUpdater?
            .wrappedValue(target.key(with: migration), progress)
    }
    
    // MARK: - Security
    
    private func getDatabaseCipherKeySpec() throws -> Data {
        try dependencies[singleton: .keychain].migrateLegacyKeyIfNeeded(
            legacyKey: "GRDBDatabaseCipherKeySpec",
            legacyService: "TSKeyChainService",
            toKey: .dbCipherKeySpec
        )
        return try dependencies[singleton: .keychain].data(forKey: .dbCipherKeySpec)
    }
    
    private func getOrGenerateDatabaseKeySpec() throws -> Data {
        do {
            var keySpec: Data = try getDatabaseCipherKeySpec()
            defer { keySpec.resetBytes(in: 0..<keySpec.count) }
            
            guard keySpec.count == Storage.SQLCipherKeySpecLength else { throw StorageError.invalidKeySpec }
            
            return keySpec
        }
        catch {
            switch (error, (error as? KeychainStorageError)?.code) {
                case (StorageError.invalidKeySpec, _):
                    // For these cases it means either the keySpec or the keychain has become corrupt so in order to
                    // get back to a "known good state" and behave like a new install we need to reset the storage
                    // and regenerate the key
                    if !SNUtilitiesKit.isRunningTests {
                        // Try to reset app by deleting database.
                        resetAllStorage()
                    }
                    fallthrough
                
                case (_, errSecItemNotFound):
                    // No keySpec was found so we need to generate a new one
                    do {
                        var keySpec: Data = try dependencies[singleton: .crypto].tryGenerate(.randomBytes(Storage.SQLCipherKeySpecLength))
                        defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
                        
                        try dependencies[singleton: .keychain].set(data: keySpec, forKey: .dbCipherKeySpec)
                        return keySpec
                    }
                    catch {
                        Log.error(.storage, "Setting keychain value failed with error: \(error)")
                        Thread.sleep(forTimeInterval: 15)    // Sleep to allow any background behaviours to complete
                        throw StorageError.keySpecCreationFailed
                    }
                    
                default:
                    // Because we use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, the keychain will be inaccessible
                    // after device restart until device is unlocked for the first time. If the app receives a push
                    // notification, we won't be able to access the keychain to process that notification, so we should
                    // just terminate by throwing an uncaught exception
                    if dependencies[singleton: .appContext].isMainApp || dependencies[singleton: .appContext].isInBackground {
                        let appState: UIApplication.State = dependencies[singleton: .appContext].reportedApplicationState
                        Log.error(.storage, "CipherKeySpec inaccessible. New install or no unlock since device restart?, ApplicationState: \(appState.name)")
                        
                        // In this case we should have already detected the situation earlier and exited
                        // gracefully (in the app delegate) using isDatabasePasswordAccessible(using:), but we
                        // want to stop the app running here anyway
                        Thread.sleep(forTimeInterval: 5)    // Sleep to allow any background behaviours to complete
                        throw StorageError.keySpecInaccessible
                    }
                    
                    Log.error(.storage, "CipherKeySpec inaccessible; not main app.")
                    Thread.sleep(forTimeInterval: 5)    // Sleep to allow any background behaviours to complete
                    throw StorageError.keySpecInaccessible
            }
        }
    }
    
    // MARK: - File Management
    
    /// In order to avoid the `0xdead10cc` exception we manually track whether database access should be suspended, when
    /// in a suspended state this class will fail/reject all read/write calls made to it. Additionally if there was an existing transaction
    /// in progress it will be interrupted.
    ///
    /// The generally suggested approach is to avoid this entirely by not storing the database in an AppGroup folder and sharing it
    /// with extensions - this may be possible but will require significant refactoring and a potentially painful migration to move the
    /// database and other files into the App folder
    public func suspendDatabaseAccess() {
        guard !isSuspended else { return }
        
        isSuspended = true
        Log.info(.storage, "Database access suspended.")
        
        /// Interrupt any open transactions (if this function is called then we are expecting that all processes have finished running
        /// and don't actually want any more transactions to occur)
        dbWriter?.interrupt()
    }
    
    /// This method reverses the database suspension used to prevent the `0xdead10cc` exception (see `suspendDatabaseAccess()`
    /// above for more information
    public func resumeDatabaseAccess() {
        guard isSuspended else { return }
        
        isSuspended = false
        Log.info(.storage, "Database access resumed.")
    }
    
    public func resetAllStorage() {
        isValid = false
        migrationsCompleted.mutate { $0 = false }
        dbWriter = nil
        
        deleteDatabaseFiles()
        do { try deleteDbKeys() } catch { Log.warn(.storage, "Failed to delete database keys.") }
    }
    
    public func reconfigureDatabase() {
        configureDatabase()
    }
    
    public func resetForCleanMigration() {
        // Clear existing content
        resetAllStorage()
        
        // Reconfigure
        reconfigureDatabase()
    }
    
    private func deleteDatabaseFiles() {
        do { try dependencies[singleton: .fileManager].removeItem(atPath: Storage.databasePath) }
        catch { Log.warn(.storage, "Failed to delete database.") }
        do { try dependencies[singleton: .fileManager].removeItem(atPath: Storage.databasePathShm) }
        catch { Log.warn(.storage, "Failed to delete database-shm.") }
        do { try dependencies[singleton: .fileManager].removeItem(atPath: Storage.databasePathWal) }
        catch { Log.warn(.storage, "Failed to delete database-wal.") }
    }
    
    private func deleteDbKeys() throws {
        try dependencies[singleton: .keychain].remove(key: .dbCipherKeySpec)
    }
    
    // MARK: - Logging Functions
    
    enum StorageState {
        case valid(DatabaseWriter)
        case invalid(Error)
        
        init(_ storage: Storage) {
            switch (storage.isSuspended, storage.isValid, storage.dbWriter) {
                case (true, _, _): self = .invalid(StorageError.databaseSuspended)
                case (false, true, .some(let dbWriter)): self = .valid(dbWriter)
                default: self = .invalid(StorageError.databaseInvalid)
            }
        }
        
        static func logIfNeeded(_ error: Error, isWrite: Bool) {
            switch error {
                case DatabaseError.SQLITE_ABORT, DatabaseError.SQLITE_INTERRUPT:
                    let message: String = ((error as? DatabaseError)?.message ?? "Unknown")
                    Log.error(.storage, "Database \(isWrite ? "write" : "read") failed due to error: \(message)")
                
                case StorageError.databaseSuspended:
                    Log.error(.storage, "Database \(isWrite ? "write" : "read") failed as the database is suspended.")
                    
                default: break
            }
        }
        
        static func logIfNeeded<T>(_ error: Error, isWrite: Bool) -> T? {
            logIfNeeded(error, isWrite: isWrite)
            return nil
        }
        
        static func logIfNeeded<T>(_ error: Error, isWrite: Bool) -> AnyPublisher<T, Error> {
            logIfNeeded(error, isWrite: isWrite)
            return Fail<T, Error>(error: error).eraseToAnyPublisher()
        }
    }
    
    private static func perform<T>(
        info: CallInfo,
        updates: @escaping (Database) throws -> T
    ) -> (Database) throws -> T {
        return { db in
            guard info.storage?.isSuspended == false else { throw StorageError.databaseSuspended }
            
            let timer: TransactionTimer = TransactionTimer.start(duration: Storage.slowTransactionThreshold, info: info)
            defer { timer.stop() }
            
            // Get the result
            let result: T = try updates(db)
            
            // Update the state flags
            switch info.isWrite {
                case true: info.storage?.hasSuccessfullyWritten = true
                case false: info.storage?.hasSuccessfullyRead = true
            }
            
            return result
        }
    }
    
    // MARK: - Functions
    
    @discardableResult public func write<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        updates: @escaping (Database) throws -> T?
    ) -> T? {
        switch StorageState(self) {
            case .invalid(let error): return StorageState.logIfNeeded(error, isWrite: true)
            case .valid(let dbWriter):
                let info: CallInfo = CallInfo(fileName, functionName, lineNumber, true, self)
                do { return try dbWriter.write(Storage.perform(info: info, updates: updates)) }
                catch { return StorageState.logIfNeeded(error, isWrite: true) }
        }
    }
    
    open func writeAsync<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        updates: @escaping (Database) throws -> T,
        completion: @escaping (Database, Swift.Result<T, Error>) throws -> Void = { _, _ in }
    ) {
        switch StorageState(self) {
            case .invalid(let error): return StorageState.logIfNeeded(error, isWrite: true)
            case .valid(let dbWriter):
                let info: CallInfo = CallInfo(fileName, functionName, lineNumber, true, self)
                dbWriter.asyncWrite(
                    Storage.perform(info: info, updates: updates),
                    completion: { db, result in
                        switch result {
                            case .failure(let error): StorageState.logIfNeeded(error, isWrite: true)
                            default: break
                        }
                        
                        try? completion(db, result)
                    }
                )
        }
    }
    
    open func writePublisher<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        updates: @escaping (Database) throws -> T
    ) -> AnyPublisher<T, Error> {
        switch StorageState(self) {
            case .invalid(let error): return StorageState.logIfNeeded(error, isWrite: true)
            case .valid(let dbWriter):
                /// **Note:** GRDB does have a `writePublisher` method but it appears to asynchronously trigger
                /// both the `output` and `complete` closures at the same time which causes a lot of unexpected
                /// behaviours (this behaviour is apparently expected but still causes a number of odd behaviours in our code
                /// for more information see https://github.com/groue/GRDB.swift/issues/1334)
                ///
                /// Instead of this we are just using `Deferred { Future {} }` which is executed on the specified scheduled
                /// which behaves in a much more expected way than the GRDB `writePublisher` does
                let info: CallInfo = CallInfo(fileName, functionName, lineNumber, true, self)
                return Deferred {
                    Future { resolver in
                        do { resolver(Result.success(try dbWriter.write(Storage.perform(info: info, updates: updates)))) }
                        catch {
                            StorageState.logIfNeeded(error, isWrite: true)
                            resolver(Result.failure(error))
                        }
                    }
                }.eraseToAnyPublisher()
        }
    }
    
    @discardableResult public func read<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        _ value: @escaping (Database) throws -> T?
    ) -> T? {
        switch StorageState(self) {
            case .invalid(let error): return StorageState.logIfNeeded(error, isWrite: false)
            case .valid(let dbWriter):
                let info: CallInfo = CallInfo(fileName, functionName, lineNumber, false, self)
                do { return try dbWriter.read(Storage.perform(info: info, updates: value)) }
                catch { return StorageState.logIfNeeded(error, isWrite: false) }
        }
    }
    
    open func readPublisher<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        value: @escaping (Database) throws -> T
    ) -> AnyPublisher<T, Error> {
        switch StorageState(self) {
            case .invalid(let error): return StorageState.logIfNeeded(error, isWrite: false)
            case .valid(let dbWriter):
                /// **Note:** GRDB does have a `readPublisher` method but it appears to asynchronously trigger
                /// both the `output` and `complete` closures at the same time which causes a lot of unexpected
                /// behaviours (this behaviour is apparently expected but still causes a number of odd behaviours in our code
                /// for more information see https://github.com/groue/GRDB.swift/issues/1334)
                ///
                /// Instead of this we are just using `Deferred { Future {} }` which is executed on the specified scheduled
                /// which behaves in a much more expected way than the GRDB `readPublisher` does
                let info: CallInfo = CallInfo(fileName, functionName, lineNumber, false, self)
                return Deferred {
                    Future { resolver in
                        do { resolver(Result.success(try dbWriter.read(Storage.perform(info: info, updates: value)))) }
                        catch {
                            StorageState.logIfNeeded(error, isWrite: false)
                            resolver(Result.failure(error))
                        }
                    }
                }.eraseToAnyPublisher()
        }
    }
    
    /// Rever to the `ValueObservation.start` method for full documentation
    ///
    /// - parameter observation: The observation to start
    /// - parameter scheduler: A Scheduler. By default, fresh values are
    ///   dispatched asynchronously on the main queue.
    /// - parameter onError: A closure that is provided eventual errors that
    ///   happen during observation
    /// - parameter onChange: A closure that is provided fresh values
    /// - returns: a DatabaseCancellable
    public func start<Reducer: ValueReducer>(
        _ observation: ValueObservation<Reducer>,
        scheduling scheduler: ValueObservationScheduler = .async(onQueue: .main),
        onError: @escaping (Error) -> Void,
        onChange: @escaping (Reducer.Value) -> Void
    ) -> DatabaseCancellable {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else {
            onError(StorageError.databaseInvalid)
            return AnyDatabaseCancellable(cancel: {})
        }
        
        return observation.start(
            in: dbWriter,
            scheduling: scheduler,
            onError: onError,
            onChange: onChange
        )
    }
    
    public func addObserver(_ observer: TransactionObserver?) {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else { return }
        guard let observer: TransactionObserver = observer else { return }
        
        // Note: This actually triggers a write to the database so can be blocked by other
        // writes, since it's usually called on the main thread when creating a view controller
        // this can result in the UI hanging - to avoid this we dispatch (and hope there isn't
        // negative impact)
        DispatchQueue.global(qos: .default).async {
            dbWriter.add(transactionObserver: observer)
        }
    }
    
    public func removeObserver(_ observer: TransactionObserver?) {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else { return }
        guard let observer: TransactionObserver = observer else { return }
        
        // Note: This actually triggers a write to the database so can be blocked by other
        // writes, since it's usually called on the main thread when creating a view controller
        // this can result in the UI hanging - to avoid this we dispatch (and hope there isn't
        // negative impact)
        DispatchQueue.global(qos: .default).async {
            dbWriter.remove(transactionObserver: observer)
        }
    }
}

// MARK: - Combine Extensions

public extension ValueObservation {
    func publisher(
        in storage: Storage,
        scheduling scheduler: ValueObservationScheduler
    ) -> AnyPublisher<Reducer.Value, Error> where Reducer: ValueReducer {
        guard storage.isValid, let dbWriter: DatabaseWriter = storage.dbWriter else {
            return Fail(error: StorageError.databaseInvalid).eraseToAnyPublisher()
        }
        
        return self.publisher(in: dbWriter, scheduling: scheduler)
            .eraseToAnyPublisher()
    }
}

public extension Publisher where Failure == Error {
    func flatMapStorageWritePublisher<T>(using dependencies: Dependencies, updates: @escaping (Database, Output) throws -> T) -> AnyPublisher<T, Error> {
        return self.flatMap { output -> AnyPublisher<T, Error> in
            dependencies[singleton: .storage].writePublisher(updates: { db in try updates(db, output) })
        }.eraseToAnyPublisher()
    }
    
    func flatMapStorageReadPublisher<T>(using dependencies: Dependencies, value: @escaping (Database, Output) throws -> T) -> AnyPublisher<T, Error> {
        return self.flatMap { output -> AnyPublisher<T, Error> in
            dependencies[singleton: .storage].readPublisher(value: { db in try value(db, output) })
        }.eraseToAnyPublisher()
    }
}

// MARK: - CallInfo

private extension Storage {
    class CallInfo {
        let file: String
        let function: String
        let line: Int
        let isWrite: Bool
        weak var storage: Storage?
        
        var callInfo: String {
            let fileInfo: String = (file.components(separatedBy: "/").last.map { "\($0):\(line) - " } ?? "")
            
            return "\(fileInfo)\(function)"
        }
        
        init(
            _ file: String,
            _ function: String,
            _ line: Int,
            _ isWrite: Bool,
            _ storage: Storage?
        ) {
            self.file = file
            self.function = function
            self.line = line
            self.isWrite = isWrite
            self.storage = storage
        }
    }
}

// MARK: - TransactionTimer

private extension Storage {
    private static let timerQueue = DispatchQueue(label: "\(Storage.queuePrefix)-.transactionTimer", qos: .background)
    
    class TransactionTimer {
        private let info: Storage.CallInfo
        private let start: CFTimeInterval = CACurrentMediaTime()
        private var timer: DispatchSourceTimer? = DispatchSource.makeTimerSource(queue: Storage.timerQueue)
        private var wasSlowTransaction: Bool = false
        
        private init(info: Storage.CallInfo) {
            self.info = info
        }

        static func start(duration: TimeInterval, info: Storage.CallInfo) -> TransactionTimer {
            let result: TransactionTimer = TransactionTimer(info: info)
            result.timer?.schedule(deadline: .now() + .seconds(Int(duration)), repeating: .infinity) // Infinity to fire once
            result.timer?.setEventHandler { [weak result] in
                result?.timer?.cancel()
                result?.timer = nil
                
                let action: String = (info.isWrite ? "write" : "read")
                Log.warn(.storage, "Slow \(action) taking longer than \(Storage.slowTransactionThreshold, format: ".2", omitZeroDecimal: true)s - [ \(info.callInfo) ]")
                result?.wasSlowTransaction = true
            }
            result.timer?.resume()
            
            return result
        }

        func stop() {
            timer?.cancel()
            timer = nil
            
            guard wasSlowTransaction else { return }
            
            let end: CFTimeInterval = CACurrentMediaTime()
            let action: String = (info.isWrite ? "write" : "read")
            Log.warn(.storage, "Slow \(action) completed after \(end - start, format: ".2", omitZeroDecimal: true)s - [ \(info.callInfo) ]")
        }
    }
}

// MARK: - Debug Convenience

public extension Storage {
    func exportInfo(password: String, using dependencies: Dependencies) throws -> (dbPath: String, keyPath: String) {
        var keySpec: Data = try dependencies[singleton: .storage].getOrGenerateDatabaseKeySpec()
        defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
        
        guard var passwordData: Data = password.data(using: .utf8) else { throw StorageError.generic }
        defer { passwordData.resetBytes(in: 0..<passwordData.count) } // Reset content immediately after use
        
        /// Encrypt the `keySpec` value using a SHA256 of the password provided and a nonce then base64-encode the encrypted
        /// data and save it to a temporary file to share alongside the database
        ///
        /// Decrypt the key via the termincal on macOS by running the command in the project root directory
        /// `swift ./Scropts/DecryptExportedKey.swift {BASE64_CIPHERTEXT} {PASSWORD}`
        ///
        /// Where `BASE64_CIPHERTEXT` is the content of the `key.enc` file and `PASSWORD` is the password provided via the
        /// prompt during export
        let nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()
        let hash: SHA256.Digest = SHA256.hash(data: passwordData)
        let key: SymmetricKey = SymmetricKey(data: Data(hash.makeIterator()))
        let sealedBox: ChaChaPoly.SealedBox = try ChaChaPoly.seal(keySpec, using: key, nonce: nonce, authenticating: Data())
        let keyInfoPath: String = "\(dependencies[singleton: .fileManager].temporaryDirectory)key.enc"
        let encryptedKeyBase64: String = sealedBox.combined.base64EncodedString()
        try encryptedKeyBase64.write(toFile: keyInfoPath, atomically: true, encoding: .utf8)
        
        return (
            Storage.databasePath,
            keyInfoPath
        )
    }
}
