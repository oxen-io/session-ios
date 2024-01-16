// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

@testable import SessionUtilitiesKit

class MockJobRunner: Mock<JobRunnerType>, JobRunnerType {
    // MARK: - Configuration
    
    func setExecutor(_ executor: JobExecutor.Type, for variant: Job.Variant) {
        mockNoReturn(args: [executor, variant])
    }
    
    func canStart(queue: JobQueue?) -> Bool {
        return mock(args: [queue])
    }
    
    func afterBlockingQueue(callback: @escaping () -> ()) {
        mockNoReturn()
    }
    
    // MARK: - State Management
    
    func jobInfoFor(jobs: [Job]?, state: JobRunner.JobState, variant: Job.Variant?) -> [Int64: JobRunner.JobInfo] {
        return mock(args: [jobs, state, variant])
    }
    
    func appDidFinishLaunching(using dependencies: Dependencies) {}
    func appDidBecomeActive(using dependencies: Dependencies) {}
    func startNonBlockingQueues(using dependencies: Dependencies) {}
    
    func stopAndClearPendingJobs(exceptForVariant: Job.Variant?, onComplete: (() -> ())?, using dependencies: Dependencies) {
        mockNoReturn(args: [exceptForVariant, onComplete], untrackedArgs: [dependencies])
        onComplete?()
    }
    
    // MARK: - Job Scheduling
    
    @discardableResult func add(_ db: Database, job: Job?, dependantJob: Job?, canStartJob: Bool, using dependencies: Dependencies) -> Job? {
        return mock(args: [job, dependantJob, canStartJob], untrackedArgs: [db, dependencies])
    }
    
    func upsert(_ db: Database, job: Job?, canStartJob: Bool, using dependencies: Dependencies) {
        mockNoReturn(args: [job, canStartJob], untrackedArgs: [db, dependencies])
    }
    
    func insert(_ db: Database, job: Job?, before otherJob: Job) -> (Int64, Job)? {
        return mock(args: [job, otherJob], untrackedArgs: [db])
    }
    
    func enqueueDependenciesIfNeeded(_ jobs: [Job], using dependencies: Dependencies) {
        mockNoReturn(args: [jobs], untrackedArgs: [dependencies])
    }
    
    func afterJob(_ job: Job?, state: JobRunner.JobState, callback: @escaping (JobRunner.JobResult) -> ()) {
        mockNoReturn(args: [job, callback])
        callback(.succeeded)
    }
    
    func removePendingJob(_ job: Job?) {
        mockNoReturn(args: [job])
    }
}
