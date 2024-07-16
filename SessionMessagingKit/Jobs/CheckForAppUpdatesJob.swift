// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionSnodeKit
import SessionUtilitiesKit

public enum CheckForAppUpdatesJob: JobExecutor {
    private static let updateCheckFrequency: TimeInterval = (4 * 60 * 60)  // Max every 4 hours
    public static var maxFailureCount: Int = -1
    public static var requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        dependencies[singleton: .storage]
            .readPublisher { db -> [UInt8]? in Identity.fetchUserEd25519KeyPair(db)?.secretKey }
            .subscribe(on: queue)
            .receive(on: queue)
            .tryFlatMap { maybeEd25519SecretKey -> AnyPublisher<(ResponseInfoType, AppVersionResponse), Error> in
                guard let ed25519SecretKey: [UInt8] = maybeEd25519SecretKey else { throw StorageError.objectNotFound }
                
                return dependencies[singleton: .network]
                    .checkClientVersion(ed25519SecretKey: ed25519SecretKey)
            }
            .sinkUntilComplete(
                receiveCompletion: { _ in
                    var updatedJob: Job = job.with(
                        failureCount: 0,
                        nextRunTimestamp: (dependencies.dateNow.timeIntervalSince1970 + updateCheckFrequency)
                    )
                    
                    dependencies[singleton: .storage].write { db in
                        try updatedJob.save(db)
                    }
                    
                    success(updatedJob, false)
                },
                receiveValue: { _, versionInfo in
                    switch versionInfo.prerelease {
                        case .none: Log.info("[CheckForAppUpdatesJob] Latest version: \(versionInfo.version)")
                        case .some(let prerelease):
                            Log.info("[CheckForAppUpdatesJob] Latest version: \(versionInfo.version), pre-release version: \(prerelease.version)")
                    }
                }
            )
    }
}
