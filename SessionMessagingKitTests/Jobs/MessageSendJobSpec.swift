// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

import Quick
import Nimble

@testable import SessionMessagingKit
@testable import SessionUtilitiesKit

extension Job: @retroactive MutableIdentifiable {
    public mutating func setId(_ id: Int64?) { self.id = id }
}

class MessageSendJobSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var job: Job!
        @TestState var interaction: Interaction!
        @TestState var attachment: Attachment! = Attachment(
            id: "200",
            variant: .standard,
            state: .failedDownload,
            contentType: "text/plain",
            byteCount: 200
        )
        @TestState var interactionAttachment: InteractionAttachment!
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
        }
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrationTargets: [
                SNUtilitiesKit.self,
                SNMessagingKit.self
            ],
            using: dependencies,
            initialData: { db in
                try SessionThread.fetchOrCreate(
                    db,
                    id: "Test1",
                    variant: .contact,
                    creationDateTimestamp: 1234567890,
                    shouldBeVisible: true,
                    calledFromConfig: nil,
                    using: dependencies
                )
            }
        )
        @TestState(singleton: .jobRunner, in: dependencies) var mockJobRunner: MockJobRunner! = MockJobRunner(
            initialSetup: { jobRunner in
                jobRunner
                    .when {
                        $0.jobInfoFor(
                            jobs: nil,
                            state: .running,
                            variant: .attachmentUpload
                        )
                    }
                    .thenReturn([:])
                jobRunner
                    .when { $0.insert(.any, job: .any, before: .any) }
                    .then { args, untrackedArgs in
                        let db: Database = untrackedArgs[0] as! Database
                        var job: Job = args[0] as! Job
                        job.id = 1000
                        
                        try! job.insert(db)
                    }
                    .thenReturn((1000, Job(variant: .messageSend)))
            }
        )
        
        // MARK: - a MessageSendJob
        describe("a MessageSendJob") {
            // MARK: -- fails when not given any details
            it("fails when not given any details") {
                job = Job(variant: .messageSend)
                
                var error: Error? = nil
                var permanentFailure: Bool = false
                
                MessageSendJob.run(
                    job,
                    queue: .main,
                    success: { _, _ in },
                    failure: { _, runError, runPermanentFailure in
                        error = runError
                        permanentFailure = runPermanentFailure
                    },
                    deferred: { _ in },
                    using: dependencies
                )
                
                expect(error).to(matchError(JobRunnerError.missingRequiredDetails))
                expect(permanentFailure).to(beTrue())
            }
            
            // MARK: -- fails when given incorrect details
            it("fails when given incorrect details") {
                job = Job(
                    variant: .messageSend,
                    details: MessageReceiveJob.Details(
                        messages: [MessageReceiveJob.Details.MessageInfo]()
                    )
                )
                
                var error: Error? = nil
                var permanentFailure: Bool = false
                
                MessageSendJob.run(
                    job,
                    queue: .main,
                    success: { _, _ in },
                    failure: { _, runError, runPermanentFailure in
                        error = runError
                        permanentFailure = runPermanentFailure
                    },
                    deferred: { _ in },
                    using: dependencies
                )
                
                expect(error).to(matchError(JobRunnerError.missingRequiredDetails))
                expect(permanentFailure).to(beTrue())
            }
            
            // MARK: -- of VisibleMessage
            context("of VisibleMessage") {
                beforeEach {
                    interaction = Interaction(
                        id: 100,
                        serverHash: nil,
                        messageUuid: nil,
                        threadId: "Test1",
                        authorId: "Test",
                        variant: .standardOutgoing,
                        body: "Test",
                        timestampMs: 1234567890,
                        receivedAtTimestampMs: 1234567900,
                        wasRead: false,
                        hasMention: false,
                        expiresInSeconds: nil,
                        expiresStartedAtMs: nil,
                        linkPreviewUrl: nil,
                        openGroupServerMessageId: nil,
                        openGroupWhisperMods: false,
                        openGroupWhisperTo: nil,
                        transientDependencies: nil
                    )
                    job = Job(
                        variant: .messageSend,
                        interactionId: interaction.id!,
                        details: MessageSendJob.Details(
                            destination: .contact(publicKey: "Test"),
                            message: VisibleMessage(
                                text: "Test"
                            )
                        )
                    )
                    
                    mockStorage.write { db in
                        try interaction.insert(db)
                        try job.insert(db, withRowId: 54321)
                    }
                }
                
                // MARK: ---- fails when there is no job id
                it("fails when there is no job id") {
                    job = Job(
                        variant: .messageSend,
                        interactionId: interaction.id!,
                        details: MessageSendJob.Details(
                            destination: .contact(publicKey: "Test"),
                            message: VisibleMessage(
                                text: "Test"
                            )
                        )
                    )
                    
                    var error: Error? = nil
                    var permanentFailure: Bool = false
                    
                    MessageSendJob.run(
                        job,
                        queue: .main,
                        success: { _, _ in },
                        failure: { _, runError, runPermanentFailure in
                            error = runError
                            permanentFailure = runPermanentFailure
                        },
                        deferred: { _ in },
                        using: dependencies
                    )
                    
                    expect(error).to(matchError(JobRunnerError.missingRequiredDetails))
                    expect(permanentFailure).to(beTrue())
                }
                
                // MARK: ---- fails when there is no interaction id
                it("fails when there is no interaction id") {
                    job = Job(
                        variant: .messageSend,
                        details: MessageSendJob.Details(
                            destination: .contact(publicKey: "Test"),
                            message: VisibleMessage(
                                text: "Test"
                            )
                        )
                    )
                    
                    var error: Error? = nil
                    var permanentFailure: Bool = false
                    
                    MessageSendJob.run(
                        job,
                        queue: .main,
                        success: { _, _ in },
                        failure: { _, runError, runPermanentFailure in
                            error = runError
                            permanentFailure = runPermanentFailure
                        },
                        deferred: { _ in },
                        using: dependencies
                    )
                    
                    expect(error).to(matchError(JobRunnerError.missingRequiredDetails))
                    expect(permanentFailure).to(beTrue())
                }
                
                // MARK: ---- fails when there is no interaction for the provided interaction id
                it("fails when there is no interaction for the provided interaction id") {
                    job = Job(
                        variant: .messageSend,
                        interactionId: 12345,
                        details: MessageSendJob.Details(
                            destination: .contact(publicKey: "Test"),
                            message: VisibleMessage(
                                text: "Test"
                            )
                        )
                    )
                    mockStorage.write { db in try job.insert(db, withRowId: 54321) }
                    
                    var error: Error? = nil
                    var permanentFailure: Bool = false
                    
                    MessageSendJob.run(
                        job,
                        queue: .main,
                        success: { _, _ in },
                        failure: { _, runError, runPermanentFailure in
                            error = runError
                            permanentFailure = runPermanentFailure
                        },
                        deferred: { _ in },
                        using: dependencies
                    )
                    
                    expect(error).to(matchError(StorageError.objectNotFound))
                    expect(permanentFailure).to(beTrue())
                }
                
                // MARK: ---- with an attachment
                context("with an attachment") {
                    beforeEach {
                        interactionAttachment = InteractionAttachment(
                            albumIndex: 0,
                            interactionId: interaction.id!,
                            attachmentId: attachment.id
                        )
                        
                        mockStorage.write { db in
                            try attachment.insert(db)
                            try interactionAttachment.insert(db)
                        }
                    }
                    
                    // MARK: ------ it fails when trying to send with an attachment which previously failed to download
                    it("it fails when trying to send with an attachment which previously failed to download") {
                        mockStorage.write { db in
                            try attachment.with(state: .failedDownload, using: dependencies).upsert(db)
                        }
                        
                        var error: Error? = nil
                        var permanentFailure: Bool = false
                        
                        MessageSendJob.run(
                            job,
                            queue: .main,
                            success: { _, _ in },
                            failure: { _, runError, runPermanentFailure in
                                error = runError
                                permanentFailure = runPermanentFailure
                            },
                            deferred: { _ in },
                            using: dependencies
                        )
                        
                        expect(error).to(matchError(AttachmentError.notUploaded))
                        expect(permanentFailure).to(beTrue())
                    }
                    
                    // MARK: ------ with a pending upload
                    context("with a pending upload") {
                        beforeEach {
                            mockStorage.write { db in
                                try attachment.with(state: .uploading, using: dependencies).upsert(db)
                            }
                        }
                        
                        // MARK: -------- it defers when trying to send with an attachment which is still pending upload
                        it("it defers when trying to send with an attachment which is still pending upload") {
                            var didDefer: Bool = false
                            
                            mockStorage.write { db in
                                try attachment.with(state: .uploading, using: dependencies).upsert(db)
                            }
                            
                            MessageSendJob.run(
                                job,
                                queue: .main,
                                success: { _, _ in },
                                failure: { _, _, _ in },
                                deferred: { _ in didDefer = true },
                                using: dependencies
                            )
                            
                            expect(didDefer).to(beTrue())
                        }
                        
                        // MARK: -------- it defers when trying to send with an uploaded attachment that has an invalid downloadUrl
                        it("it defers when trying to send with an uploaded attachment that has an invalid downloadUrl") {
                            var didDefer: Bool = false
                            
                            mockStorage.write { db in
                                try attachment
                                    .with(
                                        state: .uploaded,
                                        downloadUrl: nil,
                                        using: dependencies
                                    )
                                    .upsert(db)
                            }
                            
                            MessageSendJob.run(
                                job,
                                queue: .main,
                                success: { _, _ in },
                                failure: { _, _, _ in },
                                deferred: { _ in didDefer = true },
                                using: dependencies
                            )
                            
                            expect(didDefer).to(beTrue())
                        }
                        
                        // MARK: -------- inserts an attachment upload job before the message send job
                        it("inserts an attachment upload job before the message send job") {
                            mockJobRunner
                                .when {
                                    $0.jobInfoFor(
                                        jobs: nil,
                                        state: .running,
                                        variant: .attachmentUpload
                                    )
                                }
                                .thenReturn([:])
                            
                            MessageSendJob.run(
                                job,
                                queue: .main,
                                success: { _, _ in },
                                failure: { _, _, _ in },
                                deferred: { _ in },
                                using: dependencies
                            )
                            
                            expect(mockJobRunner)
                                .to(call(.exactly(times: 1), matchingParameters: .all) {
                                    $0.insert(
                                        .any,
                                        job: Job(
                                            variant: .attachmentUpload,
                                            behaviour: .runOnce,
                                            shouldBlock: false,
                                            shouldSkipLaunchBecomeActive: false,
                                            interactionId: 100,
                                            details: AttachmentUploadJob.Details(
                                                messageSendJobId: 54321,
                                                attachmentId: "200"
                                            )
                                        ),
                                        before: job
                                    )
                                })
                        }
                        
                        // MARK: -------- creates a dependency between the new job and the existing one
                        it("creates a dependency between the new job and the existing one") {
                            MessageSendJob.run(
                                job,
                                queue: .main,
                                success: { _, _ in },
                                failure: { _, _, _ in },
                                deferred: { _ in },
                                using: dependencies
                            )
                            
                            expect(mockStorage.read { db in try JobDependencies.fetchOne(db) })
                                .to(equal(JobDependencies(jobId: 54321, dependantId: 1000)))
                        }
                    }
                }
            }
        }
    }
}
