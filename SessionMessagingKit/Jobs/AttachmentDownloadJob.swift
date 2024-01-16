// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit
import SessionSnodeKit
import SignalCoreKit

public enum AttachmentDownloadJob: JobExecutor {
    public static var maxFailureCount: Int = 3
    public static var requiresThreadId: Bool = true
    public static let requiresInteractionId: Bool = true
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies
    ) {
        guard
            dependencies.hasInitialised(singleton: .appContext),
            let threadId: String = job.threadId,
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData),
            let attachment: Attachment = dependencies[singleton: .storage]
                .read({ db in try Attachment.fetchOne(db, id: details.attachmentId) })
        else {
            failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
            return
        }
        
        // Due to the complex nature of jobs and how attachments can be reused it's possible for
        // an AttachmentDownloadJob to get created for an attachment which has already been
        // downloaded/uploaded so in those cases just succeed immediately
        guard attachment.state != .downloaded && attachment.state != .uploaded else {
            success(job, false, dependencies)
            return
        }
        
        // If we ever make attachment downloads concurrent this will prevent us from downloading
        // the same attachment multiple times at the same time (it also adds a "clean up" mechanism
        // if an attachment ends up stuck in a "downloading" state incorrectly
        guard attachment.state != .downloading else {
            let otherCurrentJobAttachmentIds: Set<String> = dependencies[singleton: .jobRunner]
                .jobInfoFor(state: .running, variant: .attachmentDownload)
                .filter { key, _ in key != job.id }
                .values
                .compactMap { info -> String? in
                    guard let data: Data = info.detailsData else { return nil }
                    
                    return (try? JSONDecoder(using: dependencies).decode(Details.self, from: data))?
                        .attachmentId
                }
                .asSet()
            
            // If there isn't another currently running attachmentDownload job downloading this attachment
            // then we should update the state of the attachment to be failed to avoid having attachments
            // appear in an endlessly downloading state
            if !otherCurrentJobAttachmentIds.contains(attachment.id) {
                dependencies[singleton: .storage].write { db in
                    _ = try Attachment
                        .filter(id: attachment.id)
                        .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.failedDownload))
                }
            }
            
            // Note: The only ways we should be able to get into this state are if we enable concurrent
            // downloads or if the app was closed/crashed while an attachmentDownload job was in progress
            //
            // If there is another current job then just fail this one permanently, otherwise let it
            // retry (if there are more retry attempts available) and in the next retry it's state should
            // be 'failedDownload' so we won't get stuck in a loop
            failure(job, nil, otherCurrentJobAttachmentIds.contains(attachment.id), dependencies)
            return
        }
        
        // Update to the 'downloading' state (no need to update the 'attachment' instance)
        dependencies[singleton: .storage].write { db in
            try Attachment
                .filter(id: attachment.id)
                .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.downloading))
        }
        
        let temporaryFileUrl: URL = URL(
            fileURLWithPath: dependencies[singleton: .appContext].temporaryDirectoryAccessibleAfterFirstAuth + UUID().uuidString
        )
        
        Just(attachment.downloadUrl)
            .setFailureType(to: Error.self)
            .tryFlatMap { maybeDownloadUrl -> AnyPublisher<Data, Error> in
                guard
                    let downloadUrl: String = maybeDownloadUrl,
                    let fileId: String = Attachment.fileId(for: downloadUrl)
                else { throw AttachmentDownloadError.invalidUrl }
                
                return dependencies[singleton: .storage]
                    .readPublisher { db -> HTTP.PreparedRequest<Data> in
                        switch try OpenGroup.fetchOne(db, id: threadId) {
                            case .some(let openGroup):
                                return try OpenGroupAPI
                                    .preparedDownloadFile(
                                        db,
                                        fileId: fileId,
                                        from: openGroup.roomToken,
                                        on: openGroup.server
                                    )
                                
                            case .none:
                                return try FileServerAPI
                                    .preparedDownload(
                                        fileId: fileId,
                                        useOldServer: downloadUrl.contains(FileServerAPI.oldServer),
                                        using: dependencies
                                    )
                        }
                    }
                    .flatMap { $0.send(using: dependencies) }
                    .map { _, data in data }
                    .eraseToAnyPublisher()
            }
            .subscribe(on: queue)
            .receive(on: queue)
            .tryMap { data -> Void in
                // Store the encrypted data temporarily
                try data.write(to: temporaryFileUrl, options: .atomic)
                
                // Decrypt the data
                let plaintext: Data = try {
                    guard
                        let key: Data = attachment.encryptionKey,
                        let digest: Data = attachment.digest,
                        key.count > 0,
                        digest.count > 0
                    else { return data } // Open group attachments are unencrypted
                    
                    // FIXME: Replace this with an first party solution
                    return try Cryptography.decryptAttachment(
                        data,
                        withKey: key,
                        digest: digest,
                        unpaddedSize: UInt32(attachment.byteCount)
                    )
                }()
                
                // Write the data to disk
                guard try attachment.write(data: plaintext) else {
                    throw AttachmentDownloadError.failedToSaveFile
                }
                
                return ()
            }
            .sinkUntilComplete(
                receiveCompletion: { result in
                    // Remove the temporary file
                    try? FileSystem.deleteFile(at: temporaryFileUrl.path)

                    switch result {
                        case .finished:
                            /// Update the attachment state
                            ///
                            /// **Note:** We **MUST** use the `'with()` function here as it will update the
                            /// `isValid` and `duration` values based on the downloaded data and the state
                            dependencies[singleton: .storage].write { db in
                                try attachment
                                    .with(
                                        state: .downloaded,
                                        creationTimestamp: TimeInterval(
                                            (Double(SnodeAPI.currentOffsetTimestampMs(using: dependencies)) / 1000)
                                        ),
                                        localRelativeFilePath: (
                                            attachment.localRelativeFilePath ??
                                            Attachment.localRelativeFilePath(from: attachment.originalFilePath)
                                        )
                                    )
                                    .upserted(db)
                            }
                            
                            success(job, false, dependencies)
                            
                        case .failure(let error):
                            let targetState: Attachment.State
                            let permanentFailure: Bool
                            
                            switch error {
                                /// If we get a 404 then we got a successful response from the server but the attachment doesn't
                                /// exist, in this case update the attachment to an "invalid" state so the user doesn't get stuck in
                                /// a retry download loop
                                case OnionRequestAPIError.httpRequestFailedAtDestination(let statusCode, _, _) where statusCode == 404:
                                    targetState = .invalid
                                    permanentFailure = true
                                    
                                case OnionRequestAPIError.httpRequestFailedAtDestination(let statusCode, _, _) where statusCode == 400 || statusCode == 401:
                                    /// If we got a 400 or a 401 then we want to fail the download in a way that has to be manually retried as it's
                                    /// likely something else is going on that caused the failure
                                    targetState = .failedDownload
                                    permanentFailure = true
                                
                                /// For any other error it's likely either the server is down or something weird just happened with the request
                                /// so we want to automatically retry
                                default:
                                    targetState = .failedDownload
                                    permanentFailure = false
                            }
                            
                            /// To prevent the attachment from showing a state of downloading forever, we need to update the attachment
                            /// state here based on the type of error that occurred
                            ///
                            /// **Note:** We **MUST** use the `'with()` function here as it will update the
                            /// `isValid` and `duration` values based on the downloaded data and the state
                            dependencies[singleton: .storage].write { db in
                                _ = try Attachment
                                    .filter(id: attachment.id)
                                    .updateAll(db, Attachment.Columns.state.set(to: targetState))
                            }
                            
                            /// Trigger the failure and provide the `permanentFailure` value defined above
                            failure(job, error, permanentFailure, dependencies)
                    }
                }
            )
    }
}

// MARK: - AttachmentDownloadJob.Details

extension AttachmentDownloadJob {
    public struct Details: Codable {
        public let attachmentId: String
        
        public init(attachmentId: String) {
            self.attachmentId = attachmentId
        }
    }
    
    public enum AttachmentDownloadError: LocalizedError {
        case failedToSaveFile
        case invalidUrl

        public var errorDescription: String? {
            switch self {
                case .failedToSaveFile: return "Failed to save file"
                case .invalidUrl: return "Invalid file URL"
            }
        }
    }
}
