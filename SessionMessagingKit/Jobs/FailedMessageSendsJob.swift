// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("FailedMessageSendsJob", defaultLevel: .info)
}

// MARK: - FailedMessageSendsJob

public enum FailedMessageSendsJob: JobExecutor {
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
        guard Identity.userExists(using: dependencies) else { return success(job, false) }
        
        var changeCount: Int = -1
        var attachmentChangeCount: Int = -1
        
        // Update all 'sending' message states to 'failed'
        dependencies[singleton: .storage]
            .writePublisher { db in
                let sendChangeCount: Int = try Interaction
                    .filter(Interaction.Columns.state == Interaction.State.sending)
                    .updateAll(db, Interaction.Columns.state.set(to: Interaction.State.failed))
                let syncChangeCount: Int = try Interaction
                    .filter(Interaction.Columns.state == Interaction.State.syncing)
                    .updateAll(db, Interaction.Columns.state.set(to: Interaction.State.failedToSync))
                attachmentChangeCount = try Attachment
                    .filter(Attachment.Columns.state == Attachment.State.uploading)
                    .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.failedUpload))
                changeCount = (sendChangeCount + syncChangeCount)
            }
            .subscribe(on: queue, using: dependencies)
            .receive(on: queue, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { _ in
                    Log.info(.cat, "Messages marked as failed: \(changeCount), Uploads cancelled: \(attachmentChangeCount)")
                    success(job, false)
                }
            )
    }
}
