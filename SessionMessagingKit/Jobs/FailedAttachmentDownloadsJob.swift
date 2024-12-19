// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("FailedAttachmentDownloadsJob", defaultLevel: .info)
}

// MARK: - FailedAttachmentDownloadsJob

public enum FailedAttachmentDownloadsJob: JobExecutor {
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
        
        // Update all 'sending' message states to 'failed'
        dependencies[singleton: .storage].write { db in
            changeCount = try Attachment
                .filter(Attachment.Columns.state == Attachment.State.downloading)
                .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.failedDownload))
        }
        
        Log.info(.cat, "Marked \(changeCount) attachments as failed")
        success(job, false)
    }
}
