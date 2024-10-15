// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("ConfigMessageReceiveJob", defaultLevel: .info)
}

// MARK: - ConfigMessageReceiveJob

public enum ConfigMessageReceiveJob: JobExecutor {
    public static var maxFailureCount: Int = 0
    public static var requiresThreadId: Bool = true
    public static let requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        /// When the `configMessageReceive` job fails we want to unblock any `messageReceive` jobs it was blocking
        /// to ensure the user isn't losing any messages - this generally _shouldn't_ happen but if it does then having a temporary
        /// "outdated" state due to standard messages which would have been invalidated by a config change incorrectly being
        /// processed is less severe then dropping a bunch on messages just because they were processed in the same poll as
        /// invalid config messages
        let removeDependencyOnMessageReceiveJobs: () -> () = {
            guard let jobId: Int64 = job.id else { return }
            
            dependencies[singleton: .storage].write { db in
                try JobDependencies
                    .filter(JobDependencies.Columns.dependantId == jobId)
                    .joining(
                        required: JobDependencies.job
                            .filter(Job.Columns.variant == Job.Variant.messageReceive)
                    )
                    .deleteAll(db)
            }
        }
        
        guard
            let swarmPublicKey: String = job.threadId,
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else {
            removeDependencyOnMessageReceiveJobs()
            return failure(job, JobRunnerError.missingRequiredDetails, true)
        }
        
        var lastError: Error?
        
        dependencies[singleton: .storage].write { db in
            // Send any SharedConfigMessages to the LibSession to handle it
            do {
                try dependencies.mutate(cache: .libSession) { cache in
                    try cache.handleConfigMessages(
                        db,
                        swarmPublicKey: swarmPublicKey,
                        messages: details.messages
                    )
                }
            }
            catch { lastError = error }
        }
        
        // Handle the result
        switch lastError {
            case .some(let error):
                Log.error(.cat, "Couldn't receive config message due to error: \(error)")
                removeDependencyOnMessageReceiveJobs()
                failure(job, error, true)

            case .none: success(job, false)
        }
    }
}

// MARK: - ConfigMessageReceiveJob.Details

extension ConfigMessageReceiveJob {
    public struct Details: Codable {
        public struct MessageInfo: Codable {
            private enum CodingKeys: String, CodingKey {
                case namespace
                case serverHash
                case serverTimestampMs
                case data
            }
            
            public let namespace: SnodeAPI.Namespace
            public let serverHash: String
            public let serverTimestampMs: Int64
            public let data: Data
            
            public init(
                namespace: SnodeAPI.Namespace,
                serverHash: String,
                serverTimestampMs: Int64,
                data: Data
            ) {
                self.namespace = namespace
                self.serverHash = serverHash
                self.serverTimestampMs = serverTimestampMs
                self.data = data
            }
        }
        
        public let messages: [MessageInfo]
        
        public init(messages: [ProcessedMessage]) {
            self.messages = messages
                .compactMap { processedMessage -> MessageInfo? in
                    switch processedMessage {
                        case .standard: return nil
                        case .config(_, let namespace, let serverHash, let serverTimestampMs, let data):
                            return MessageInfo(
                                namespace: namespace,
                                serverHash: serverHash,
                                serverTimestampMs: serverTimestampMs,
                                data: data
                            )
                    }
            }
        }
    }
}
