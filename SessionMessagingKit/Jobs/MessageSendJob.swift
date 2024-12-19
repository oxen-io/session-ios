// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("MessageSendJob", defaultLevel: .info)
}

// MARK: - MessageSendJob

public enum MessageSendJob: JobExecutor {
    public static var maxFailureCount: Int = 10
    public static var requiresThreadId: Bool = true
    public static let requiresInteractionId: Bool = false   // Some messages don't have interactions
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { return failure(job, JobRunnerError.missingRequiredDetails, true) }
        
        /// We need to include `fileIds` when sending messages with attachments to Open Groups so extract them from any
        /// associated attachments
        var messageFileIds: [String] = []
        let messageType: String = {
            switch details.destination {
                case .syncMessage: return "\(type(of: details.message)) (SyncMessage)"
                default: return "\(type(of: details.message))"
            }
        }()
        
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
            else { return failure(job, JobRunnerError.missingRequiredDetails, true) }
            
            // Retrieve the current attachment state
            typealias AttachmentState = (error: Error?, pendingUploadAttachmentIds: [String], preparedFileIds: [String])

            let attachmentState: AttachmentState = dependencies[singleton: .storage]
                .read { db in
                    // If the original interaction no longer exists then don't bother sending the message (ie. the
                    // message was deleted before it even got sent)
                    guard try Interaction.exists(db, id: interactionId) else {
                        Log.warn(.cat, "Failing \(messageType) (\(job.id ?? -1)) due to missing interaction")
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
                        Log.info(.cat, "Failing \(messageType) (\(job.id ?? -1)) due to failed attachment upload")
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
                Log.error(.cat, "Failed \(messageType) (\(job.id ?? -1)) due to invalid attachment state")
                return failure(job, (attachmentState.error ?? MessageSenderError.invalidMessage), true)
            }

            /// If we have any pending (or failed) attachment uploads then we should create jobs for them and insert them into the
            /// queue before the current job and defer it (this will mean the current job will re-run after these inserted jobs complete)
            guard attachmentState.pendingUploadAttachmentIds.isEmpty else {
                dependencies[singleton: .storage].write { db in
                    try attachmentState.pendingUploadAttachmentIds
                        .filter { attachmentId in
                            // Don't add a new job if there is one already in the queue
                            !dependencies[singleton: .jobRunner].hasJob(
                                of: .attachmentUpload,
                                with: AttachmentUploadJob.Details(
                                    messageSendJobId: jobId,
                                    attachmentId: attachmentId
                                )
                            )
                        }
                        .compactMap { attachmentId -> (jobId: Int64, job: Job)? in
                            dependencies[singleton: .jobRunner]
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

                Log.info(.cat, "Deferring \(messageType) (\(job.id ?? -1)) due to pending attachment uploads")
                return deferred(job)
            }

            // Store the fileIds so they can be sent with the open group message content
            messageFileIds = attachmentState.preparedFileIds
        }
        
        /// If this message is being sent to an updated group then we should first make sure that we have a encryption keys
        /// for the group before we try to send the message, if not then defer the job 1 second to give the poller the chance to
        /// receive the keys
        ///
        /// **Note:** If we have already deferred this message once then we should only continue to defer if we have a config
        /// for the message (this way we won't get stuck deferring permanently if config state isn't loaded and we will instead try,
        /// and fail, to send the message)
        var previousDeferralsMessage: String = ""
        
        switch details.destination {
            case .closedGroup(let groupPublicKey) where groupPublicKey.starts(with: SessionId.Prefix.group.rawValue):
                let deferalDuration: TimeInterval = 1
                let groupSessionId: SessionId = SessionId(.group, hex: groupPublicKey)
                let numGroupKeys: Int = (try? LibSession.numKeys(groupSessionId: groupSessionId, using: dependencies))
                    .defaulting(to: 0)
                let deferCount: Int = dependencies[singleton: .jobRunner].deferCount(for: job.id, of: job.variant)
                previousDeferralsMessage = " and \(.seconds(Double(deferCount) * deferalDuration), unit: .s) of deferrals"  // stringlint:ignore
                
                guard
                    numGroupKeys > 0 && (
                        deferCount == 0 ||
                        dependencies[cache: .libSession].hasConfig(for: .groupKeys, sessionId: groupSessionId)
                    )
                else {
                    // Defer the job by 1s to give it a little more time to receive updated keys
                    let updatedJob: Job? = dependencies[singleton: .storage].write { db in
                        try job
                            .with(nextRunTimestamp: dependencies.dateNow.timeIntervalSince1970 + deferalDuration)
                            .upserted(db)
                    }
                    
                    Log.info(.cat, "Deferring \(messageType) (\(job.id ?? -1)) as we haven't received the group encryption keys yet")
                    return deferred(updatedJob ?? job)
                }
                
            default: break
        }
        
        // Store the sentTimestamp from the message in case it fails due to a clockOutOfSync error
        let originalSentTimestampMs: UInt64? = details.message.sentTimestampMs
        let startTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        
        /// Perform the actual message sending - this will timeout if the entire process takes longer than `Network.defaultTimeout * 2`
        /// which can occur if it needs to build a new onion path (which doesn't actually have any limits so can take forever in rare cases)
        ///
        /// **Note:** No need to upload attachments as part of this process as the above logic splits that out into it's own job
        /// so we shouldn't get here until attachments have already been uploaded
        dependencies[singleton: .storage]
            .writePublisher { db -> Network.PreparedRequest<Void> in
                try MessageSender.preparedSend(
                    db,
                    message: details.message,
                    to: details.destination,
                    namespace: details.destination.defaultNamespace,
                    interactionId: job.interactionId,
                    fileIds: messageFileIds,
                    using: dependencies
                )
            }
            .flatMap { $0.send(using: dependencies) }
            .subscribe(on: queue, using: dependencies)
            .receive(on: queue, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished:
                            Log.info(.cat, "Completed sending \(messageType) (\(job.id ?? -1)) after \(.seconds(dependencies.dateNow.timeIntervalSince1970 - startTime), unit: .s)\(previousDeferralsMessage).")
                            success(job, false)
                            
                        case .failure(let error):
                            Log.info(.cat, "Failed to send \(messageType) (\(job.id ?? -1)) after \(.seconds(dependencies.dateNow.timeIntervalSince1970 - startTime), unit: .s)\(previousDeferralsMessage) due to error: \(error).")
                            
                            // Actual error handling
                            switch (error, details.message) {
                                case (let senderError as MessageSenderError, _) where !senderError.isRetryable:
                                    failure(job, error, true)
                                    
                                case (SnodeAPIError.rateLimited, _):
                                    failure(job, error, true)
                                    
                                case (SnodeAPIError.clockOutOfSync, _):
                                    Log.error(.cat, "\(originalSentTimestampMs != nil ? "Permanently Failing" : "Failing") to send \(messageType) (\(job.id ?? -1)) due to clock out of sync issue.")
                                    failure(job, error, (originalSentTimestampMs != nil))
                                    
                                // Don't bother retrying (it can just send a new one later but allowing retries
                                // can result in a large number of `MessageSendJobs` backing up)
                                case (_, is TypingIndicator):
                                    failure(job, error, true)
                                    
                                default:
                                    if details.message is VisibleMessage {
                                        guard
                                            let interactionId: Int64 = job.interactionId,
                                            dependencies[singleton: .storage].read({ db in try Interaction.exists(db, id: interactionId) }) == true
                                        else {
                                            // The message has been deleted so permanently fail the job
                                            return failure(job, error, true)
                                        }
                                    }
                                    
                                    failure(job, error, false)
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
                Log.error(.cat, "Unable to decode messageSend job due to missing variant")
                throw StorageError.decodingFailed
            }
            
            self = Details(
                destination: try container.decode(Message.Destination.self, forKey: .destination),
                message: try variant.decode(from: container, forKey: .message)
            )
        }
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            guard let variant: Message.Variant = Message.Variant(from: message) else {
                Log.error(.cat, "Unable to encode messageSend job due to unsupported variant")
                throw StorageError.objectNotFound
            }

            try container.encode(destination, forKey: .destination)
            try container.encode(message, forKey: .message)
            try container.encode(variant, forKey: .variant)
        }
    }
}
