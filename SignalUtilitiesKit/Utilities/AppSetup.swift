// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit

public enum AppSetup {
    private static let _hasRun: Atomic<Bool> = Atomic(false)
    public static var hasRun: Bool { _hasRun.wrappedValue }
    
    public static func setupEnvironment(
        additionalMigrationTargets: [MigratableTarget.Type] = [],
        retrySetupIfDatabaseInvalid: Bool = false,
        appSpecificBlock: (() -> ())? = nil,
        migrationProgressChanged: ((CGFloat, TimeInterval) -> ())? = nil,
        migrationsCompletion: @escaping (Result<Void, Error>, Bool) -> (),
        using dependencies: Dependencies
    ) {
        // If we've already run the app setup then only continue under certain circumstances
        guard !AppSetup._hasRun.wrappedValue else {
            let storageIsValid: Bool = dependencies[singleton: .storage].isValid
            
            switch (retrySetupIfDatabaseInvalid, storageIsValid) {
                case (true, false):
                    dependencies[singleton: .storage].reconfigureDatabase()
                    AppSetup._hasRun.mutate { $0 = false }
                    AppSetup.setupEnvironment(
                        retrySetupIfDatabaseInvalid: false, // Don't want to get stuck in a loop
                        appSpecificBlock: appSpecificBlock,
                        migrationProgressChanged: migrationProgressChanged,
                        migrationsCompletion: migrationsCompletion,
                        using: dependencies
                    )
                    
                default:
                    migrationsCompletion(
                        (storageIsValid ? .success(()) : .failure(StorageError.startupFailed)),
                        false
                    )
            }
            return
        }
        
        AppSetup._hasRun.mutate { $0 = true }
        
        var backgroundTask: SessionBackgroundTask? = SessionBackgroundTask(label: #function, using: dependencies)
        
        DispatchQueue.global(qos: .userInitiated).async {
            // Order matters here.
            //
            // All of these "singletons" should have any dependencies used in their
            // initializers injected.
            dependencies[singleton: .backgroundTaskManager].startObservingNotifications()
            
            // Attachments can be stored to NSTemporaryDirectory()
            // If you receive a media message while the device is locked, the download will fail if
            // the temporary directory is NSFileProtectionComplete
            try? FileSystem.protectFileOrFolder(
                at: NSTemporaryDirectory(),
                fileProtectionType: .completeUntilFirstUserAuthentication,
                using: dependencies
            )

            SessionEnvironment.shared = SessionEnvironment(
                audioSession: OWSAudioSession(),
                proximityMonitoringManager: OWSProximityMonitoringManagerImpl(using: dependencies),
                windowManager: OWSWindowManager(default: ())
            )
            appSpecificBlock?()            
            
            runPostSetupMigrations(
                backgroundTask: backgroundTask,
                additionalMigrationTargets: additionalMigrationTargets,
                migrationProgressChanged: migrationProgressChanged,
                migrationsCompletion: migrationsCompletion,
                using: dependencies
            )
            
            // The 'if' is only there to prevent the "variable never read" warning from showing
            if backgroundTask != nil { backgroundTask = nil }
        }
    }
    
    public static func runPostSetupMigrations(
        backgroundTask: SessionBackgroundTask? = nil,
        additionalMigrationTargets: [MigratableTarget.Type] = [],
        migrationProgressChanged: ((CGFloat, TimeInterval) -> ())? = nil,
        migrationsCompletion: @escaping (Result<Void, Error>, Bool) -> (),
        using dependencies: Dependencies
    ) {
        var backgroundTask: SessionBackgroundTask? = (backgroundTask ?? SessionBackgroundTask(label: #function, using: dependencies))
        
        dependencies[singleton: .storage].perform(
            migrationTargets: additionalMigrationTargets
                .appending(contentsOf: [
                    SNUtilitiesKit.self,
                    SNSnodeKit.self,
                    SNMessagingKit.self
                ]),
            onProgressUpdate: migrationProgressChanged,
            onMigrationRequirement: { db, requirement in
                switch requirement {
                    case .sessionIdCached:
                        guard let userKeyPair: KeyPair = Identity.fetchUserKeyPair(db) else { return }
                        
                        // Cache the users session id so we don't need to fetch it from the database every time
                        dependencies.mutate(cache: .general) {
                            $0.setCachedSessionId(sessionId: SessionId(.standard, publicKey: userKeyPair.publicKey))
                        }
                        
                    case .libSessionStateLoaded:
                        guard Identity.userExists(db, using: dependencies) else { return }
                        
                        // After the migrations have run but before the migration completion we load the
                        // SessionUtil state
                        let cache: LibSession.Cache = LibSession.Cache(
                            userSessionId: dependencies[cache: .general].sessionId,
                            using: dependencies
                        )
                        cache.loadState(db)
                        dependencies.set(cache: .libSession, to: cache)
                }
            },
            onComplete: { result, needsConfigSync in
                // The 'needsConfigSync' flag should be based on whether either a migration or the
                // configs need to be sync'ed
                migrationsCompletion(result, (needsConfigSync || dependencies.mutate(cache: .libSession) { $0.needsSync }))
                
                // The 'if' is only there to prevent the "variable never read" warning from showing
                if backgroundTask != nil { backgroundTask = nil }
            }
        )
    }
}
