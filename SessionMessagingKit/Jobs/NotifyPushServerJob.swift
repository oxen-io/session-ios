// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionSnodeKit
import SessionUtilitiesKit

// FIXME: Remove this once legacy notifications and legacy groups are deprecated
public enum NotifyPushServerJob: JobExecutor {
    public static var maxFailureCount: Int = 20
    public static var requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies
    ) {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else {
            SNLog("[NotifyPushServerJob] Failing due to missing details")
            return failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
        }
        
        dependencies[singleton: .storage]
            .readPublisher(using: dependencies) { db in
                try PushNotificationAPI.preparedLegacyNotify(
                    recipient: details.message.recipient,
                    with: details.message.data,
                    maxRetryCount: 4,
                    using: dependencies
                )
            }
            .flatMap { $0.send(using: dependencies) }
            .subscribe(on: queue, using: dependencies)
            .receive(on: queue, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: success(job, false, dependencies)
                        case .failure(let error): failure(job, error, false, dependencies)
                    }
                }
            )
    }
}

// MARK: - NotifyPushServerJob.Details

extension NotifyPushServerJob {
    public struct Details: Codable {
        public let message: SnodeMessage
    }
}