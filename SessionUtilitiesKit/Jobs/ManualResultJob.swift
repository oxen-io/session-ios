// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum ManualResultJob: JobExecutor {
    public static var maxFailureCount: Int = -1
    public static var requiresThreadId: Bool = false
    public static var requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies
    ) {
        // Do nothing (the code will manually trigger the result for this job via the JobRunner)
    }
}
