// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public enum UpdateProfilePictureJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        // Don't run when inactive or not in main app
        guard dependencies[defaults: .appGroup, key: .isMainAppActive] else {
            return deferred(job) // Don't need to do anything if it's not the main app
        }
        
        // Only re-upload the profile picture if enough time has passed since the last upload
        guard
            let lastProfilePictureUpload: Date = dependencies[defaults: .standard, key: .lastProfilePictureUpload],
            dependencies.dateNow.timeIntervalSince(lastProfilePictureUpload) > (14 * 24 * 60 * 60)
        else {
            // Reset the `nextRunTimestamp` value just in case the last run failed so we don't get stuck
            // in a loop endlessly deferring the job
            if let jobId: Int64 = job.id {
                dependencies[singleton: .storage].write { db in
                    try Job
                        .filter(id: jobId)
                        .updateAll(db, Job.Columns.nextRunTimestamp.set(to: 0))
                }
            }

            Log.info("[UpdateProfilePictureJob] Deferred as not enough time has passed since the last update")
            return deferred(job)
        }
        
        // Note: The user defaults flag is updated in DisplayPictureManager
        let profile: Profile = Profile.fetchOrCreateCurrentUser(using: dependencies)
        let displayPictureData: Data? = profile.profilePictureFileName
            .map { DisplayPictureManager.loadDisplayPictureFromDisk(for: $0, using: dependencies) }
        
        Profile.updateLocal(
            queue: queue,
            profileName: profile.name,
            displayPictureUpdate: (displayPictureData.map { .uploadImageData($0) } ?? .none),
            success: { db in
                // Need to call the 'success' closure asynchronously on the queue to prevent a reentrancy
                // issue as it will write to the database and this closure is already called within
                // another database write
                queue.async {
                    Log.info("[UpdateProfilePictureJob] Profile successfully updated")
                    success(job, false)
                }
            },
            failure: { error in failure(job, error, false) },
            using: dependencies
        )
    }
}
