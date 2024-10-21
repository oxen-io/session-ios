// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public enum FailedMessageSendsJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies
    ) {
        var changeCount: Int = -1
        var attachmentChangeCount: Int = -1
        
        // Update all 'sending' message states to 'failed'
        dependencies.storage
            .writePublisher(using: dependencies) { db in
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
                    SNLog("[FailedMessageSendsJob] Marked \(changeCount) message\(changeCount == 1 ? "" : "s") as failed (\(attachmentChangeCount) upload\(attachmentChangeCount == 1 ? "" : "s") cancelled)")
                    success(job, false, dependencies)
                }
            )
    }
}
