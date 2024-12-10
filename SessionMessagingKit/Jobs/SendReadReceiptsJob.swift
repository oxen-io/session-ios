// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

public enum SendReadReceiptsJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    private static let maxRunFrequency: TimeInterval = 3
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        guard
            let threadId: String = job.threadId,
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { return failure(job, JobRunnerError.missingRequiredDetails, true) }
        
        // If there are no timestampMs values then the job can just complete (next time
        // something is marked as read we want to try and run immediately so don't scuedule
        // another run in this case)
        guard !details.timestampMsValues.isEmpty else {
            return success(job, true)
        }
        
        dependencies[singleton: .storage]
            .writePublisher { db -> Network.PreparedRequest<Void> in
                try MessageSender.preparedSend(
                    db,
                    message: ReadReceipt(
                        timestamps: details.timestampMsValues.map { UInt64($0) }
                    ),
                    to: details.destination,
                    namespace: details.destination.defaultNamespace,
                    interactionId: nil,
                    fileIds: [],
                    using: dependencies
                )
            }
            .flatMap { $0.send(using: dependencies) }
            .subscribe(on: queue, using: dependencies)
            .receive(on: queue, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .failure(let error): failure(job, error, false)
                        case .finished:
                            // When we complete the 'SendReadReceiptsJob' we want to immediately schedule
                            // another one for the same thread but with a 'nextRunTimestamp' set to the
                            // 'maxRunFrequency' value to throttle the read receipt requests
                            var shouldFinishCurrentJob: Bool = false
                            let nextRunTimestamp: TimeInterval = (dependencies.dateNow.timeIntervalSince1970 + maxRunFrequency)
                            
                            let updatedJob: Job? = dependencies[singleton: .storage].write { db in
                                // If another 'sendReadReceipts' job was scheduled then update that one
                                // to run at 'nextRunTimestamp' and make the current job stop
                                if
                                    let existingJob: Job = try? Job
                                        .filter(Job.Columns.id != job.id)
                                        .filter(Job.Columns.variant == Job.Variant.sendReadReceipts)
                                        .filter(Job.Columns.threadId == threadId)
                                        .fetchOne(db),
                                    !dependencies[singleton: .jobRunner].isCurrentlyRunning(existingJob)
                                {
                                    try existingJob
                                        .with(nextRunTimestamp: nextRunTimestamp)
                                        .upserted(db)
                                    shouldFinishCurrentJob = true
                                    return job
                                }
                                
                                return try job
                                    .with(details: Details(destination: details.destination, timestampMsValues: []))
                                    .defaulting(to: job)
                                    .with(nextRunTimestamp: nextRunTimestamp)
                                    .upserted(db)
                            }
                            
                            success(updatedJob ?? job, shouldFinishCurrentJob)
                    }
                }
            )
    }
}


// MARK: - SendReadReceiptsJob.Details

extension SendReadReceiptsJob {
    public struct Details: Codable {
        public let destination: Message.Destination
        public let timestampMsValues: Set<Int64>
    }
}

// MARK: - Convenience

public extension SendReadReceiptsJob {
    /// This method upserts a 'sendReadReceipts' job to include the timestamps for the specified `interactionIds`
    ///
    /// **Note:** This method assumes that the provided `interactionIds` are valid and won't filter out any invalid ids so
    /// ensure that is done correctly beforehand
    @discardableResult static func createOrUpdateIfNeeded(
        _ db: Database,
        threadId: String,
        interactionIds: [Int64],
        using dependencies: Dependencies
    ) -> Job? {
        guard db[.areReadReceiptsEnabled] == true else { return nil }
        guard !interactionIds.isEmpty else { return nil }
        
        // Retrieve the timestampMs values for the specified interactions
        let timestampMsValues: [Int64] = (try? Interaction
            .select(.timestampMs)
            .filter(interactionIds.contains(Interaction.Columns.id))
            .distinct()
            .asRequest(of: Int64.self)
            .fetchAll(db))
            .defaulting(to: [])
        
        // If there are no timestamp values then do nothing
        guard !timestampMsValues.isEmpty else { return nil }
        
        // Try to get an existing job (if there is one that's not running)
        if
            let existingJob: Job = try? Job
                .filter(Job.Columns.variant == Job.Variant.sendReadReceipts)
                .filter(Job.Columns.threadId == threadId)
                .fetchOne(db),
            !dependencies[singleton: .jobRunner].isCurrentlyRunning(existingJob),
            let existingDetailsData: Data = existingJob.details,
            let existingDetails: Details = try? JSONDecoder(using: dependencies)
                .decode(Details.self, from: existingDetailsData)
        {
            let maybeUpdatedJob: Job? = existingJob
                .with(
                    details: Details(
                        destination: existingDetails.destination,
                        timestampMsValues: existingDetails.timestampMsValues
                            .union(timestampMsValues)
                    )
                )
            
            guard let updatedJob: Job = maybeUpdatedJob else { return nil }
            
            return try? updatedJob
                .upserted(db)
        }
        
        // Otherwise create a new job
        return Job(
            variant: .sendReadReceipts,
            behaviour: .recurring,
            threadId: threadId,
            details: Details(
                destination: .contact(publicKey: threadId),
                timestampMsValues: timestampMsValues.asSet()
            )
        )
    }
}
