// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
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
            Log.error("[MessageSendJob] Failing due to missing details")
            return failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
        }
        
        // We need to include 'fileIds' when sending messages with attachments to Open Groups
        // so extract them from any associated attachments
        var messageFileIds: [String] = []
        
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
                Log.error("[MessageSendJob] Failing due to missing details")
                return failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
            }
            
            // Retrieve the current attachment state
            typealias AttachmentState = (error: Error?, pendingUploadAttachmentIds: [String], preparedFileIds: [String])

            let attachmentState: AttachmentState = dependencies.storage
                .read { db in
                    // If the original interaction no longer exists then don't bother sending the message (ie. the
                    // message was deleted before it even got sent)
                    guard try Interaction.exists(db, id: interactionId) else {
                        Log.warn("[MessageSendJob] Failing due to missing interaction")
                        return (StorageError.objectNotFound, [], [])
                    }

                    // Get the current state of the attachments
                    let allAttachmentStateInfo: [Attachment.StateInfo] = try Attachment
                        .stateInfo(interactionId: interactionId)
                        .fetchAll(db)
                    let maybeFileIds: [String?] = allAttachmentStateInfo
                        .sorted { lhs, rhs in lhs.albumIndex < rhs.albumIndex }
                        .map { Attachment.fileId(for: $0.downloadUrl) }
                    let fileIds: [String] = maybeFileIds.compactMap { $0 }

                    // If there were failed attachments then this job should fail (can't send a
                    // message which has associated attachments if the attachments fail to upload)
                    guard !allAttachmentStateInfo.contains(where: { $0.state == .failedDownload }) else {
                        Log.info("[MessageSendJob] Failing due to failed attachment upload")
                        return (AttachmentError.notUploaded, [], fileIds)
                    }

                    /// Find all attachmentIds for attachments which need to be uploaded
                    ///
                    /// **Note:** If there are any 'downloaded' attachments then they also need to be uploaded (as a
                    /// 'downloaded' attachment will be on the current users device but not on the message recipients
                    /// device - both `LinkPreview` and `Quote` can have this case)
                    let pendingUploadAttachmentIds: [String] = allAttachmentStateInfo
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
                        .map { $0.attachmentId }
                    
                    return (nil, pendingUploadAttachmentIds, fileIds)
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

                Log.info("[MessageSendJob] Deferring due to pending attachment uploads")
                return deferred(job, dependencies)
            }

            // Store the fileIds so they can be sent with the open group message content
            messageFileIds = attachmentState.preparedFileIds
        }
        
        // Store the sentTimestamp from the message in case it fails due to a clockOutOfSync error
        let originalSentTimestamp: UInt64? = details.message.sentTimestamp
        let startTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        
        /// Perform the actual message sending - this will timeout if the entire process takes longer than `HTTP.defaultTimeout * 2`
        /// which can occur if it needs to build a new onion path (which doesn't actually have any limits so can take forever in rare cases)
        ///
        /// **Note:** No need to upload attachments as part of this process as the above logic splits that out into it's own job
        /// so we shouldn't get here until attachments have already been uploaded
        dependencies.storage
            .writePublisher { db in
                try MessageSender.preparedSendData(
                    db,
                    message: details.message,
                    to: details.destination,
                    namespace: details.destination.defaultNamespace,
                    interactionId: job.interactionId,
                    using: dependencies
                )
            }
            .map { sendData in sendData.with(fileIds: messageFileIds) }
            .flatMap { MessageSender.sendImmediate(data: $0, using: dependencies) }
            .subscribe(on: queue, using: dependencies)
            .receive(on: queue, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished:
                            Log.info("[MessageSendJob] Completed sending \(type(of: details.message)) after \(.seconds(dependencies.dateNow.timeIntervalSince1970 - startTime), unit: .s).")
                            success(job, false, dependencies)
                            
                        case .failure(let error):
                            Log.info("[MessageSendJob] Failed to send \(type(of: details.message)) after \(.seconds(dependencies.dateNow.timeIntervalSince1970 - startTime), unit: .s) due to error: \(error).")
                            
                            // Actual error handling
                            switch (error, details.message) {
                                case (let senderError as MessageSenderError, _) where !senderError.isRetryable:
                                    failure(job, error, true, dependencies)
                                    
                                case (SnodeAPIError.rateLimited, _):
                                    failure(job, error, true, dependencies)
                                    
                                case (SnodeAPIError.clockOutOfSync, _):
                                    Log.error("[MessageSendJob] \(originalSentTimestamp != nil ? "Permanently Failing" : "Failing") to send \(type(of: details.message)) due to clock out of sync issue.")
                                    failure(job, error, (originalSentTimestamp != nil), dependencies)
                                    
                                // Don't bother retrying (it can just send a new one later but allowing retries
                                // can result in a large number of `MessageSendJobs` backing up)
                                case (_, is TypingIndicator):
                                    failure(job, error, true, dependencies)
                                    
                                default:
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
            @available(*, deprecated, message: "replaced by 'Message.Destination.syncMessage'") case isSyncMessage
            case variant
        }
        
        public let destination: Message.Destination
        public let message: Message
        public let variant: Message.Variant?
        
        // MARK: - Initialization
        
        public init(
            destination: Message.Destination,
            message: Message
        ) {
            self.destination = destination
            self.message = message
            self.variant = Message.Variant(from: message)
        }
        
        // MARK: - Codable
        
        public init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            guard let variant: Message.Variant = try? container.decode(Message.Variant.self, forKey: .variant) else {
                SNLog("Unable to decode messageSend job due to missing variant")
                throw StorageError.decodingFailed
            }
            
            let message: Message = try variant.decode(from: container, forKey: .message)
            var destination: Message.Destination = try container.decode(Message.Destination.self, forKey: .destination)
            
            /// Handle the legacy 'isSyncMessage' flag - this flag was deprecated in `2.5.2` (April 2024) and can be removed in a
            /// subsequent release after May 2024
            if ((try? container.decode(Bool.self, forKey: .isSyncMessage)) ?? false) {
                switch (destination, message) {
                    case (.contact, let message as VisibleMessage):
                        guard let targetPublicKey: String = message.syncTarget else {
                            SNLog("Unable to decode messageSend job due to missing syncTarget")
                            throw StorageError.decodingFailed
                        }
                        
                        destination = .syncMessage(originalRecipientPublicKey: targetPublicKey)
                        
                    case (.contact, let message as ExpirationTimerUpdate):
                        guard let targetPublicKey: String = message.syncTarget else {
                            SNLog("Unable to decode messageSend job due to missing syncTarget")
                            throw StorageError.decodingFailed
                        }
                        
                        destination = .syncMessage(originalRecipientPublicKey: targetPublicKey)
                        
                    case (.contact(let publicKey), _):
                        SNLog("Sync message in messageSend job was missing explicit syncTarget (falling back to specified value)")
                        destination = .syncMessage(originalRecipientPublicKey: publicKey)
                        
                    default:
                        SNLog("Unable to decode messageSend job due to invalid sync message state")
                        throw StorageError.decodingFailed
                }
            }
            
            self = Details(
                destination: destination,
                message: message
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
            try container.encode(variant, forKey: .variant)
        }
    }
}
