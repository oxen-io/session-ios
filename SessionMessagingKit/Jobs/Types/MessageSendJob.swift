// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SignalCoreKit
import SessionUtilitiesKit
import SessionSnodeKit

public enum MessageSendJob: JobExecutor {
    public static var maxFailureCount: Int = 10
    public static var requiresThreadId: Bool = true
    public static let requiresInteractionId: Bool = false   // Some messages don't have interactions
    
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
            let details: Details = try? JSONDecoder().decode(Details.self, from: detailsData)
        else {
            SNLog("[MessageSendJob] Failing due to missing details")
            return failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
        }
        
        /// We need to provide the `PreparedUpload` instances when sending messages so extract them when relevant
        var preparedAttachments: [Attachment.PreparedUpload] = []
        
        /// Ensure any associated attachments have already been uploaded before sending the message
        ///
        /// **Note:** Reactions reference their original message so we need to ignore this logic for reaction messages to ensure we don't
        /// incorrectly re-upload incoming attachments that the user reacted to, we also want to exclude "sync" messages since they should
        /// already have attachments in a valid state
        if
            details.message is VisibleMessage,
            (details.message as? VisibleMessage)?.reaction == nil
        {
            guard
                let jobId: Int64 = job.id,
                let interactionId: Int64 = job.interactionId
            else {
                SNLog("[MessageSendJob] Failing due to missing details")
                return failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
            }
            
            // Retrieve the current attachment state
            typealias AttachmentState = (
                error: Error?,
                pendingUploadAttachmentIds: [String],
                preparedAttachments: [Attachment.PreparedUpload]
            )

            let attachmentState: AttachmentState = dependencies.storage
                .read { db -> (Error?, [String], [Attachment.PreparedUpload]) in
                    // If the original interaction no longer exists then don't bother sending the message (ie. the
                    // message was deleted before it even got sent)
                    guard try Interaction.exists(db, id: interactionId) else {
                        SNLog("[MessageSendJob] Failing due to missing interaction")
                        return (StorageError.objectNotFound, [], [])
                    }
                    
                    // Get all attachments
                    let allAttachments: [Attachment] = try Attachment.fetchAll(db, interactionId: interactionId)
                    
                    // If there were failed attachments then this job should fail (can't send a
                    // message which has associated attachments if the attachments fail to upload)
                    guard !allAttachments.contains(where: { $0.state == .failedDownload }) else {
                        SNLog("[MessageSendJob] Failing due to failed attachment upload")
                        return (AttachmentError.notUploaded, [], [])
                    }

                    /// Find all attachmentIds for attachments which need to be uploaded
                    ///
                    /// **Note:** If there are any 'downloaded' attachments then they also need to be uploaded (as a
                    /// 'downloaded' attachment will be on the current users device but not on the message recipients
                    /// device - both `LinkPreview` and `Quote` can have this case)
                    let pendingUploadAttachmentIds: [String] = allAttachments
                        .filter { attachment -> Bool in
                            // Non-media quotes won't have thumbnails so so don't try to upload them
                            guard attachment.downloadUrl != Attachment.nonMediaQuoteFileId else { return false }

                            switch attachment.state {
                                case .uploading, .pendingDownload, .downloading, .failedUpload, .downloaded:
                                    return true
                                    
                                // If we've somehow got an attachment that is in an 'uploaded' state but doesn't
                                // have a 'downloadUrl' then it's invalid and needs to be re-uploaded
                                case .uploaded: return (attachment.downloadUrl == nil)

                                default: return false
                            }
                        }
                        .map { $0.id }
                    
                    /// Check if there are any remaining attachments before continuing (can early out if not)
                    let remainingAttachments: [Attachment] = allAttachments
                        .filter { !pendingUploadAttachmentIds.contains($0.id) }
                    
                    guard !remainingAttachments.isEmpty else { return (nil, pendingUploadAttachmentIds, []) }
                    
                    /// Get the proper upload destination (in case we change the logic in the future to upload as part of this job)
                    let maybeUploadDestination: Attachment.PreparedUpload.Destination? = {
                        switch details.destination {
                            case .openGroup(let roomToken, let server, _, _, _):
                                let openGroupId: String = OpenGroup.idFor(roomToken: roomToken, server: server)
                                
                                return (try? OpenGroup.fetchOne(db, id: openGroupId))
                                    .map { .community($0) }
                                
                            default: return .fileServer
                        }
                    }()
                    
                    guard let uploadDestination: Attachment.PreparedUpload.Destination = maybeUploadDestination else {
                        SNLog("[MessageSendJob] Failing due to invalid attachment upload destination")
                        return (AttachmentError.invalidDestination, [], [])
                    }
                    
                    /// Generate `Attachment.PreparedUpload` instances for the attachments which have already been
                    /// uploaded (this means we can use a consistent type in the codebase but will skip the encryption step
                    /// since they are already encrypted)
                    let preparedAttachments: [Attachment.PreparedUpload] = try remainingAttachments
                        .map { try Attachment.PreparedUpload(db, attachment: $0, destination: uploadDestination) }
                    
                    return (nil, pendingUploadAttachmentIds, preparedAttachments)
                }
                .defaulting(to: (MessageSenderError.invalidMessage, [], []))

            /// If we got an error when trying to retrieve the attachment state then this job is actually invalid so it
            /// should permanently fail
            guard attachmentState.error == nil else {
                return failure(job, (attachmentState.error ?? MessageSenderError.invalidMessage), true, dependencies)
            }

            /// If we have any pending (or failed) attachment uploads then we should create jobs for them and insert them into the
            /// queue before the current job and defer it (this will mean the current job will re-run after these inserted jobs complete)
            guard attachmentState.pendingUploadAttachmentIds.isEmpty else {
                dependencies.storage.write { db in
                    try attachmentState.pendingUploadAttachmentIds
                        .filter { attachmentId in
                            // Don't add a new job if there is one already in the queue
                            !dependencies.jobRunner.hasJob(
                                of: .attachmentUpload,
                                with: AttachmentUploadJob.Details(
                                    messageSendJobId: jobId,
                                    attachmentId: attachmentId
                                )
                            )
                        }
                        .compactMap { attachmentId -> (jobId: Int64, job: Job)? in
                            dependencies.jobRunner
                                .insert(
                                    db,
                                    job: Job(
                                        variant: .attachmentUpload,
                                        behaviour: .runOnce,
                                        threadId: job.threadId,
                                        interactionId: interactionId,
                                        details: AttachmentUploadJob.Details(
                                            messageSendJobId: jobId,
                                            attachmentId: attachmentId
                                        )
                                    ),
                                    before: job
                                )
                        }
                        .forEach { otherJobId, _ in
                            // Create the dependency between the jobs
                            try JobDependencies(
                                jobId: jobId,
                                dependantId: otherJobId
                            )
                            .insert(db)
                        }
                }

                SNLog("[MessageSendJob] Deferring due to pending attachment uploads")
                return deferred(job, dependencies)
            }

            // Store the fileIds so they can be sent with the open group message content
            preparedAttachments = attachmentState.preparedAttachments
        }
        
        // Store the sentTimestamp from the message in case it fails due to a clockOutOfSync error
        let originalSentTimestamp: UInt64? = details.message.sentTimestamp
        
        /// Perform the actual message sending
        ///
        /// **Note:** No need to upload attachments as part of this process as the above logic splits that out into it's own job
        /// so we shouldn't get here until attachments have already been uploaded
        dependencies.storage
            .writePublisher { db in
                try MessageSender.preparedSendData(
                    db,
                    message: details.message,
                    preparedAttachments: preparedAttachments,
                    to: details.destination,
                    namespace: details.destination.defaultNamespace,
                    interactionId: job.interactionId,
                    isSyncMessage: details.isSyncMessage,
                    using: dependencies
                )
            }
            .flatMap { MessageSender.sendImmediate(data: $0, using: dependencies) }
            .subscribe(on: queue, using: dependencies)
            .receive(on: queue, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: success(job, false, dependencies)
                        case .failure(let error):
                            SNLog("[MessageSendJob] Couldn't send message due to error: \(error).")
                            
                            switch error {
                                case let senderError as MessageSenderError where !senderError.isRetryable:
                                    failure(job, error, true, dependencies)
                                    
                                case OnionRequestAPIError.httpRequestFailedAtDestination(let statusCode, _, _) where statusCode == 429: // Rate limited
                                    failure(job, error, true, dependencies)
                                    
                                case SnodeAPIError.clockOutOfSync:
                                    SNLog("[MessageSendJob] \(originalSentTimestamp != nil ? "Permanently Failing" : "Failing") to send \(type(of: details.message)) due to clock out of sync issue.")
                                    failure(job, error, (originalSentTimestamp != nil), dependencies)
                                    
                                default:
                                    SNLog("[MessageSendJob] Failed to send \(type(of: details.message)).")
                                    
                                    if details.message is VisibleMessage {
                                        guard
                                            let interactionId: Int64 = job.interactionId,
                                            dependencies.storage.read({ db in try Interaction.exists(db, id: interactionId) }) == true
                                        else {
                                            // The message has been deleted so permanently fail the job
                                            return failure(job, error, true, dependencies)
                                        }
                                    }
                                    
                                    failure(job, error, false, dependencies)
                            }
                    }
                }
            )
    }
}

// MARK: - MessageSendJob.Details

extension MessageSendJob {
    public struct Details: Codable {
        private enum CodingKeys: String, CodingKey {
            case destination
            case message
            case isSyncMessage
            case variant
        }
        
        public let destination: Message.Destination
        public let message: Message
        public let isSyncMessage: Bool
        public let variant: Message.Variant?
        
        // MARK: - Initialization
        
        public init(
            destination: Message.Destination,
            message: Message,
            isSyncMessage: Bool = false
        ) {
            self.destination = destination
            self.message = message
            self.isSyncMessage = isSyncMessage
            self.variant = Message.Variant(from: message)
        }
        
        // MARK: - Codable
        
        public init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            guard let variant: Message.Variant = try? container.decode(Message.Variant.self, forKey: .variant) else {
                SNLog("Unable to decode messageSend job due to missing variant")
                throw StorageError.decodingFailed
            }
            
            self = Details(
                destination: try container.decode(Message.Destination.self, forKey: .destination),
                message: try variant.decode(from: container, forKey: .message),
                isSyncMessage: ((try? container.decode(Bool.self, forKey: .isSyncMessage)) ?? false)
            )
        }
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            guard let variant: Message.Variant = Message.Variant(from: message) else {
                SNLog("Unable to encode messageSend job due to unsupported variant")
                throw StorageError.objectNotFound
            }

            try container.encode(destination, forKey: .destination)
            try container.encode(message, forKey: .message)
            try container.encode(isSyncMessage, forKey: .isSyncMessage)
            try container.encode(variant, forKey: .variant)
        }
    }
}
