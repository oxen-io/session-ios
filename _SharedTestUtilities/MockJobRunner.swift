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
    
    func queue(for variant: Job.Variant) -> DispatchQueue? { DispatchQueue.main }
    
    // MARK: - State Management
    
    func jobInfoFor(jobs: [Job]?, state: JobRunner.JobState, variant: Job.Variant?) -> [Int64: JobRunner.JobInfo] {
        return mock(args: [jobs, state, variant])
    }
    
    func appDidFinishLaunching() {}
    func appDidBecomeActive() {}
    func startNonBlockingQueues() {}
    
    func stopAndClearPendingJobs(exceptForVariant: Job.Variant?, onComplete: ((Bool) -> ())?) {
        mockNoReturn(args: [exceptForVariant, onComplete])
        onComplete?(false)
    }
    
    // MARK: - Job Scheduling
    
    @discardableResult func add(_ db: Database, job: Job?, dependantJob: Job?, canStartJob: Bool) -> Job? {
        return mock(args: [job, dependantJob, canStartJob], untrackedArgs: [db])
    }
    
    func upsert(_ db: Database, job: Job?, canStartJob: Bool) -> Job? {
        return mock(args: [job, canStartJob], untrackedArgs: [db])
    }
    
    func insert(_ db: Database, job: Job?, before otherJob: Job) -> (Int64, Job)? {
        return mock(args: [job, otherJob], untrackedArgs: [db])
    }
    
    func enqueueDependenciesIfNeeded(_ jobs: [Job]) {
        mockNoReturn(args: [jobs])
    }
    
    func afterJob(_ job: Job?, state: JobRunner.JobState, callback: @escaping (JobRunner.JobResult) -> ()) {
        mockNoReturn(args: [job, state], untrackedArgs: [callback])
        callback(.succeeded)
    }
    
    func manuallyTriggerResult(_ job: Job?, result: JobRunner.JobResult) {
        mockNoReturn(args: [job, result])
    }
    
    func removePendingJob(_ job: Job?) {
        mockNoReturn(args: [job])
    }
}
