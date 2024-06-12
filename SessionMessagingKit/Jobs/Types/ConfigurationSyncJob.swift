// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

public enum ConfigurationSyncJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = true
    public static let requiresInteractionId: Bool = false
    private static let maxRunFrequency: TimeInterval = 3
    private static let waitTimeForExpirationUpdate: TimeInterval = 1
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies
    ) {
        guard Identity.userCompletedRequiredOnboarding() else { return success(job, true, dependencies) }
        
        // It's possible for multiple ConfigSyncJob's with the same target (user/group) to try to run at the
        // same time since as soon as one is started we will enqueue a second one, rather than adding dependencies
        // between the jobs we just continue to defer the subsequent job while the first one is running in
        // order to prevent multiple configurationSync jobs with the same target from running at the same time
        guard
            dependencies
                .jobRunner
                .jobInfoFor(state: .running, variant: .configurationSync)
                .filter({ key, info in
                    key != job.id &&                // Exclude this job
                    info.threadId == job.threadId   // Exclude jobs for different config stores
                })
                .isEmpty
        else {
            // Defer the job to run 'maxRunFrequency' from when this one ran (if we don't it'll try start
            // it again immediately which is pointless)
            let updatedJob: Job? = dependencies.storage.write { db in
                try job
                    .with(nextRunTimestamp: dependencies.dateNow.timeIntervalSince1970 + maxRunFrequency)
                    .saved(db)
            }
            
            SNLog("[ConfigurationSyncJob] For \(job.threadId ?? "UnknownId") deferred due to in progress job")
            return deferred(updatedJob ?? job, dependencies)
        }
        
        // If we don't have a userKeyPair yet then there is no need to sync the configuration
        // as the user doesn't exist yet (this will get triggered on the first launch of a
        // fresh install due to the migrations getting run)
        guard
            let publicKey: String = job.threadId,
            let pendingChanges: LibSession.PendingChanges = dependencies.storage
                .read(using: dependencies, { db in try LibSession.pendingChanges(db, publicKey: publicKey) })
        else {
            SNLog("[ConfigurationSyncJob] For \(job.threadId ?? "UnknownId") failed due to invalid data")
            return failure(job, StorageError.generic, false, dependencies)
        }
        
        // If there are no pending changes then the job can just complete (next time something
        // is updated we want to try and run immediately so don't scuedule another run in this case)
        guard !pendingChanges.pushData.isEmpty || !pendingChanges.obsoleteHashes.isEmpty else {
            SNLog("[ConfigurationSyncJob] For \(publicKey) completed with no pending changes")
            return success(job, true, dependencies)
        }
        
        let jobStartTimestamp: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        let messageSendTimestamp: Int64 = SnodeAPI.currentOffsetTimestampMs()
        SNLog("[ConfigurationSyncJob] For \(publicKey) started with \(pendingChanges.pushData.count) change\( pendingChanges.pushData.count == 1 ? "" : "s"), \(pendingChanges.obsoleteHashes.count) old hash\(pendingChanges.obsoleteHashes.count == 1 ? "" : "es")")
        
        dependencies.storage
            .readPublisher { db in
                try SnodeAPI.preparedSequence(
                    requests: try pendingChanges.pushData
                        .map { pushData -> ErasedPreparedRequest in
                            try SnodeAPI.preparedSendMessage(
                                db,
                                message: SnodeMessage(
                                    recipient: publicKey,
                                    data: pushData.data.base64EncodedString(),
                                    ttl: pushData.variant.ttl,
                                    timestampMs: UInt64(messageSendTimestamp)
                                ),
                                in: pushData.variant.namespace,
                                using: dependencies
                            )
                        }
                        .appending(try {
                            guard !pendingChanges.obsoleteHashes.isEmpty else { return nil }
                            
                            return try SnodeAPI.preparedDeleteMessages(
                                db,
                                swarmPublicKey: publicKey,
                                serverHashes: Array(pendingChanges.obsoleteHashes),
                                requireSuccessfulDeletion: false,
                                using: dependencies
                            )
                        }()),
                    requireAllBatchResponses: false,
                    swarmPublicKey: publicKey,
                    using: dependencies
                )
            }
            .flatMap { $0.send(using: dependencies) }
            .subscribe(on: queue)
            .receive(on: queue)
            .map { (_: ResponseInfoType, response: Network.BatchResponse) -> [ConfigDump] in
                /// The number of responses returned might not match the number of changes sent but they will be returned
                /// in the same order, this means we can just `zip` the two arrays as it will take the smaller of the two and
                /// correctly align the response to the change
                zip(response, pendingChanges.pushData)
                    .compactMap { (subResponse: Any, pushData: LibSession.PendingChanges.PushData) in
                        /// If the request wasn't successful then just ignore it (the next time we sync this config we will try
                        /// to send the changes again)
                        guard
                            let typedResponse: Network.BatchSubResponse<SendMessagesResponse> = (subResponse as? Network.BatchSubResponse<SendMessagesResponse>),
                            200...299 ~= typedResponse.code,
                            !typedResponse.failedToParseBody,
                            let sendMessageResponse: SendMessagesResponse = typedResponse.body
                        else { return nil }
                        
                        /// Since this change was successful we need to mark it as pushed and generate any config dumps
                        /// which need to be stored
                        return LibSession.markingAsPushed(
                            seqNo: pushData.seqNo,
                            serverHash: sendMessageResponse.hash,
                            sentTimestamp: messageSendTimestamp,
                            variant: pushData.variant,
                            publicKey: publicKey
                        )
                    }
            }
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: SNLog("[ConfigurationSyncJob] For \(publicKey) completed")
                        case .failure(let error):
                            SNLog("[ConfigurationSyncJob] For \(publicKey) failed due to error: \(error)")
                            failure(job, error, false, dependencies)
                    }
                },
                receiveValue: { (configDumps: [ConfigDump]) in
                    // Flag to indicate whether the job should be finished or will run again
                    var shouldFinishCurrentJob: Bool = false
                    
                    // Lastly we need to save the updated dumps to the database
                    let updatedJob: Job? = dependencies.storage.write { db in
                        // Save the updated dumps to the database
                        try configDumps.forEach { try $0.save(db) }
                        
                        // When we complete the 'ConfigurationSync' job we want to immediately schedule
                        // another one with a 'nextRunTimestamp' set to the 'maxRunFrequency' value to
                        // throttle the config sync requests
                        let nextRunTimestamp: TimeInterval = (jobStartTimestamp + maxRunFrequency)
                        
                        // If another 'ConfigurationSync' job was scheduled then update that one
                        // to run at 'nextRunTimestamp' and make the current job stop
                        if
                            let existingJob: Job = try? Job
                                .filter(Job.Columns.id != job.id)
                                .filter(Job.Columns.variant == Job.Variant.configurationSync)
                                .filter(Job.Columns.threadId == publicKey)
                                .order(Job.Columns.nextRunTimestamp.asc)
                                .fetchOne(db)
                        {
                            // If the next job isn't currently running then delay it's start time
                            // until the 'nextRunTimestamp'
                            if !dependencies.jobRunner.isCurrentlyRunning(existingJob) {
                                _ = try existingJob
                                    .with(nextRunTimestamp: nextRunTimestamp)
                                    .saved(db)
                            }
                            
                            // If there is another job then we should finish this one
                            shouldFinishCurrentJob = true
                            return job
                        }
                        
                        return try job
                            .with(nextRunTimestamp: nextRunTimestamp)
                            .saved(db)
                    }
                    
                    success((updatedJob ?? job), shouldFinishCurrentJob, dependencies)
                }
            )
    }
}

// MARK: - Convenience

public extension ConfigurationSyncJob {
    static func enqueue(
        _ db: Database,
        publicKey: String,
        dependencies: Dependencies = Dependencies()
    ) {
        // Upsert a config sync job if needed
        dependencies.jobRunner.upsert(
            db,
            job: ConfigurationSyncJob.createIfNeeded(db, publicKey: publicKey, using: dependencies),
            canStartJob: true,
            using: dependencies
        )
    }
    
    @discardableResult static func createIfNeeded(
        _ db: Database,
        publicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) -> Job? {
        /// The ConfigurationSyncJob will automatically reschedule itself to run again after 3 seconds so if there is an existing
        /// job then there is no need to create another instance
        ///
        /// **Note:** Jobs with different `threadId` values can run concurrently
        guard
            dependencies.jobRunner
                .jobInfoFor(state: .running, variant: .configurationSync)
                .filter({ _, info in info.threadId == publicKey })
                .isEmpty,
            (try? Job
                .filter(Job.Columns.variant == Job.Variant.configurationSync)
                .filter(Job.Columns.threadId == publicKey)
                .isEmpty(db))
                .defaulting(to: false)
        else { return nil }
        
        // Otherwise create a new job
        return Job(
            variant: .configurationSync,
            behaviour: .recurring,
            threadId: publicKey
        )
    }
    
    static func run(using dependencies: Dependencies = Dependencies()) -> AnyPublisher<Void, Error> {
        // Trigger the job emitting the result when completed
        return Deferred {
            Future { resolver in
                ConfigurationSyncJob.run(
                    Job(variant: .configurationSync),
                    queue: .global(qos: .userInitiated),
                    success: { _, _, _ in resolver(Result.success(())) },
                    failure: { _, error, _, _ in resolver(Result.failure(error ?? NetworkError.unknown)) },
                    deferred: { _, _ in },
                    using: dependencies
                )
            }
        }
        .eraseToAnyPublisher()
    }
}
