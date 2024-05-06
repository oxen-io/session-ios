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
        dependencies[singleton: .storage].write { db in
            let sendChangeCount: Int = try RecipientState
                .filter(RecipientState.Columns.state == RecipientState.State.sending)
                .updateAll(db, RecipientState.Columns.state.set(to: RecipientState.State.failed))
            let syncChangeCount: Int = try RecipientState
                .filter(RecipientState.Columns.state == RecipientState.State.syncing)
                .updateAll(db, RecipientState.Columns.state.set(to: RecipientState.State.failedToSync))
            attachmentChangeCount = try Attachment
                .filter(Attachment.Columns.state == Attachment.State.uploading)
                .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.failedUpload))
            changeCount = (sendChangeCount + syncChangeCount)
        }
        
        SNLog("[FailedMessageSendsJob] Marked \(changeCount) message\(plural: changeCount) as failed (\(attachmentChangeCount) upload\(plural: attachmentChangeCount) cancelled)")
        success(job, false, dependencies)
    }
}
