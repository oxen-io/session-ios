// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import CryptoKit
import Combine
import GRDB
import SignalCoreKit

open class Storage {
    public static let queuePrefix: String = "SessionDatabase"
    private static let dbFileName: String = "Session.sqlite"
    private static let keychainService: String = "TSKeyChainService"
    private static let dbCipherKeySpecKey: String = "GRDBDatabaseCipherKeySpec"
    private static let kSQLCipherKeySpecLength: Int = 48
    private static let writeWarningThreadshold: TimeInterval = 3
    
    private static var sharedDatabaseDirectoryPath: String { "\(OWSFileSystem.appSharedDataDirectoryPath())/database" }
    private static var databasePath: String { "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)" }
    private static var databasePathShm: String { "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)-shm" }
    private static var databasePathWal: String { "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)-wal" }
    
    public static var hasCreatedValidInstance: Bool { internalHasCreatedValidInstance.wrappedValue }
    public static var isDatabasePasswordAccessible: Bool {
        guard (try? getDatabaseCipherKeySpec()) != nil else { return false }
        
        return true
    }
    
    private var startupError: Error?
    private let migrationsCompleted: Atomic<Bool> = Atomic(false)
    private static let internalHasCreatedValidInstance: Atomic<Bool> = Atomic(false)
    internal let internalCurrentlyRunningMigration: Atomic<(identifier: TargetMigrations.Identifier, migration: Migration.Type)?> = Atomic(nil)
    
    public static let shared: Storage = Storage()
    public private(set) var isValid: Bool = false
    
    /// This property gets set when triggering the suspend/resume notifications for the database but `GRDB` will attempt to
    /// resume the suspention when it attempts to perform a write so it's possible for this to return a **false-positive** so
    /// this should be taken into consideration when used
    public private(set) var isSuspendedUnsafe: Bool = false
    
    /// This property gets set the first time we successfully read from the database
    public private(set) var hasSuccessfullyRead: Bool = false
    
    /// This property gets set the first time we successfully write to the database
    public private(set) var hasSuccessfullyWritten: Bool = false
    
    public var hasCompletedMigrations: Bool { migrationsCompleted.wrappedValue }
    public var currentlyRunningMigration: (identifier: TargetMigrations.Identifier, migration: Migration.Type)? {
        internalCurrentlyRunningMigration.wrappedValue
    }
    public static let defaultPublisherScheduler: ValueObservationScheduler = .async(onQueue: .main)
    
    fileprivate var dbWriter: DatabaseWriter?
    internal var testDbWriter: DatabaseWriter? { dbWriter }
    private var unprocessedMigrationRequirements: Atomic<[MigrationRequirement]> = Atomic(MigrationRequirement.allCases)
    private var migrationProgressUpdater: Atomic<((String, CGFloat) -> ())>?
    private var migrationRequirementProcesser: Atomic<(Database, MigrationRequirement) -> ()>?
    
    // MARK: - Initialization
    
    public init(customWriter: DatabaseWriter? = nil) {
        configureDatabase(customWriter: customWriter)
    }
    
    private func configureDatabase(customWriter: DatabaseWriter? = nil) {
        // Create the database directory if needed and ensure it's protection level is set before attempting to
        // create the database KeySpec or the database itself
        OWSFileSystem.ensureDirectoryExists(Storage.sharedDatabaseDirectoryPath)
        OWSFileSystem.protectFileOrFolder(atPath: Storage.sharedDatabaseDirectoryPath)
        
        // If a custom writer was provided then use that (for unit testing)
        guard customWriter == nil else {
            dbWriter = customWriter
            isValid = true
            Storage.internalHasCreatedValidInstance.mutate { $0 = true }
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
            var tmpKeySpec: Data = try Storage.getOrGenerateDatabaseKeySpec()
            tmpKeySpec.resetBytes(in: 0..<tmpKeySpec.count)
        }
        catch { return }
        
        // Configure the database and create the DatabasePool for interacting with the database
        var config = Configuration()
        config.label = Storage.queuePrefix
        config.maximumReaderCount = 10  // Increase the max read connection limit - Default is 5
        config.observesSuspensionNotifications = true // Minimise `0xDEAD10CC` exceptions
        config.prepareDatabase { db in
            var keySpec: Data = try Storage.getOrGenerateDatabaseKeySpec()
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
            dbWriter = try DatabasePool(
                path: "\(Storage.sharedDatabaseDirectoryPath)/\(Storage.dbFileName)",
                configuration: config
            )
            isValid = true
            Storage.internalHasCreatedValidInstance.mutate { $0 = true }
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
        onComplete: @escaping (Swift.Result<Void, Error>, Bool) -> (),
        using dependencies: Dependencies
    ) {
        perform(
            sortedMigrations: Storage.sortedMigrationInfo(migrationTargets: migrationTargets),
            async: async,
            onProgressUpdate: onProgressUpdate,
            onMigrationRequirement: onMigrationRequirement,
            onComplete: onComplete,
            using: dependencies
        )
    }
    
    internal func perform(
        sortedMigrations: [KeyedMigration],
        async: Bool,
        onProgressUpdate: ((CGFloat, TimeInterval) -> ())?,
        onMigrationRequirement: @escaping (Database, MigrationRequirement) -> (),
        onComplete: @escaping (Swift.Result<Void, Error>, Bool) -> (),
        using dependencies: Dependencies
    ) {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else {
            let error: Error = (startupError ?? StorageError.startupFailed)
            SNLog("[Database Error] Statup failed with error: \(error)")
            onComplete(.failure(error), false)
            return
        }
        
        // Setup and run any required migrations
        var migrator: DatabaseMigrator = DatabaseMigrator()
        sortedMigrations.forEach { _, identifier, migration in
            migrator.registerMigration(self, targetIdentifier: identifier, migration: migration, using: dependencies)
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
        let migrationCompleted: (Swift.Result<Void, Error>) -> () = { [weak self] result in
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
            if !remainingMigrationRequirements.isEmpty {
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
                case .failure(let error): SNLog("[Migration Error] Migration failed with error: \(error)")
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
        guard async else { return migrationCompleted(Result(try migrator.migrate(dbWriter))) }
        
        migrator.asyncMigrate(dbWriter) { result in
            let finalResult: Swift.Result<Void, Error> = {
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
        let unprocessedRequirements: Set<MigrationRequirement> = migration.requirements.asSet()
            .intersection(unprocessedMigrationRequirements.wrappedValue.asSet())
        
        // No need to do anything if there are no unprocessed requirements
        guard !unprocessedRequirements.isEmpty else { return }
        
        // Process all of the requirements for this migration
        unprocessedRequirements.forEach { migrationRequirementProcesser?.wrappedValue(db, $0) }
        
        // Remove any processed requirements from the list (don't want to process them multiple times)
        unprocessedMigrationRequirements.mutate {
            $0 = Array($0.asSet().subtracting(migration.requirements.asSet()))
        }
    }
    
    public static func update(
        progress: CGFloat,
        for migration: Migration.Type,
        in target: TargetMigrations.Identifier
    ) {
        // In test builds ignore any migration progress updates (we run in a custom database writer anyway)
        guard !SNUtilitiesKit.isRunningTests else { return }
        
        Storage.shared.migrationProgressUpdater?.wrappedValue(target.key(with: migration), progress)
    }
    
    // MARK: - Security
    
    private static func getDatabaseCipherKeySpec() throws -> Data {
        return try SSKDefaultKeychainStorage.shared.data(forService: keychainService, key: dbCipherKeySpecKey)
    }
    
    @discardableResult private static func getOrGenerateDatabaseKeySpec() throws -> Data {
        do {
            var keySpec: Data = try getDatabaseCipherKeySpec()
            defer { keySpec.resetBytes(in: 0..<keySpec.count) }
            
            guard keySpec.count == kSQLCipherKeySpecLength else { throw StorageError.invalidKeySpec }
            
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
                        var keySpec: Data = try Randomness.generateRandomBytes(numberBytes: kSQLCipherKeySpecLength)
                        defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
                        
                        try SSKDefaultKeychainStorage.shared.set(data: keySpec, service: keychainService, key: dbCipherKeySpecKey)
                        return keySpec
                    }
                    catch {
                        SNLog("Setting keychain value failed with error: \(error)")
                        Thread.sleep(forTimeInterval: 15)    // Sleep to allow any background behaviours to complete
                        throw StorageError.keySpecCreationFailed
                    }
                    
                default:
                    // Because we use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, the keychain will be inaccessible
                    // after device restart until device is unlocked for the first time. If the app receives a push
                    // notification, we won't be able to access the keychain to process that notification, so we should
                    // just terminate by throwing an uncaught exception
                    if Singleton.hasAppContext && (Singleton.appContext.isMainApp || Singleton.appContext.isInBackground) {
                        let appState: UIApplication.State = Singleton.appContext.reportedApplicationState
                        SNLog("CipherKeySpec inaccessible. New install or no unlock since device restart?, ApplicationState: \(appState.name)")
                        
                        // In this case we should have already detected the situation earlier and exited
                        // gracefully (in the app delegate) using isDatabasePasswordAccessible, but we
                        // want to stop the app running here anyway
                        Thread.sleep(forTimeInterval: 5)    // Sleep to allow any background behaviours to complete
                        throw StorageError.keySpecInaccessible
                    }
                    
                    SNLog("CipherKeySpec inaccessible; not main app.")
                    Thread.sleep(forTimeInterval: 5)    // Sleep to allow any background behaviours to complete
                    throw StorageError.keySpecInaccessible
            }
        }
    }
    
    // MARK: - File Management
    
    /// In order to avoid the `0xdead10cc` exception when accessing the database while another target is accessing it we call
    /// the experimental `Database.suspendNotification` notification (and store the current suspended state) to prevent
    /// `GRDB` from trying to access the locked database file
    ///
    /// The generally suggested approach is to avoid this entirely by not storing the database in an AppGroup folder and sharing it
    /// with extensions - this may be possible but will require significant refactoring and a potentially painful migration to move the
    /// database and other files into the App folder
    public static func suspendDatabaseAccess(using dependencies: Dependencies = Dependencies()) {
        Log.info("[Storage] suspendDatabaseAccess called.")
        NotificationCenter.default.post(name: Database.suspendNotification, object: self)
        if Storage.hasCreatedValidInstance { dependencies.storage.isSuspendedUnsafe = true }
    }
    
    /// This method reverses the database suspension used to prevent the `0xdead10cc` exception (see `suspendDatabaseAccess()`
    /// above for more information
    public static func resumeDatabaseAccess(using dependencies: Dependencies = Dependencies()) {
        NotificationCenter.default.post(name: Database.resumeNotification, object: self)
        if Storage.hasCreatedValidInstance { dependencies.storage.isSuspendedUnsafe = false }
        Log.info("[Storage] resumeDatabaseAccess called.")
    }
    
    public static func resetAllStorage() {
        Storage.shared.isValid = false
        Storage.internalHasCreatedValidInstance.mutate { $0 = false }
        Storage.shared.migrationsCompleted.mutate { $0 = false }
        Storage.shared.dbWriter = nil
        
        deleteDatabaseFiles()
        do { try deleteDbKeys() } catch { Log.warn("Failed to delete database keys.") }
    }
    
    public static func reconfigureDatabase() {
        Storage.shared.configureDatabase()
    }
    
    public static func resetForCleanMigration() {
        // Clear existing content
        resetAllStorage()
        
        // Reconfigure
        reconfigureDatabase()
    }
    
    private static func deleteDatabaseFiles() {
        if !OWSFileSystem.deleteFile(databasePath) { Log.warn("Failed to delete database.") }
        if !OWSFileSystem.deleteFile(databasePathShm) { Log.warn("Failed to delete database-shm.") }
        if !OWSFileSystem.deleteFile(databasePathWal) { Log.warn("Failed to delete database-wal.") }
    }
    
    private static func deleteDbKeys() throws {
        try SSKDefaultKeychainStorage.shared.remove(service: keychainService, key: dbCipherKeySpecKey)
    }
    
    // MARK: - Logging Functions
    
    private enum Action {
        case read
        case write
        case logIfSlow
    }
    
    private typealias CallInfo = (storage: Storage?, actions: [Action], file: String, function: String, line: Int)
    
    private static func perform<T>(
        info: CallInfo,
        updates: @escaping (Database) throws -> T
    ) -> (Database) throws -> T {
        return { db in
            let start: CFTimeInterval = CACurrentMediaTime()
            let actionName: String = (info.actions.contains(.write) ? "write" : "read")
            let fileName: String = (info.file.components(separatedBy: "/").last.map { " \($0):\(info.line)" } ?? "")
            let timeout: Timer? = {
                guard info.actions.contains(.logIfSlow) else { return nil }
                
                return Timer.scheduledTimerOnMainThread(withTimeInterval: Storage.writeWarningThreadshold) {
                    $0.invalidate()
                    
                    // Don't want to log on the main thread as to avoid confusion when debugging issues
                    DispatchQueue.global(qos: .default).async {
                        SNLog("[Storage\(fileName)] Slow \(actionName) taking longer than \(Storage.writeWarningThreadshold, format: ".2", omitZeroDecimal: true)s - \(info.function)")
                    }
                }
            }()
            
            // If we timed out and are logging slow actions then log the actual duration to help us
            // prioritise performance issues
            defer {
                if timeout != nil && timeout?.isValid == false {
                    let end: CFTimeInterval = CACurrentMediaTime()
                    
                    DispatchQueue.global(qos: .default).async {
                        SNLog("[Storage\(fileName)] Slow \(actionName) completed after \(end - start, format: ".2", omitZeroDecimal: true)s")
                    }
                }
                
                timeout?.invalidate()
            }
            
            // Get the result
            let result: T = try updates(db)
            
            // Update the state flags
            switch info.actions {
                case [.write], [.write, .logIfSlow]: info.storage?.hasSuccessfullyWritten = true
                case [.read], [.read, .logIfSlow]: info.storage?.hasSuccessfullyRead = true
                default: break
            }
            
            return result
        }
    }
    
    private static func logIfNeeded(_ error: Error, isWrite: Bool) {
        switch error {
            case DatabaseError.SQLITE_ABORT:
                let message: String = ((error as? DatabaseError)?.message ?? "Unknown")
                SNLog("[Storage] Database \(isWrite ? "write" : "read") failed due to error: \(message)")
                
            default: break
        }
    }
    
    private static func logIfNeeded<T>(_ error: Error, isWrite: Bool) -> T? {
        logIfNeeded(error, isWrite: isWrite)
        return nil
    }
    
    // MARK: - Functions
    
    @discardableResult public func write<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        using dependencies: Dependencies = Dependencies(),
        updates: @escaping (Database) throws -> T?
    ) -> T? {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else { return nil }
        
        let info: CallInfo = { [weak self] in (self, [.write, .logIfSlow], fileName, functionName, lineNumber) }()
        do { return try dbWriter.write(Storage.perform(info: info, updates: updates)) }
        catch { return Storage.logIfNeeded(error, isWrite: true) }
    }
    
    open func writeAsync<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        using dependencies: Dependencies = Dependencies(),
        updates: @escaping (Database) throws -> T
    ) {
        writeAsync(
            fileName: fileName,
            functionName: functionName,
            lineNumber: lineNumber,
            using: dependencies,
            updates: updates,
            completion: { _, _ in }
        )
    }
    
    open func writeAsync<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        using dependencies: Dependencies = Dependencies(),
        updates: @escaping (Database) throws -> T,
        completion: @escaping (Database, Swift.Result<T, Error>) throws -> Void
    ) {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else { return }
        
        let info: CallInfo = { [weak self] in (self, [.write, .logIfSlow], fileName, functionName, lineNumber) }()
        
        dbWriter.asyncWrite(
            Storage.perform(info: info, updates: updates),
            completion: { db, result in
                switch result {
                    case .failure(let error): Storage.logIfNeeded(error, isWrite: true)
                    default: break
                }
                
                try? completion(db, result)
            }
        )
    }
    
    open func writePublisher<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        using dependencies: Dependencies = Dependencies(),
        updates: @escaping (Database) throws -> T
    ) -> AnyPublisher<T, Error> {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else {
            return Fail<T, Error>(error: StorageError.databaseInvalid)
                .eraseToAnyPublisher()
        }
        
        let info: CallInfo = { [weak self] in (self, [.write, .logIfSlow], fileName, functionName, lineNumber) }()
        
        /// **Note:** GRDB does have a `writePublisher` method but it appears to asynchronously trigger
        /// both the `output` and `complete` closures at the same time which causes a lot of unexpected
        /// behaviours (this behaviour is apparently expected but still causes a number of odd behaviours in our code
        /// for more information see https://github.com/groue/GRDB.swift/issues/1334)
        ///
        /// Instead of this we are just using `Deferred { Future {} }` which is executed on the specified scheduled
        /// which behaves in a much more expected way than the GRDB `writePublisher` does
        return Deferred {
            Future { resolver in
                do { resolver(Result.success(try dbWriter.write(Storage.perform(info: info, updates: updates)))) }
                catch {
                    Storage.logIfNeeded(error, isWrite: true)
                    resolver(Result.failure(error))
                }
            }
        }.eraseToAnyPublisher()
    }
    
    open func readPublisher<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        using dependencies: Dependencies = Dependencies(),
        value: @escaping (Database) throws -> T
    ) -> AnyPublisher<T, Error> {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else {
            return Fail<T, Error>(error: StorageError.databaseInvalid)
                .eraseToAnyPublisher()
        }
        
        let info: CallInfo = { [weak self] in (self, [.read], fileName, functionName, lineNumber) }()
        
        /// **Note:** GRDB does have a `readPublisher` method but it appears to asynchronously trigger
        /// both the `output` and `complete` closures at the same time which causes a lot of unexpected
        /// behaviours (this behaviour is apparently expected but still causes a number of odd behaviours in our code
        /// for more information see https://github.com/groue/GRDB.swift/issues/1334)
        ///
        /// Instead of this we are just using `Deferred { Future {} }` which is executed on the specified scheduled
        /// which behaves in a much more expected way than the GRDB `readPublisher` does
        return Deferred {
            Future { resolver in
                do { resolver(Result.success(try dbWriter.read(Storage.perform(info: info, updates: value)))) }
                catch {
                    Storage.logIfNeeded(error, isWrite: false)
                    resolver(Result.failure(error))
                }
            }
        }.eraseToAnyPublisher()
    }
    
    @discardableResult public func read<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        using dependencies: Dependencies = Dependencies(),
        _ value: @escaping (Database) throws -> T?
    ) -> T? {
        guard isValid, let dbWriter: DatabaseWriter = dbWriter else { return nil }
        
        let info: CallInfo = { [weak self] in (self, [.read], fileName, functionName, lineNumber) }()
        do { return try dbWriter.read(Storage.perform(info: info, updates: value)) }
        catch { return Storage.logIfNeeded(error, isWrite: false) }
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
        scheduling scheduler: ValueObservationScheduler = Storage.defaultPublisherScheduler
    ) -> AnyPublisher<Reducer.Value, Error> where Reducer: ValueReducer {
        guard storage.isValid, let dbWriter: DatabaseWriter = storage.dbWriter else {
            return Fail(error: StorageError.databaseInvalid).eraseToAnyPublisher()
        }
        
        return self.publisher(in: dbWriter, scheduling: scheduler)
            .eraseToAnyPublisher()
    }
}

// MARK: - Debug Convenience

#if DEBUG
public extension Storage {
    func exportInfo(password: String) throws -> (dbPath: String, keyPath: String) {
        var keySpec: Data = try Storage.getOrGenerateDatabaseKeySpec()
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
        let keyInfoPath: String = "\(NSTemporaryDirectory())key.enc"
        let encryptedKeyBase64: String = sealedBox.combined.base64EncodedString()
        try encryptedKeyBase64.write(toFile: keyInfoPath, atomically: true, encoding: .utf8)
        
        return (
            Storage.databasePath,
            keyInfoPath
        )
    }
}
#endif
