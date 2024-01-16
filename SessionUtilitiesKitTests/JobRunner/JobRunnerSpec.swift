// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

import Quick
import Nimble

@testable import SessionUtilitiesKit

class JobRunnerSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var job1: Job! = Job(
            id: 100,
            failureCount: 0,
            variant: .messageSend,
            behaviour: .runOnce,
            shouldBlock: false,
            shouldBeUnique: false,
            shouldSkipLaunchBecomeActive: false,
            nextRunTimestamp: 0,
            threadId: nil,
            interactionId: nil,
            details: nil
        )
        @TestState var job2: Job! = Job(
            id: 101,
            failureCount: 0,
            variant: .attachmentUpload,
            behaviour: .runOnce,
            shouldBlock: false,
            shouldBeUnique: false,
            shouldSkipLaunchBecomeActive: false,
            nextRunTimestamp: 0,
            threadId: nil,
            interactionId: nil,
            details: nil
        )
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 0)
            dependencies.forceSynchronous = true
            dependencies.setMockableValue(JSONEncoder.OutputFormatting.sortedKeys)  // Deterministic ordering
        }
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrationTargets: [
                SNUtilitiesKit.self
            ],
            using: dependencies,
            initialData: { db in
                // Migrations add jobs which we don't want so delete them
                try Job.deleteAll(db)
            }
        )
        @TestState(singleton: .jobRunner, in: dependencies) var jobRunner: JobRunnerType! = JobRunner(
            isTestingJobRunner: true,
            executors: [
                .messageSend: TestJob.self,
                .attachmentUpload: TestJob.self,
                .messageReceive: TestJob.self
            ],
            using: dependencies
        )
        
        // MARK: - a JobRunner
        describe("a JobRunner") {
            afterEach {
                /// We **must** set `fixedTime` to ensure we break any loops within the `TestJob` executor
                dependencies.fixedTime = Int.max
                jobRunner.stopAndClearPendingJobs(using: dependencies)
            }
            
            // MARK: -- when configuring
            context("when configuring") {
                // MARK: ---- adds an executor correctly
                it("adds an executor correctly") {
                    job1 = Job(
                        id: 101,
                        failureCount: 0,
                        variant: .getSnodePool,
                        behaviour: .runOnce,
                        shouldBlock: false,
                        shouldBeUnique: false,
                        shouldSkipLaunchBecomeActive: false,
                        nextRunTimestamp: 0,
                        threadId: nil,
                        interactionId: nil,
                        details: try? JSONEncoder(using: dependencies)
                            .encode(TestDetails(completeTime: 1))
                    )
                    jobRunner.appDidFinishLaunching(using: dependencies)
                    jobRunner.appDidBecomeActive(using: dependencies)
                    
                    // Save the job to the database
                    mockStorage.write { db in _ = try job1.inserted(db) }
                    expect(mockStorage.read { db in try Job.fetchCount(db) }).to(equal(1))
                    
                    // Try to start the job
                    mockStorage.write { db in
                        jobRunner.upsert(
                            db,
                            job: job1,
                            canStartJob: true,
                            using: dependencies
                        )
                    }
                    
                    // Ensure the job isn't running, and that it has been deleted (can't retry if there
                    // is no executer so no failure counts)
                    expect(jobRunner.isCurrentlyRunning(job1)).to(beFalse())
                    expect(mockStorage.read { db in try Job.fetchCount(db) }).to(equal(0))
                    
                    // Add the executor and start the job again
                    jobRunner.setExecutor(TestJob.self, for: .getSnodePool)
                    
                    mockStorage.write { db in
                        jobRunner.add(
                            db,
                            job: job1,
                            canStartJob: true,
                            using: dependencies
                        )
                    }
                    
                    // Job is now running
                    expect(jobRunner.isCurrentlyRunning(job1)).to(beTrue())
                }
            }
            
            // MARK: ---- when managing state
            context("when managing state") {
                // MARK: ------ by checking if a job is currently running
                context("by checking if a job is currently running") {
                    // MARK: -------- returns false when not given a job
                    it("returns false when not given a job") {
                        expect(jobRunner.isCurrentlyRunning(nil)).to(beFalse())
                    }
                    
                    // MARK: -------- returns false when given a job that has not been persisted
                    it("returns false when given a job that has not been persisted") {
                        job1 = Job(variant: .messageSend)
                        
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beFalse())
                    }
                    
                    // MARK: -------- returns false when given a job that is not running
                    it("returns false when given a job that is not running") {
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beFalse())
                    }
                    
                    // MARK: -------- returns true when given a non blocking job that is running
                    it("returns true when given a non blocking job that is running") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beTrue())
                    }
                    
                    // MARK: -------- returns true when given a blocking job that is running
                    it("returns true when given a blocking job that is running") {
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .runOnceNextLaunch,
                            shouldBlock: true,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job2,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job2)).to(beTrue())
                    }
                }
                
                // MARK: ------ by getting the details for jobs
                context("by getting the details for jobs") {
                    // MARK: -------- returns an empty dictionary when there are no jobs
                    it("returns an empty dictionary when there are no jobs") {
                        expect(jobRunner.allJobInfo()).to(equal([:]))
                    }
                    
                    // MARK: -------- returns an empty dictionary when there are no jobs matching the filters
                    it("returns an empty dictionary when there are no jobs matching the filters") {
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job2,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        expect(jobRunner.jobInfoFor(state: .running, variant: .messageSend)).to(equal([:]))
                    }
                    
                    // MARK: -------- can filter to specific jobs
                    it("can filter to specific jobs") {
                        job1 = Job(
                            id: 100,
                            failureCount: 0,
                            variant: .messageReceive,
                            behaviour: .runOnce,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .messageReceive,
                            behaviour: .runOnce,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: nil
                        )
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                            
                            jobRunner.add(
                                db,
                                job: job2,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        // Validate the filtering works
                        expect(jobRunner.allJobInfo()).toNot(beEmpty())
                        expect(jobRunner.jobInfoFor(jobs: [job1]))
                            .to(equal([
                                100: JobRunner.JobInfo(
                                    variant: .messageReceive,
                                    threadId: nil,
                                    interactionId: nil,
                                    detailsData: job1.details,
                                    uniqueHashValue: nil
                                )
                            ]))
                        expect(jobRunner.jobInfoFor(jobs: [job2]))
                            .to(equal([
                                101: JobRunner.JobInfo(
                                    variant: .messageReceive,
                                    threadId: nil,
                                    interactionId: nil,
                                    detailsData: nil,
                                    uniqueHashValue: nil
                                )
                            ]))
                    }
                    
                    // MARK: -------- can filter to running jobs
                    it("can filter to running jobs") {
                        job1 = Job(
                            id: 100,
                            failureCount: 0,
                            variant: .messageReceive,
                            behaviour: .runOnce,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .messageReceive,
                            behaviour: .runOnce,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                            
                            jobRunner.add(
                                db,
                                job: job2,
                                canStartJob: false,
                                using: dependencies
                            )
                        }
                        
                        // Wait for there to be data and the validate the filtering works
                        expect(jobRunner.jobInfoFor(state: .running))
                            .to(equal([
                                100: JobRunner.JobInfo(
                                    variant: .messageReceive,
                                    threadId: nil,
                                    interactionId: nil,
                                    detailsData: try! JSONEncoder(using: dependencies)
                                        .encode(TestDetails(completeTime: 1)),
                                    uniqueHashValue: nil
                                )
                            ]))
                        expect(Array(jobRunner.allJobInfo().keys).sorted()).to(equal([100, 101]))
                    }
                    
                    // MARK: -------- can filter to pending jobs
                    it("can filter to pending jobs") {
                        job1 = Job(
                            id: 100,
                            failureCount: 0,
                            variant: .messageReceive,
                            behaviour: .runOnce,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .messageReceive,
                            behaviour: .runOnce,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                            
                            jobRunner.add(
                                db,
                                job: job2,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        // Wait for there to be data and the validate the filtering works
                        expect(jobRunner.jobInfoFor(state: .pending))
                            .to(equal([
                                101: JobRunner.JobInfo(
                                    variant: .messageReceive,
                                    threadId: nil,
                                    interactionId: nil,
                                    detailsData: try! JSONEncoder(using: dependencies)
                                        .encode(TestDetails(completeTime: 1)),
                                    uniqueHashValue: nil
                                )
                            ]))
                        expect(Array(jobRunner.allJobInfo().keys).sorted()).to(equal([100, 101]))
                    }
                    
                    // MARK: -------- can filter to specific variants
                    it("can filter to specific variants") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        job2 = job2.with(details: TestDetails(completeTime: 2))
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                            
                            jobRunner.add(
                                db,
                                job: job2,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        // Wait for there to be data and the validate the filtering works
                        expect(jobRunner.jobInfoFor(variant: .attachmentUpload))
                            .to(equal([
                                101: JobRunner.JobInfo(
                                    variant: .attachmentUpload,
                                    threadId: nil,
                                    interactionId: nil,
                                    detailsData: try! JSONEncoder(using: dependencies)
                                        .encode(TestDetails(completeTime: 2)),
                                    uniqueHashValue: nil
                                )
                            ]))
                        expect(Array(jobRunner.allJobInfo().keys).sorted()).to(equal([100, 101]))
                    }
                    
                    // MARK: -------- includes non blocking jobs
                    it("includes non blocking jobs") {
                        job2 = job2.with(details: TestDetails(completeTime: 1))
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job2,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        expect(jobRunner.jobInfoFor(state: .running, variant: .attachmentUpload))
                            .to(equal([
                                101: JobRunner.JobInfo(
                                    variant: .attachmentUpload,
                                    threadId: nil,
                                    interactionId: nil,
                                    detailsData: try! JSONEncoder(using: dependencies)
                                        .encode(TestDetails(completeTime: 1)),
                                    uniqueHashValue: nil
                                )
                            ]))
                    }
                    
                    // MARK: -------- includes blocking jobs
                    it("includes blocking jobs") {
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .attachmentUpload,
                            behaviour: .runOnceNextLaunch,
                            shouldBlock: true,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try! JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job2,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        
                        expect(jobRunner.jobInfoFor(state: .running, variant: .attachmentUpload))
                            .to(equal([
                                101: JobRunner.JobInfo(
                                    variant: .attachmentUpload,
                                    threadId: nil,
                                    interactionId: nil,
                                    detailsData: try! JSONEncoder(using: dependencies)
                                        .encode(TestDetails(completeTime: 1)),
                                    uniqueHashValue: nil
                                )
                            ]))
                    }
                }
                
                // MARK: ------ by checking for an existing job
                context("by checking for an existing job") {
                    // MARK: -------- returns false for a queue that doesn't exist
                    it("returns false for a queue that doesn't exist") {
                        jobRunner = JobRunner(
                            isTestingJobRunner: true,
                            variantsToExclude: [.attachmentUpload],
                            using: dependencies
                        )
                        
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: TestDetails()))
                            .to(beFalse())
                    }
                    
                    // MARK: -------- returns false when the provided details fail to decode
                    it("returns false when the provided details fail to decode") {
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: InvalidDetails()))
                            .to(beFalse())
                    }
                    
                    // MARK: -------- returns false when there is not a pending or running job
                    it("returns false when there is not a pending or running job") {
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: TestDetails()))
                            .to(beFalse())
                    }
                    
                    // MARK: -------- returns true when there is a pending job
                    it("returns true when there is a pending job") {
                        job1 = Job(
                            id: 100,
                            failureCount: 0,
                            variant: .messageReceive,
                            behaviour: .runOnce,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .messageReceive,
                            behaviour: .runOnce,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 2))
                        )
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                            
                            jobRunner.add(
                                db,
                                job: job2,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        expect(Array(jobRunner.jobInfoFor(state: .pending, variant: .messageReceive).keys))
                            .to(equal([101]))
                        expect(jobRunner.hasJob(of: .messageReceive, with: TestDetails(completeTime: 2)))
                            .to(beTrue())
                    }
                    
                    // MARK: -------- returns true when there is a running job
                    it("returns true when there is a running job") {
                        job2 = job2.with(details: TestDetails(completeTime: 1))
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job2,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        expect(Array(jobRunner.jobInfoFor(state: .running, variant: .attachmentUpload).keys))
                            .to(equal([101]))
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: TestDetails(completeTime: 1)))
                            .to(beTrue())
                    }
                    
                    // MARK: -------- returns true when there is a blocking job
                    it("returns true when there is a blocking job") {
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .attachmentUpload,
                            behaviour: .runOnceNextLaunch,
                            shouldBlock: true,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try! JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job2,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        // Need to add the job before starting it since it's a 'runOnceNextLaunch'
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        expect(Array(jobRunner.jobInfoFor(state: .running, variant: .attachmentUpload).keys))
                            .to(equal([101]))
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: TestDetails(completeTime: 1)))
                            .to(beTrue())
                    }
                    
                    // MARK: -------- returns true when there is a non blocking job
                    it("returns true when there is a non blocking job") {
                        job2 = job2.with(details: TestDetails(completeTime: 1))
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job2,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        expect(Array(jobRunner.jobInfoFor(state: .running, variant: .attachmentUpload).keys))
                            .to(equal([101]))
                        expect(jobRunner.hasJob(of: .attachmentUpload, with: TestDetails(completeTime: 1)))
                            .to(beTrue())
                    }
                }
                
                // MARK: ------ by being notified of app launch
                context("by being notified of app launch") {
                    // MARK: -------- does not start a job before getting the app launch call
                    it("does not start a job before getting the app launch call") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beFalse())
                    }
                    
                    // MARK: -------- starts the job queues if there are no app launch jobs
                    it("does nothing if there are no app launch jobs") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        expect(jobRunner.allJobInfo()).to(beEmpty())
                    }
                }
                
                // MARK: ------ by being notified of app becoming active
                context("by being notified of app becoming active") {
                    // MARK: -------- does not start a job before getting the app active call
                    it("does not start a job before getting the app active call") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beFalse())
                    }
                    
                    // MARK: -------- does not start the job queues if there are no app active jobs and blocking jobs are running
                    it("does not start the job queues if there are no app active jobs and blocking jobs are running") {
                        job1 = job1.with(details: TestDetails(completeTime: 2))
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .runOnceNextLaunch,
                            shouldBlock: true,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                            jobRunner.add(
                                db,
                                job: job2,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        // Not currently running
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beFalse())
                        
                        // Start the blocking job
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        
                        // Make sure the other queues don't start
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beFalse())
                    }
                    
                    // MARK: -------- does not start the job queues if there are app active jobs and blocking jobs are running
                    it("does not start the job queues if there are app active jobs and blocking jobs are running") {
                        job1 = Job(
                            id: 100,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .recurringOnActive,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 2))
                        )
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .runOnceNextLaunch,
                            shouldBlock: true,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                            jobRunner.add(
                                db,
                                job: job2,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        // Not currently running
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beFalse())
                        
                        // Start the blocking queue
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        
                        // Make sure the other queues don't start
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beFalse())
                    }
                    
                    // MARK: -------- starts the job queues if there are no app active jobs
                    it("starts the job queues if there are no app active jobs") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        // Make sure it isn't already started
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beFalse())
                        
                        // Make sure it starts after 'appDidBecomeActive' is called
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beTrue())
                    }
                    
                    // MARK: -------- starts the job queues if there are app active jobs
                    it("starts the job queues if there are app active jobs") {
                        job1 = Job(
                            id: 100,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .recurringOnActive,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .runOnce,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                            jobRunner.add(
                                db,
                                job: job2,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        // Not currently running
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beFalse())
                        expect(jobRunner.isCurrentlyRunning(job2)).to(beFalse())
                        
                        // Make sure the queues are started
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beTrue())
                        expect(jobRunner.isCurrentlyRunning(job2)).to(beTrue())
                    }
                    
                    // MARK: -------- starts the job queues after completing blocking app launch jobs
                    it("starts the job queues after completing blocking app launch jobs") {
                        job1 = job1.with(details: TestDetails(completeTime: 2))
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .runOnceNextLaunch,
                            shouldBlock: true,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try! JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                            jobRunner.add(
                                db,
                                job: job2,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        // Not currently running
                        expect(jobRunner.isCurrentlyRunning(job1))
                            .to(beFalse())
                        expect(jobRunner.isCurrentlyRunning(job2)).to(beFalse())
                        
                        // Make sure it starts
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        // Blocking job running but blocked job not
                        expect(jobRunner.isCurrentlyRunning(job2)).to(beTrue())
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beFalse())
                        
                        // Complete 'job2'
                        dependencies.stepForwardInTime()
                        
                        // Blocked job eventually starts
                        expect(jobRunner.isCurrentlyRunning(job2)).to(beFalse())
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beTrue())
                    }
                    
                    // MARK: -------- starts the job queues alongside non blocking app launch jobs
                    it("starts the job queues alongside non blocking app launch jobs") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .runOnceNextLaunch,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try! JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                            jobRunner.add(
                                db,
                                job: job2,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        // Not currently running
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beFalse())
                        expect(jobRunner.isCurrentlyRunning(job2)).to(beFalse())
                        
                        // Make sure it starts
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        expect(jobRunner.isCurrentlyRunning(job1)).to(beTrue())
                        expect(jobRunner.isCurrentlyRunning(job2)).to(beTrue())
                    }
                }
                
                // MARK: ------ by checking if a job can be added to the queue
                context("by checking if a job can be added to the queue") {
                    // MARK: -------- does not add a general job to the queue before launch
                    it("does not add a general job to the queue before launch") {
                        job1 = Job(
                            id: 100,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .runOnce,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        expect(jobRunner.allJobInfo()).to(beEmpty())
                    }
                    
                    // MARK: -------- adds a launch job to the queue in a pending state before launch
                    it("adds a launch job to the queue in a pending state before launch") {
                        job1 = Job(
                            id: 100,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .recurringOnLaunch,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        expect(Array(jobRunner.jobInfoFor(state: [.pending]).keys)).to(equal([100]))
                    }
                    
                    // MARK: -------- does not add a general job to the queue after launch but before becoming active
                    it("does not add a general job to the queue after launch but before becoming active") {
                        job1 = Job(
                            id: 100,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .runOnce,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        expect(jobRunner.allJobInfo()).to(beEmpty())
                    }
                    
                    // MARK: -------- adds a launch job to the queue in a pending state after launch but before becoming active
                    it("adds a launch job to the queue in a pending state after launch but before becoming active") {
                        job1 = Job(
                            id: 100,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .recurringOnLaunch,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        expect(Array(jobRunner.jobInfoFor(state: .pending).keys)).to(equal([100]))
                    }
                    
                    // MARK: -------- adds a general job to the queue after becoming active
                    it("adds a general job to the queue after becoming active") {
                        job1 = Job(
                            id: 100,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .runOnce,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        expect(Array(jobRunner.allJobInfo().keys)).to(equal([100]))
                    }
                    
                    // MARK: -------- adds a launch job to the queue and starts it after becoming active
                    it("adds a launch job to the queue and starts it after becoming active") {
                        job1 = Job(
                            id: 100,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .recurringOnLaunch,
                            shouldBlock: false,
                            shouldBeUnique: false,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        jobRunner.appDidFinishLaunching(using: dependencies)
                        jobRunner.appDidBecomeActive(using: dependencies)
                        
                        mockStorage.write { db in
                            jobRunner.add(
                                db,
                                job: job1,
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(equal([100]))
                    }
                }
            }
            
            // MARK: ---- when running jobs
            context("when running jobs") {
                beforeEach {
                    jobRunner.appDidFinishLaunching(using: dependencies)
                    jobRunner.appDidBecomeActive(using: dependencies)
                }
                
                // MARK: ------ by adding
                context("by adding") {
                    // MARK: -------- does not start until after the db transaction completes
                    it("does not start until after the db transaction completes") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        
                        mockStorage.write { db in
                            jobRunner.add(db, job: job1, canStartJob: true, using: dependencies)
                            
                            expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(beEmpty())
                        }
                        
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(equal([100]))
                    }
                    
                    // MARK: -------- does not add the job if it is unique and another already exists
                    it("does not add the job if it is unique and another already exists") {
                        job1 = Job(
                            id: 100,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .recurringOnLaunch,
                            shouldBlock: false,
                            shouldBeUnique: true,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        job2 = Job(
                            id: 101,
                            failureCount: 0,
                            variant: .messageSend,
                            behaviour: .recurringOnLaunch,
                            shouldBlock: false,
                            shouldBeUnique: true,
                            shouldSkipLaunchBecomeActive: false,
                            nextRunTimestamp: 0,
                            threadId: nil,
                            interactionId: nil,
                            details: try? JSONEncoder(using: dependencies)
                                .encode(TestDetails(completeTime: 1))
                        )
                        
                        var result1: Job?
                        var result2: Job?
                        
                        mockStorage.write { db in
                            result1 = jobRunner.add(db, job: job1, canStartJob: true, using: dependencies)
                            result2 = jobRunner.add(db, job: job2, canStartJob: true, using: dependencies)
                        }
                        
                        expect(result1).toNot(beNil())
                        expect(result2).to(beNil())
                    }
                }
                
                // MARK: ------ with job dependencies
                context("with job dependencies") {
                    // MARK: -------- starts dependencies first
                    it("starts dependencies first") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        job2 = job2.with(details: TestDetails(completeTime: 2))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            try JobDependencies(jobId: job1.id!, dependantId: job2.id!).insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, using: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.jobInfoFor(state: .running, variant: .attachmentUpload).keys))
                            .to(equal([101]))
                    }
                    
                    // MARK: -------- removes the initial job from the queue
                    it("removes the initial job from the queue") {
                        job1 = job1.with(details: TestDetails(completeTime: 1))
                        job2 = job2.with(details: TestDetails(completeTime: 2))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            try JobDependencies(jobId: job1.id!, dependantId: job2.id!).insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, using: dependencies)
                        }
                        
                        // Make sure the initial job is removed from the queue
                        expect(Array(jobRunner.jobInfoFor(state: .running, variant: .attachmentUpload).keys))
                            .to(equal([101]))
                        expect(jobRunner.jobInfoFor(state: .running, variant: .messageSend).keys).toNot(contain(100))
                    }
                    
                    // MARK: -------- starts the initial job when the dependencies succeed
                    it("starts the initial job when the dependencies succeed") {
                        job1 = job1.with(details: TestDetails(completeTime: 2))
                        job2 = job2.with(details: TestDetails(completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            try JobDependencies(jobId: job1.id!, dependantId: job2.id!).insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, using: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.jobInfoFor(state: .running, variant: .attachmentUpload).keys))
                            .to(equal([101]))
                        expect(jobRunner.jobInfoFor(state: .running, variant: .messageSend).keys).toNot(contain(100))
                        
                        // Make sure the initial job starts
                        dependencies.stepForwardInTime()
                        expect(Array(jobRunner.jobInfoFor(state: .running, variant: .messageSend).keys))
                            .to(equal([100]))
                    }
                    
                    // MARK: -------- does not start the initial job if the dependencies are deferred
                    it("does not start the initial job if the dependencies are deferred") {
                        job1 = job1.with(details: TestDetails(result: .failure, completeTime: 2))
                        job2 = job2.with(details: TestDetails(result: .deferred, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            try JobDependencies(jobId: job1.id!, dependantId: job2.id!).insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, using: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.jobInfoFor(state: .running, variant: .attachmentUpload).keys))
                            .to(equal([101]))
                        expect(jobRunner.jobInfoFor(state: .running, variant: .messageSend).keys).toNot(contain(100))
                        
                        // Make sure there are no running jobs
                        dependencies.stepForwardInTime()
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(beEmpty())
                    }
                    
                    // MARK: -------- does not start the initial job if the dependencies fail
                    it("does not start the initial job if the dependencies fail") {
                        job1 = job1.with(details: TestDetails(result: .failure, completeTime: 2))
                        job2 = job2.with(details: TestDetails(result: .failure, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            try JobDependencies(jobId: job1.id!, dependantId: job2.id!).insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, using: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.jobInfoFor(state: .running, variant: .attachmentUpload).keys))
                            .to(equal([101]))
                        expect(jobRunner.jobInfoFor(state: .running, variant: .messageSend).keys).toNot(contain(100))
                        
                        // Make sure there are no running jobs
                        dependencies.stepForwardInTime()
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(beEmpty())
                    }
                    
                    // MARK: -------- does not delete the initial job if the dependencies fail
                    it("does not delete the initial job if the dependencies fail") {
                        job1 = job1.with(details: TestDetails(result: .failure, completeTime: 2))
                        job2 = job2.with(details: TestDetails(result: .failure, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            try JobDependencies(jobId: job1.id!, dependantId: job2.id!).insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, using: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.jobInfoFor(state: .running, variant: .attachmentUpload).keys))
                            .to(equal([101]))
                        expect(jobRunner.jobInfoFor(state: .running, variant: .messageSend).keys).toNot(contain(100))
                        
                        // Make sure there are no running jobs
                        dependencies.stepForwardInTime()
                        expect(Array(jobRunner.jobInfoFor(state: .running, variant: .attachmentUpload).keys))
                            .to(beEmpty())
                        
                        // Stop the queues so it doesn't run out of retry attempts
                        jobRunner.stopAndClearPendingJobs(exceptForVariant: nil, using: dependencies, onComplete: nil)
                        
                        // Make sure the jobs still exist
                        expect(mockStorage.read { db in try Job.fetchCount(db) }).to(equal(2))
                    }
                    
                    // MARK: -------- deletes the initial job if the dependencies permanently fail
                    it("deletes the initial job if the dependencies permanently fail") {
                        job1 = job1.with(details: TestDetails(result: .failure, completeTime: 2))
                        job2 = job2.with(details: TestDetails(result: .permanentFailure, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            try job2.insert(db)
                            try JobDependencies(jobId: job1.id!, dependantId: job2.id!).insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, using: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.jobInfoFor(state: .running, variant: .attachmentUpload).keys))
                            .to(equal([101]))
                        expect(jobRunner.jobInfoFor(state: .running, variant: .messageSend).keys).toNot(contain(100))
                        
                        // Make sure there are no running jobs
                        dependencies.stepForwardInTime()
                        expect(Array(jobRunner.jobInfoFor(state: .running, variant: .attachmentUpload).keys))
                            .to(beEmpty())
                        
                        // Make sure the jobs were deleted
                        expect(mockStorage.read { db in try Job.fetchCount(db) }).to(equal(0))
                    }
                }
            }
            
            // MARK: ---- when completing jobs
            context("when completing jobs") {
                beforeEach {
                    jobRunner.appDidFinishLaunching(using: dependencies)
                    jobRunner.appDidBecomeActive(using: dependencies)
                }
                
                // MARK: ------ by succeeding
                context("by succeeding") {
                    // MARK: -------- removes the job from the queue
                    it("removes the job from the queue") {
                        job1 = job1.with(details: TestDetails(result: .success, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, using: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(equal([100]))
                        
                        // Make sure there are no running jobs
                        dependencies.stepForwardInTime()
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(beEmpty())
                    }
                    
                    // MARK: -------- deletes the job
                    it("deletes the job") {
                        job1 = job1.with(details: TestDetails(result: .success, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, using: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(equal([100]))
                        
                        // Make sure there are no running jobs
                        dependencies.stepForwardInTime()
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(beEmpty())
                        
                        // Make sure the jobs were deleted
                        expect(mockStorage.read { db in try Job.fetchCount(db) }).to(equal(0))
                    }
                }
                
                // MARK: ------ by deferring
                context("by deferring") {
                    // MARK: -------- reschedules the job to run again later
                    it("reschedules the job to run again later") {
                        job1 = job1.with(details: TestDetails(result: .deferred, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, using: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(equal([100]))
                        
                        // Make sure there are no running jobs
                        dependencies.stepForwardInTime()
                        expect(jobRunner.jobInfoFor(state: .running)).to(beEmpty())
                        expect {
                            mockStorage.read { db in try Job.select(.details).asRequest(of: Data.self).fetchOne(db) }
                        }.to(equal(
                            try! JSONEncoder(using: dependencies)
                                .encode(TestDetails(result: .deferred, completeTime: 3))
                        ))
                    }
                    
                    // MARK: -------- does not delete the job
                    it("does not delete the job") {
                        job1 = job1.with(details: TestDetails(result: .deferred, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, using: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(equal([100]))
                        
                        // Make sure there are no running jobs
                        dependencies.stepForwardInTime()
                        expect(jobRunner.jobInfoFor(state: .running)).to(beEmpty())
                        
                        // Make sure the jobs were deleted
                        expect(mockStorage.read { db in try Job.fetchCount(db) }).toNot(equal(0))
                    }
                    
                    // MARK: -------- fails the job if it is deferred too many times
                    it("fails the job if it is deferred too many times") {
                        job1 = job1.with(details: TestDetails(result: .deferred, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, using: dependencies)
                        }
                        
                        // Make sure it runs
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(equal([100]))
                        dependencies.stepForwardInTime()
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(beEmpty())
                        
                        // Progress the time
                        dependencies.stepForwardInTime()
                        
                        // Make sure it finishes once
                        expect(jobRunner.jobInfoFor(state: .running))
                            .to(equal([
                                100: JobRunner.JobInfo(
                                    variant: .messageSend,
                                    threadId: nil,
                                    interactionId: nil,
                                    detailsData: try! JSONEncoder(using: dependencies)
                                        .encode(TestDetails(result: .deferred, completeTime: 3)),
                                    uniqueHashValue: nil
                                )
                            ]))
                        dependencies.stepForwardInTime()
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(beEmpty())
                        
                        // Progress the time
                        dependencies.stepForwardInTime()
                        
                        // Make sure it finishes twice
                        expect(jobRunner.jobInfoFor(state: .running))
                            .to(equal([
                                100: JobRunner.JobInfo(
                                    variant: .messageSend,
                                    threadId: nil,
                                    interactionId: nil,
                                    detailsData: try! JSONEncoder(using: dependencies)
                                        .encode(TestDetails(result: .deferred, completeTime: 5)),
                                    uniqueHashValue: nil
                                )
                            ]))
                        dependencies.stepForwardInTime()
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(beEmpty())
                        
                        // Progress the time
                        dependencies.stepForwardInTime()
                        
                        // Make sure it's finishes the last time
                        expect(jobRunner.jobInfoFor(state: .running))
                            .to(equal([
                                100: JobRunner.JobInfo(
                                    variant: .messageSend,
                                    threadId: nil,
                                    interactionId: nil,
                                    detailsData: try! JSONEncoder(using: dependencies)
                                        .encode(TestDetails(result: .deferred, completeTime: 7)),
                                    uniqueHashValue: nil
                                )
                            ]))
                        dependencies.stepForwardInTime()
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(beEmpty())
                        
                        // Make sure the job was marked as failed
                        expect(mockStorage.read { db in try Job.fetchOne(db, id: 100)?.failureCount }).to(equal(1))
                    }
                }
                
                // MARK: ------ by failing
                context("by failing") {
                    // MARK: -------- removes the job from the queue
                    it("removes the job from the queue") {
                        job1 = job1.with(details: TestDetails(result: .failure, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, using: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(equal([100]))
                        
                        // Make sure there are no running jobs
                        dependencies.stepForwardInTime()
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(beEmpty())
                    }
                    
                    // MARK: -------- does not delete the job
                    it("does not delete the job") {
                        job1 = job1.with(details: TestDetails(result: .failure, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, using: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(equal([100]))
                        
                        // Make sure there are no running jobs
                        dependencies.stepForwardInTime()
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(beEmpty())
                        
                        // Make sure the jobs were deleted
                        expect(mockStorage.read { db in try Job.fetchCount(db) }).toNot(equal(0))
                    }
                }
                
                // MARK: ------ by permanently failing
                context("by permanently failing") {
                    // MARK: -------- removes the job from the queue
                    it("removes the job from the queue") {
                        job1 = job1.with(details: TestDetails(result: .permanentFailure, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, using: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(equal([100]))
                        
                        // Make sure there are no running jobs
                        dependencies.stepForwardInTime()
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(beEmpty())
                    }
                    
                    // MARK: -------- deletes the job
                    it("deletes the job") {
                        job1 = job1.with(details: TestDetails(result: .permanentFailure, completeTime: 1))
                        
                        mockStorage.write { db in
                            try job1.insert(db)
                            
                            jobRunner.upsert(db, job: job1, canStartJob: true, using: dependencies)
                        }
                        
                        // Make sure the dependency is run
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(equal([100]))
                        
                        // Make sure there are no running jobs
                        dependencies.stepForwardInTime()
                        expect(Array(jobRunner.jobInfoFor(state: .running).keys)).to(beEmpty())
                        
                        // Make sure the jobs were deleted
                        expect(mockStorage.read { db in try Job.fetchCount(db) }).to(equal(0))
                    }
                }
            }
        }
    }
}

// MARK: - Test Types

fileprivate struct TestDetails: Codable {
    enum ResultType: Codable {
        case success
        case failure
        case permanentFailure
        case deferred
    }
    
    public let result: ResultType
    public let completeTime: Int
    public let intValue: Int64
    public let stringValue: String
    
    init(
        result: ResultType = .success,
        completeTime: Int = 0,
        intValue: Int64 = 100,
        stringValue: String = "200"
    ) {
        self.result = result
        self.completeTime = completeTime
        self.intValue = intValue
        self.stringValue = stringValue
    }
}

fileprivate struct InvalidDetails: Codable {
    func encode(to encoder: Encoder) throws { throw HTTPError.parsingFailed }
}

fileprivate enum TestJob: JobExecutor {
    static let maxFailureCount: Int = 1
    static let requiresThreadId: Bool = false
    static let requiresInteractionId: Bool = false
    
    static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies
    ) {
        guard
            let detailsData: Data = job.details,
            let details: TestDetails = try? JSONDecoder().decode(TestDetails.self, from: detailsData)
        else { return success(job, true, dependencies) }
        
        let completeJob: () -> () = {
            // Need to increase the 'completeTime' and 'nextRunTimestamp' to prevent the job
            // from immediately being run again or immediately completing afterwards
            let updatedJob: Job = job
                .with(nextRunTimestamp: TimeInterval(details.completeTime + 1))
                .with(
                    details: TestDetails(
                        result: details.result,
                        completeTime: (details.completeTime + 2),
                        intValue: details.intValue,
                        stringValue: details.stringValue
                    )
                )!
            dependencies[singleton: .storage].write { db in try updatedJob.upserted(db) }
            
            switch details.result {
                case .success: success(job, true, dependencies)
                case .failure: failure(job, nil, false, dependencies)
                case .permanentFailure: failure(job, nil, true, dependencies)
                case .deferred: deferred(updatedJob, dependencies)
            }
        }
        
        guard dependencies.fixedTime < details.completeTime else {
            return queue.async(using: dependencies) {
                completeJob()
            }
        }
        
        dependencies.async(at: details.completeTime) {
            queue.async(using: dependencies) {
                completeJob()
            }
        }
    }
}

// MARK: - Unit Test Convenience

fileprivate extension JobRunner {
    convenience init(
        isTestingJobRunner: Bool = false,
        variantsToExclude: [Job.Variant] = [],
        executors: [Job.Variant: JobExecutor.Type],
        using dependencies: Dependencies
    ) {
        self.init(
            isTestingJobRunner: isTestingJobRunner,
            variantsToExclude: variantsToExclude,
            using: dependencies
        )
        
        executors.forEach { variant, executor in self.setExecutor(executor, for: variant) }
    }
}
