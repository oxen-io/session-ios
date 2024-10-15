// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("ConfigurationSyncJob", defaultLevel: .info)
}

// MARK: - ConfigurationSyncJob

public enum ConfigurationSyncJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = true
    public static let requiresInteractionId: Bool = false
    private static let maxRunFrequency: TimeInterval = 3
    private static let waitTimeForExpirationUpdate: TimeInterval = 1
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        guard !dependencies[cache: .libSession].isEmpty else {
            return success(job, true)
        }
        
        // It's possible for multiple ConfigSyncJob's with the same target (user/group) to try to run at the
        // same time since as soon as one is started we will enqueue a second one, rather than adding dependencies
        // between the jobs we just continue to defer the subsequent job while the first one is running in
        // order to prevent multiple configurationSync jobs with the same target from running at the same time
        guard
            dependencies[singleton: .jobRunner]
                .jobInfoFor(state: .running, variant: .configurationSync)
                .filter({ key, info in
                    key != job.id &&                // Exclude this job
                    info.threadId == job.threadId   // Exclude jobs for different config stores
                })
                .isEmpty
        else {
            // Defer the job to run 'maxRunFrequency' from when this one ran (if we don't it'll try start
            // it again immediately which is pointless)
            let updatedJob: Job? = dependencies[singleton: .storage].write { db in
                try job
                    .with(nextRunTimestamp: dependencies.dateNow.timeIntervalSince1970 + maxRunFrequency)
                    .upserted(db)
            }
            
            Log.info(.cat, "For \(job.threadId ?? "UnknownId") deferred due to in progress job")
            return deferred(updatedJob ?? job)
        }
        
        // If we don't have a userKeyPair yet then there is no need to sync the configuration
        // as the user doesn't exist yet (this will get triggered on the first launch of a
        // fresh install due to the migrations getting run)
        guard
            let swarmPublicKey: String = job.threadId,
            let pendingChanges: LibSession.PendingChanges = dependencies[singleton: .storage].read({ db in
                try dependencies.mutate(cache: .libSession) {
                    try $0.pendingChanges(db, swarmPubkey: swarmPublicKey)
                }
            })
        else {
            Log.info(.cat, "For \(job.threadId ?? "UnknownId") failed due to invalid data")
            return failure(job, StorageError.generic, false)
        }
        
        // If there are no pending changes then the job can just complete (next time something
        // is updated we want to try and run immediately so don't scuedule another run in this case)
        guard !pendingChanges.pushData.isEmpty || !pendingChanges.obsoleteHashes.isEmpty else {
            Log.info(.cat, "For \(swarmPublicKey) completed with no pending changes")
            return success(job, true)
        }
        
        let jobStartTimestamp: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        let messageSendTimestamp: Int64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        Log.info(.cat, "For \(swarmPublicKey) started with changes: \(pendingChanges.pushData.count), old hashes: \(pendingChanges.obsoleteHashes.count)")
        
        // TODO: Seems like the conversation list will randomly not get the last message (Lokinet updates???).
        dependencies[singleton: .storage]
            .readPublisher { db -> Network.PreparedRequest<Network.BatchResponse> in
                try SnodeAPI.preparedSequence(
                    requests: try pendingChanges.pushData
                        .map { pushData -> ErasedPreparedRequest in
                            try SnodeAPI
                                .preparedSendMessage(
                                    message: SnodeMessage(
                                        recipient: swarmPublicKey,
                                        data: pushData.data.base64EncodedString(),
                                        ttl: pushData.variant.ttl,
                                        timestampMs: UInt64(messageSendTimestamp)
                                    ),
                                    in: pushData.variant.namespace,
                                    authMethod: try Authentication.with(
                                        db,
                                        swarmPublicKey: swarmPublicKey,
                                        using: dependencies
                                    ),
                                    using: dependencies
                                )
                        }
                        .appending(try {
                            guard !pendingChanges.obsoleteHashes.isEmpty else { return nil }
                            
                            return try SnodeAPI.preparedDeleteMessages(
                                serverHashes: Array(pendingChanges.obsoleteHashes),
                                requireSuccessfulDeletion: false,
                                authMethod: try Authentication.with(
                                    db,
                                    swarmPublicKey: swarmPublicKey,
                                    using: dependencies
                                ),
                                using: dependencies
                            )
                        }()),
                    requireAllBatchResponses: false,
                    swarmPublicKey: swarmPublicKey,
                    using: dependencies
                )
            }
            .flatMap { $0.send(using: dependencies) }
            .subscribe(on: queue, using: dependencies)
            .receive(on: queue, using: dependencies)
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
                        return dependencies.mutate(cache: .libSession) { cache in
                            cache.markingAsPushed(
                                seqNo: pushData.seqNo,
                                serverHash: sendMessageResponse.hash,
                                sentTimestamp: messageSendTimestamp,
                                variant: pushData.variant,
                                swarmPublicKey: swarmPublicKey
                            )
                        }
                    }
            }
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: Log.info(.cat, "For \(swarmPublicKey) completed")
                        case .failure(let error):
                            Log.error(.cat, "For \(swarmPublicKey) failed due to error: \(error)")
                            failure(job, error, false)
                    }
                },
                receiveValue: { (configDumps: [ConfigDump]) in
                    // Flag to indicate whether the job should be finished or will run again
                    var shouldFinishCurrentJob: Bool = false
                    
                    // Lastly we need to save the updated dumps to the database
                    let updatedJob: Job? = dependencies[singleton: .storage].write { db in
                        // Save the updated dumps to the database
                        try configDumps.forEach { try $0.upsert(db) }
                        
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
                                .filter(Job.Columns.threadId == swarmPublicKey)
                                .order(Job.Columns.nextRunTimestamp.asc)
                                .fetchOne(db)
                        {
                            // If the next job isn't currently running then delay it's start time
                            // until the 'nextRunTimestamp' unless it was manually triggered (in which
                            // case we want it to run immediately as some thread is likely waiting on
                            // it to return)
                            if !dependencies[singleton: .jobRunner].isCurrentlyRunning(existingJob) {
                                let jobWasManualTrigger: Bool = (existingJob.details
                                    .map { try? JSONDecoder(using: dependencies).decode(OptionalDetails.self, from: $0) }
                                    .map { $0.wasManualTrigger })
                                    .defaulting(to: false)
                                
                                try existingJob
                                    .with(nextRunTimestamp: (jobWasManualTrigger ? 0 : nextRunTimestamp))
                                    .upserted(db)
                            }
                            
                            // If there is another job then we should finish this one
                            shouldFinishCurrentJob = true
                            return job
                        }
                        
                        return try job
                            .with(nextRunTimestamp: nextRunTimestamp)
                            .upserted(db)
                    }
                    
                    success((updatedJob ?? job), shouldFinishCurrentJob)
                }
            )
    }
}

// MARK: - ConfigurationSyncJob.OptionalDetails

extension ConfigurationSyncJob {
    public struct OptionalDetails: Codable {
        private enum CodingKeys: String, CodingKey {
            case wasManualTrigger
        }
        
        public let wasManualTrigger: Bool
    }
}

// MARK: - Convenience

public extension ConfigurationSyncJob {
    static func enqueue(
        _ db: Database,
        swarmPublicKey: String,
        using dependencies: Dependencies
    ) {
        // Upsert a config sync job if needed
        dependencies[singleton: .jobRunner].upsert(
            db,
            job: ConfigurationSyncJob.createIfNeeded(db, swarmPublicKey: swarmPublicKey, using: dependencies),
            canStartJob: true
        )
    }
    
    @discardableResult static func createIfNeeded(
        _ db: Database,
        swarmPublicKey: String,
        using dependencies: Dependencies
    ) -> Job? {
        /// The ConfigurationSyncJob will automatically reschedule itself to run again after 3 seconds so if there is an existing
        /// job then there is no need to create another instance
        ///
        /// **Note:** Jobs with different `threadId` values can run concurrently
        guard
            dependencies[singleton: .jobRunner]
                .jobInfoFor(state: .running, variant: .configurationSync)
                .filter({ _, info in info.threadId == swarmPublicKey })
                .isEmpty,
            (try? Job
                .filter(Job.Columns.variant == Job.Variant.configurationSync)
                .filter(Job.Columns.threadId == swarmPublicKey)
                .isEmpty(db))
                .defaulting(to: false)
        else { return nil }
        
        // Otherwise create a new job
        return Job(
            variant: .configurationSync,
            behaviour: .recurring,
            threadId: swarmPublicKey
        )
    }
    
    /// Trigger the job emitting the result when completed
    ///
    /// **Note:** The `ConfigurationSyncJob` can only have a single instance running at a time, as a result this call may not
    /// resolve until after the current job has completed
    static func run(
        swarmPublicKey: String,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        return Deferred {
            Future { resolver in
                guard
                    let job: Job = Job(
                        variant: .configurationSync,
                        threadId: swarmPublicKey,
                        details: OptionalDetails(wasManualTrigger: true)
                    )
                else { return resolver(Result.failure(NetworkError.parsingFailed)) }
                
                ConfigurationSyncJob.run(
                    job,
                    queue: .global(qos: .userInitiated),
                    success: { _, _ in resolver(Result.success(())) },
                    failure: { _, error, _ in resolver(Result.failure(error)) },
                    deferred: { job in
                        dependencies[singleton: .jobRunner].afterJob(job) { result in
                            switch result {
                                /// If it gets deferred a second time then we should probably just fail - no use waiting on something
                                /// that may never run (also means we can avoid another potential defer loop)
                                case .notFound, .deferred: resolver(Result.failure(NetworkError.unknown))
                                case .failed(let error, _): resolver(Result.failure(error))
                                case .succeeded: resolver(Result.success(()))
                            }
                        }
                    },
                    using: dependencies
                )
            }
        }
        .eraseToAnyPublisher()
    }
}
