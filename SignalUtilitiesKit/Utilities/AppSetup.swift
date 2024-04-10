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
        appSpecificBlock: @escaping () -> (),
        migrationProgressChanged: ((CGFloat, TimeInterval) -> ())? = nil,
        migrationsCompletion: @escaping (Result<Void, Error>, Bool) -> ()
    ) {
        // If we've already run the app setup then only continue under certain circumstances
        guard !AppSetup.hasRun.wrappedValue else {
            let storageIsValid: Bool = Storage.shared.isValid
            
            switch (retrySetupIfDatabaseInvalid, storageIsValid) {
                case (true, false):
                    Storage.reconfigureDatabase()
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
        
        var backgroundTask: OWSBackgroundTask? = OWSBackgroundTask(labelStr: #function)
        
        DispatchQueue.global(qos: .userInitiated).async {
            // Order matters here.
            //
            // All of these "singletons" should have any dependencies used in their
            // initializers injected.
            OWSBackgroundTaskManager.shared().observeNotifications()
            
            // Attachments can be stored to NSTemporaryDirectory()
            // If you receive a media message while the device is locked, the download will fail if
            // the temporary directory is NSFileProtectionComplete
            let success: Bool = OWSFileSystem.protectFileOrFolder(
                atPath: NSTemporaryDirectory(),
                fileProtectionType: .completeUntilFirstUserAuthentication
            )
            assert(success)

            SessionEnvironment.shared = SessionEnvironment(
                reachabilityManager: SSKReachabilityManagerImpl(),
                audioSession: OWSAudioSession(),
                proximityMonitoringManager: OWSProximityMonitoringManagerImpl(),
                windowManager: OWSWindowManager(default: ())
            )
            appSpecificBlock()
            
            /// `performMainSetup` **MUST** run before `perform(migrations:)`
            Configuration.performMainSetup()
            
            runPostSetupMigrations(
                backgroundTask: backgroundTask,
                migrationProgressChanged: migrationProgressChanged,
                migrationsCompletion: migrationsCompletion
            )
            
            // The 'if' is only there to prevent the "variable never read" warning from showing
            if backgroundTask != nil { backgroundTask = nil }
        }
    }
    
    public static func runPostSetupMigrations(
        backgroundTask: OWSBackgroundTask? = nil,
        migrationProgressChanged: ((CGFloat, TimeInterval) -> ())? = nil,
        migrationsCompletion: @escaping (Result<Void, Error>, Bool) -> ()
    ) {
        var backgroundTask: OWSBackgroundTask? = (backgroundTask ?? OWSBackgroundTask(labelStr: #function))
        
        Storage.shared.perform(
            migrationTargets: [
                SNUtilitiesKit.self,
                SNSnodeKit.self,
                SNMessagingKit.self,
                SNUIKit.self
            ],
            onProgressUpdate: migrationProgressChanged,
            onMigrationRequirement: { db, requirement in
                switch requirement {
                    case .sessionUtilStateLoaded:
                        guard Identity.userExists(db) else { return }
                        
                        // After the migrations have run but before the migration completion we load the
                        // SessionUtil state
                        SessionUtil.loadState(
                            db,
                            userPublicKey: getUserHexEncodedPublicKey(db),
                            ed25519SecretKey: Identity.fetchUserEd25519KeyPair(db)?.secretKey
                        )
                }
            },
            onComplete: { result, needsConfigSync in
                // The 'needsConfigSync' flag should be based on whether either a migration or the
                // configs need to be sync'ed
                migrationsCompletion(result, (needsConfigSync || SessionUtil.needsSync))
                
                // The 'if' is only there to prevent the "variable never read" warning from showing
                if backgroundTask != nil { backgroundTask = nil }
            }
        )
    }
}
