// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SignalCoreKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalCoreKit

public enum SyncPushTokensJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    private static let maxFrequency: TimeInterval = (12 * 60 * 60)
    private static let maxRunFrequency: TimeInterval = 1
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies = Dependencies()
    ) {
        // Don't run when inactive or not in main app or if the user doesn't exist yet
        guard (UserDefaults.sharedLokiProject?[.isMainAppActive]).defaulting(to: false) else {
            return deferred(job, dependencies) // Don't need to do anything if it's not the main app
        }
        guard Identity.userCompletedRequiredOnboarding() else {
            SNLog("[SyncPushTokensJob] Deferred due to incomplete registration")
            return deferred(job, dependencies)
        }
        
        /// Since this job can be dependant on network conditions it's possible for multiple jobs to run at the same time, while this shouldn't cause issues
        /// it can result in multiple API calls getting made concurrently so to avoid this we defer the job as if the previous one was successful then the
        ///  `lastPushNotificationSync` value will prevent the subsequent call being made
        guard
            dependencies.jobRunner
                .jobInfoFor(state: .running, variant: .syncPushTokens)
                .filter({ key, info in key != job.id })     // Exclude this job
                .isEmpty
        else {
            // Defer the job to run 'maxRunFrequency' from when this one ran (if we don't it'll try start
            // it again immediately which is pointless)
            let updatedJob: Job? = dependencies.storage.write { db in
                try job
                    .with(nextRunTimestamp: dependencies.dateNow.timeIntervalSince1970 + maxRunFrequency)
                    .upserted(db)
            }
            
            SNLog("[SyncPushTokensJob] Deferred due to in progress job")
            return deferred(updatedJob ?? job, dependencies)
        }
        
        // Determine if the device has 'Fast Mode' (APNS) enabled
        let isUsingFullAPNs: Bool = UserDefaults.standard[.isUsingFullAPNs]
        
        // If the job is running and 'Fast Mode' is disabled then we should try to unregister the existing
        // token
        guard isUsingFullAPNs else {
            Just(dependencies.storage[.lastRecordedPushToken])
                .setFailureType(to: Error.self)
                .flatMap { lastRecordedPushToken -> AnyPublisher<Void, Error> in
                    // Tell the device to unregister for remote notifications (essentially try to invalidate
                    // the token if needed - we do this first to avoid wrid race conditions which could be
                    // triggered by the user immediately re-registering)
                    DispatchQueue.main.sync { UIApplication.shared.unregisterForRemoteNotifications() }
                    
                    // Clear the old token
                    dependencies.storage.write(using: dependencies) { db in
                        db[.lastRecordedPushToken] = nil
                    }
                    
                    // Unregister from our server
                    if let existingToken: String = lastRecordedPushToken {
                        SNLog("[SyncPushTokensJob] Unregister using last recorded push token: \(redact(existingToken))")
                        return PushNotificationAPI.unsubscribe(token: Data(hex: existingToken))
                            .map { _ in () }
                            .eraseToAnyPublisher()
                    }
                    
                    SNLog("[SyncPushTokensJob] No previous token stored just triggering device unregister")
                    return Just(())
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                .subscribe(on: queue, using: dependencies)
                .sinkUntilComplete(
                    receiveCompletion: { result in
                        switch result {
                            case .finished: SNLog("[SyncPushTokensJob] Unregister Completed")
                            case .failure: SNLog("[SyncPushTokensJob] Unregister Failed")
                        }
                        
                        // We want to complete this job regardless of success or failure
                        success(job, false, dependencies)
                    }
                )
            return
        }
        
        /// Perform device registration
        ///
        /// **Note:** Apple's documentation states that we should re-register for notifications on every launch:
        /// https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/HandlingRemoteNotifications.html#//apple_ref/doc/uid/TP40008194-CH6-SW1
        SNLog("[SyncPushTokensJob] Re-registering for remote notifications")
        PushRegistrationManager.shared.requestPushTokens()
            .flatMap { (pushToken: String, voipToken: String) -> AnyPublisher<(String, String)?, Error> in
                Deferred {
                    Future<(String, String)?, Error> { resolver in
                        _ = LibSession.onPathsChanged(skipInitialCallbackIfEmpty: true) { paths, pathsChangedId in
                            // Only listen for the first callback
                            LibSession.removePathsChangedCallback(callbackId: pathsChangedId)
                            
                            guard !paths.isEmpty else {
                                SNLog("[SyncPushTokensJob] OS subscription completed, skipping server subscription due to lack of paths")
                                return resolver(Result.success(nil))
                            }
                            
                            resolver(Result.success((pushToken, voipToken)))
                        }
                    }
                }.eraseToAnyPublisher()
            }
            .flatMap { (tokenInfo: (String, String)?) -> AnyPublisher<Void, Error> in
                guard let (pushToken, voipToken): (String, String) = tokenInfo else {
                    return Just(())
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                /// For our `subscribe` endpoint we only want to call it if:
                /// • It's been longer than `SyncPushTokensJob.maxFrequency` since the last subscription;
                /// • The token has changed; or
                /// • We want to force an update
                let timeSinceLastSubscription: TimeInterval = dependencies.dateNow
                    .timeIntervalSince(
                        dependencies.standardUserDefaults[.lastPushNotificationSync]
                            .defaulting(to: Date.distantPast)
                    )
                let uploadOnlyIfStale: Bool? = {
                    guard
                        let detailsData: Data = job.details,
                        let details: Details = try? JSONDecoder().decode(Details.self, from: detailsData)
                    else { return nil }
                    
                    return details.uploadOnlyIfStale
                }()
                
                guard
                    timeSinceLastSubscription >= SyncPushTokensJob.maxFrequency ||
                    dependencies.storage[.lastRecordedPushToken] != pushToken ||
                    uploadOnlyIfStale == false
                else {
                    SNLog("[SyncPushTokensJob] OS subscription completed, skipping server subscription due to frequency")
                    return Just(())
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                return PushNotificationAPI
                    .subscribe(
                        token: Data(hex: pushToken),
                        isForcedUpdate: true,
                        using: dependencies
                    )
                    .retry(3, using: dependencies)
                    .handleEvents(
                        receiveCompletion: { result in
                            switch result {
                                case .failure(let error):
                                    SNLog("[SyncPushTokensJob] Failed to register due to error: \(error)")
                                
                                case .finished:
                                    Logger.warn("Recording push tokens locally. pushToken: \(redact(pushToken)), voipToken: \(redact(voipToken))")
                                    SNLog("[SyncPushTokensJob] Completed")
                                    dependencies.standardUserDefaults[.lastPushNotificationSync] = dependencies.dateNow

                                    dependencies.storage.write(using: dependencies) { db in
                                        db[.lastRecordedPushToken] = pushToken
                                        db[.lastRecordedVoipToken] = voipToken
                                    }
                            }
                        }
                    )
                    .map { _ in () }
                    .eraseToAnyPublisher()
            }
            .subscribe(on: queue, using: dependencies)
            .sinkUntilComplete(
                // We want to complete this job regardless of success or failure
                receiveCompletion: { _ in success(job, false, dependencies) }
            )
    }
    
    public static func run(uploadOnlyIfStale: Bool) {
        guard let job: Job = Job(
            variant: .syncPushTokens,
            behaviour: .runOnce,
            details: SyncPushTokensJob.Details(
                uploadOnlyIfStale: uploadOnlyIfStale
            )
        )
        else { return }
                                 
        SyncPushTokensJob.run(
            job,
            queue: DispatchQueue.global(qos: .default),
            success: { _, _, _ in },
            failure: { _, _, _, _ in },
            deferred: { _, _ in }
        )
    }
}

// MARK: - SyncPushTokensJob.Details

extension SyncPushTokensJob {
    public struct Details: Codable {
        public let uploadOnlyIfStale: Bool
    }
}

// MARK: - Convenience

private func redact(_ string: String) -> String {
#if DEBUG
    return "[ DEBUG_NOT_REDACTED \(string) ]" // stringlint:disable
#else
    return "[ READACTED \(string.prefix(2))...\(string.suffix(2)) ]" // stringlint:disable
#endif
}
