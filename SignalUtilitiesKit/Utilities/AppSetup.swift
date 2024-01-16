// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionMessagingKit
import SessionUtilitiesKit
import SessionUIKit
import SessionSnodeKit

public enum AppSetup {
    private static let hasRun: Atomic<Bool> = Atomic(false)
    
    public static func setupEnvironment(
        retrySetupIfDatabaseInvalid: Bool = false,
        appSpecificBlock: (() -> ())? = nil,
        migrationProgressChanged: ((CGFloat, TimeInterval) -> ())? = nil,
        migrationsCompletion: @escaping (Result<Void, Error>, Bool) -> (),
        using dependencies: Dependencies = Dependencies()
    ) {
        // If we've already run the app setup then only continue under certain circumstances
        guard !AppSetup.hasRun.wrappedValue else {
            let storageIsValid: Bool = dependencies[singleton: .storage].isValid
            
            switch (retrySetupIfDatabaseInvalid, storageIsValid) {
                case (true, false):
                    Storage.reconfigureDatabase(using: dependencies)
                    AppSetup.hasRun.mutate { $0 = false }
                    AppSetup.setupEnvironment(
                        retrySetupIfDatabaseInvalid: false, // Don't want to get stuck in a loop
                        appSpecificBlock: appSpecificBlock,
                        migrationProgressChanged: migrationProgressChanged,
                        migrationsCompletion: migrationsCompletion
                    )
                    
                default:
                    migrationsCompletion(
                        (storageIsValid ? .success(()) : .failure(StorageError.startupFailed)),
                        false
                    )
            }
            return
        }
        
        AppSetup.hasRun.mutate { $0 = true }
        
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

            Environment.shared = Environment(
                reachabilityManager: SSKReachabilityManagerImpl(),
                audioSession: OWSAudioSession(),
                proximityMonitoringManager: OWSProximityMonitoringManagerImpl(using: dependencies),
                windowManager: OWSWindowManager(default: ())
            )
            appSpecificBlock?()
            
            /// `performMainSetup` **MUST** run before `perform(migrations:)`
            Configuration.performMainSetup(using: dependencies)
            
            runPostSetupMigrations(
                backgroundTask: backgroundTask,
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
        migrationProgressChanged: ((CGFloat, TimeInterval) -> ())? = nil,
        migrationsCompletion: @escaping (Result<Void, Error>, Bool) -> (),
        using dependencies: Dependencies
    ) {
        var backgroundTask: SessionBackgroundTask? = (backgroundTask ?? SessionBackgroundTask(label: #function, using: dependencies))
        
        dependencies[singleton: .storage].perform(
            migrationTargets: [
                SNUtilitiesKit.self,
                SNSnodeKit.self,
                SNMessagingKit.self,
                SNUIKit.self
            ],
            onProgressUpdate: migrationProgressChanged,
            onMigrationRequirement: { db, requirement in
                switch requirement {
                    case .libSessionStateLoaded:
                        guard Identity.userExists(db, using: dependencies) else { return }
                        
                        // After the migrations have run but before the migration completion we load the
                        // SessionUtil state
                        LibSession.loadState(db, using: dependencies)
                }
            },
            onComplete: { result, needsConfigSync in
                // The 'needsConfigSync' flag should be based on whether either a migration or the
                // configs need to be sync'ed
                migrationsCompletion(result, (needsConfigSync || dependencies[cache: .libSession].needsSync))
                
                // The 'if' is only there to prevent the "variable never read" warning from showing
                if backgroundTask != nil { backgroundTask = nil }
            },
            using: dependencies
        )
    }
}
