// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

/// This job deletes unused and orphaned data from the database as well as orphaned files from device storage
///
/// **Note:** When sheduling this job if no `Details` are provided (with a list of `typesToCollect`) then this job will
/// assume that it should be collecting all `Types`
public enum GarbageCollectionJob: JobExecutor {
    public static var maxFailureCount: Int = -1
    public static var requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    public static let approxSixMonthsInSeconds: TimeInterval = (6 * 30 * 24 * 60 * 60)
    public static let fourteenDaysInSeconds: TimeInterval = (14 * 24 * 60 * 60)
    private static let minInteractionsToTrim: Int = 2000
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        /// Determine what types of data we want to collect (if we didn't provide any then assume we want to collect everything)
        ///
        /// **Note:** The reason we default to handle all cases (instead of just doing nothing in that case) is so the initial registration
        /// of the garbageCollection job never needs to be updated as we continue to add more types going forward
        let typesToCollect: [Types] = (job.details
            .map { try? JSONDecoder(using: dependencies).decode(Details.self, from: $0) }?
            .typesToCollect)
            .defaulting(to: Types.allCases)
        let timestampNow: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        
        /// Only do a full collection if the job isn't the recurring one or it's been 23 hours since it last ran (23 hours so a user who opens the
        /// app at about the same time every day will trigger the garbage collection) - since this runs when the app becomes active we
        /// want to prevent it running to frequently (the app becomes active if a system alert, the notification center or the control panel
        /// are shown)
        let lastGarbageCollection: Date = dependencies[defaults: .standard, key: .lastGarbageCollection]
            .defaulting(to: Date.distantPast)
        let finalTypesToCollect: Set<Types> = {
            guard
                job.behaviour != .recurringOnActive ||
                dependencies.dateNow.timeIntervalSince(lastGarbageCollection) > (23 * 60 * 60)
            else {
                // Note: This should only contain the `Types` which are unlikely to ever cause
                // a startup delay (ie. avoid mass deletions and file management)
                return typesToCollect.asSet()
                    .intersection([
                        .threadTypingIndicators
                    ])
            }
            
            return typesToCollect.asSet()
        }()
        
        dependencies[singleton: .storage].writeAsync(
            updates: { db in
                let userSessionId: SessionId = dependencies[cache: .general].sessionId
                
                /// Remove any typing indicators
                if finalTypesToCollect.contains(.threadTypingIndicators) {
                    _ = try ThreadTypingIndicator
                        .deleteAll(db)
                }
                
                /// Remove any expired controlMessageProcessRecords
                if finalTypesToCollect.contains(.expiredControlMessageProcessRecords) {
                    _ = try ControlMessageProcessRecord
                        .filter(ControlMessageProcessRecord.Columns.serverExpirationTimestamp <= timestampNow)
                        .deleteAll(db)
                }
                
                /// Remove any old open group messages - open group messages which are older than six months
                if finalTypesToCollect.contains(.oldOpenGroupMessages) && db[.trimOpenGroupMessagesOlderThanSixMonths] {
                    let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                    let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
                    let threadIdLiteral: SQL = SQL(stringLiteral: Interaction.Columns.threadId.name)
                    let minInteractionsToTrimSql: SQL = SQL("\(GarbageCollectionJob.minInteractionsToTrim)")
                    
                    try db.execute(literal: """
                        DELETE FROM \(Interaction.self)
                        WHERE \(Column.rowID) IN (
                            SELECT \(interaction[.rowId])
                            FROM \(Interaction.self)
                            JOIN \(SessionThread.self) ON (
                                \(SQL("\(thread[.variant]) = \(SessionThread.Variant.community)")) AND
                                \(thread[.id]) = \(interaction[.threadId])
                            )
                            JOIN (
                                SELECT
                                    COUNT(\(interaction[.rowId])) AS interactionCount,
                                    \(interaction[.threadId])
                                FROM \(Interaction.self)
                                GROUP BY \(interaction[.threadId])
                            ) AS interactionInfo ON interactionInfo.\(threadIdLiteral) = \(interaction[.threadId])
                            WHERE (
                                \(interaction[.timestampMs]) < \((timestampNow - approxSixMonthsInSeconds) * 1000) AND
                                interactionInfo.interactionCount >= \(minInteractionsToTrimSql)
                            )
                        )
                    """)
                }
                
                /// Orphaned jobs - jobs which have had their threads or interactions removed
                if finalTypesToCollect.contains(.orphanedJobs) {
                    let job: TypedTableAlias<Job> = TypedTableAlias()
                    let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
                    let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                    
                    try db.execute(literal: """
                        DELETE FROM \(Job.self)
                        WHERE \(Column.rowID) IN (
                            SELECT \(job[.rowId])
                            FROM \(Job.self)
                            LEFT JOIN \(SessionThread.self) ON \(thread[.id]) = \(job[.threadId])
                            LEFT JOIN \(Interaction.self) ON \(interaction[.id]) = \(job[.interactionId])
                            WHERE (
                                -- Never delete config sync jobs, even if their threads were deleted
                                \(SQL("\(job[.variant]) != \(Job.Variant.configurationSync)")) AND
                                (
                                    \(job[.threadId]) IS NOT NULL AND
                                    \(thread[.id]) IS NULL
                                ) OR (
                                    \(job[.interactionId]) IS NOT NULL AND
                                    \(interaction[.id]) IS NULL
                                )
                            )
                        )
                    """)
                }
                
                /// Orphaned link previews - link previews which have no interactions with matching url & rounded timestamps
                if finalTypesToCollect.contains(.orphanedLinkPreviews) {
                    let linkPreview: TypedTableAlias<LinkPreview> = TypedTableAlias()
                    let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                    
                    try db.execute(literal: """
                        DELETE FROM \(LinkPreview.self)
                        WHERE \(Column.rowID) IN (
                            SELECT \(linkPreview[.rowId])
                            FROM \(LinkPreview.self)
                            LEFT JOIN \(Interaction.self) ON (
                                \(interaction[.linkPreviewUrl]) = \(linkPreview[.url]) AND
                                \(Interaction.linkPreviewFilterLiteral())
                            )
                            WHERE \(interaction[.id]) IS NULL
                        )
                    """)
                }
                
                /// Orphaned open groups - open groups which are no longer associated to a thread (except for the session-run ones for which
                /// we want cached image data even if the user isn't in the group)
                if finalTypesToCollect.contains(.orphanedOpenGroups) {
                    let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
                    let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
                    
                    try db.execute(literal: """
                        DELETE FROM \(OpenGroup.self)
                        WHERE \(Column.rowID) IN (
                            SELECT \(openGroup[.rowId])
                            FROM \(OpenGroup.self)
                            LEFT JOIN \(SessionThread.self) ON \(thread[.id]) = \(openGroup[.threadId])
                            WHERE (
                                \(thread[.id]) IS NULL AND
                                \(SQL("\(openGroup[.server]) != \(OpenGroupAPI.defaultServer.lowercased())"))
                            )
                        )
                    """)
                }
                
                /// Orphaned open group capabilities - capabilities which have no existing open groups with the same server
                if finalTypesToCollect.contains(.orphanedOpenGroupCapabilities) {
                    let capability: TypedTableAlias<Capability> = TypedTableAlias()
                    let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
                    
                    try db.execute(literal: """
                        DELETE FROM \(Capability.self)
                        WHERE \(Column.rowID) IN (
                            SELECT \(capability[.rowId])
                            FROM \(Capability.self)
                            LEFT JOIN \(OpenGroup.self) ON \(openGroup[.server]) = \(capability[.openGroupServer])
                            WHERE \(openGroup[.threadId]) IS NULL
                        )
                    """)
                }
                
                /// Orphaned blinded id lookups - lookups which have no existing threads or approval/block settings for either blinded/un-blinded id
                if finalTypesToCollect.contains(.orphanedBlindedIdLookups) {
                    let blindedIdLookup: TypedTableAlias<BlindedIdLookup> = TypedTableAlias()
                    let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
                    let contact: TypedTableAlias<Contact> = TypedTableAlias()
                    
                    try db.execute(literal: """
                        DELETE FROM \(BlindedIdLookup.self)
                        WHERE \(Column.rowID) IN (
                            SELECT \(blindedIdLookup[.rowId])
                            FROM \(BlindedIdLookup.self)
                            LEFT JOIN \(SessionThread.self) ON (
                                \(thread[.id]) = \(blindedIdLookup[.blindedId]) OR
                                \(thread[.id]) = \(blindedIdLookup[.sessionId])
                            )
                            LEFT JOIN \(Contact.self) ON (
                                \(contact[.id]) = \(blindedIdLookup[.blindedId]) OR
                                \(contact[.id]) = \(blindedIdLookup[.sessionId])
                            )
                            WHERE (
                                \(thread[.id]) IS NULL AND
                                \(contact[.id]) IS NULL
                            )
                        )
                    """)
                }
                
                /// Approved blinded contact records - once a blinded contact has been approved there is no need to keep the blinded
                /// contact record around anymore
                if finalTypesToCollect.contains(.approvedBlindedContactRecords) {
                    let contact: TypedTableAlias<Contact> = TypedTableAlias()
                    let blindedIdLookup: TypedTableAlias<BlindedIdLookup> = TypedTableAlias()

                    try db.execute(literal: """
                        DELETE FROM \(Contact.self)
                        WHERE \(Column.rowID) IN (
                            SELECT \(contact[.rowId])
                            FROM \(Contact.self)
                            LEFT JOIN \(BlindedIdLookup.self) ON (
                                \(blindedIdLookup[.blindedId]) = \(contact[.id]) AND
                                \(blindedIdLookup[.sessionId]) IS NOT NULL
                            )
                            WHERE \(blindedIdLookup[.sessionId]) IS NOT NULL
                        )
                    """)
                }
                
                /// Orphaned attachments - attachments which have no related interactions, quotes or link previews
                if finalTypesToCollect.contains(.orphanedAttachments) {
                    let attachment: TypedTableAlias<Attachment> = TypedTableAlias()
                    let quote: TypedTableAlias<Quote> = TypedTableAlias()
                    let linkPreview: TypedTableAlias<LinkPreview> = TypedTableAlias()
                    let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
                    
                    try db.execute(literal: """
                        DELETE FROM \(Attachment.self)
                        WHERE \(Column.rowID) IN (
                            SELECT \(attachment[.rowId])
                            FROM \(Attachment.self)
                            LEFT JOIN \(Quote.self) ON \(quote[.attachmentId]) = \(attachment[.id])
                            LEFT JOIN \(LinkPreview.self) ON \(linkPreview[.attachmentId]) = \(attachment[.id])
                            LEFT JOIN \(InteractionAttachment.self) ON \(interactionAttachment[.attachmentId]) = \(attachment[.id])
                            WHERE (
                                \(quote[.attachmentId]) IS NULL AND
                                \(linkPreview[.url]) IS NULL AND
                                \(interactionAttachment[.attachmentId]) IS NULL
                            )
                        )
                    """)
                }
                
                if finalTypesToCollect.contains(.orphanedProfiles) {
                    let profile: TypedTableAlias<Profile> = TypedTableAlias()
                    let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
                    let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                    let quote: TypedTableAlias<Quote> = TypedTableAlias()
                    let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
                    let contact: TypedTableAlias<Contact> = TypedTableAlias()
                    let blindedIdLookup: TypedTableAlias<BlindedIdLookup> = TypedTableAlias()
                    
                    try db.execute(literal: """
                        DELETE FROM \(Profile.self)
                        WHERE \(Column.rowID) IN (
                            SELECT \(profile[.rowId])
                            FROM \(Profile.self)
                            LEFT JOIN \(SessionThread.self) ON \(thread[.id]) = \(profile[.id])
                            LEFT JOIN \(Interaction.self) ON \(interaction[.authorId]) = \(profile[.id])
                            LEFT JOIN \(Quote.self) ON \(quote[.authorId]) = \(profile[.id])
                            LEFT JOIN \(GroupMember.self) ON \(groupMember[.profileId]) = \(profile[.id])
                            LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(profile[.id])
                            LEFT JOIN \(BlindedIdLookup.self) ON (
                                blindedIdLookup.blindedId = \(profile[.id]) OR
                                blindedIdLookup.sessionId = \(profile[.id])
                            )
                            WHERE (
                                \(thread[.id]) IS NULL AND
                                \(interaction[.authorId]) IS NULL AND
                                \(quote[.authorId]) IS NULL AND
                                \(groupMember[.profileId]) IS NULL AND
                                \(contact[.id]) IS NULL AND
                                \(blindedIdLookup[.blindedId]) IS NULL
                            )
                        )
                    """)
                }
                
                /// Remove interactions which should be disappearing after read but never be read within 14 days
                if finalTypesToCollect.contains(.expiredUnreadDisappearingMessages) {
                    _ = try Interaction
                        .filter(Interaction.Columns.expiresInSeconds != 0)
                        .filter(Interaction.Columns.expiresStartedAtMs == nil)
                        .filter(Interaction.Columns.timestampMs < (timestampNow - fourteenDaysInSeconds) * 1000)
                        .deleteAll(db)
                }

                if finalTypesToCollect.contains(.expiredPendingReadReceipts) {
                    _ = try PendingReadReceipt
                        .filter(PendingReadReceipt.Columns.serverExpirationTimestamp <= timestampNow)
                        .deleteAll(db)
                }
                
                if finalTypesToCollect.contains(.shadowThreads) {
                    // Shadow threads are thread records which were created to start a conversation that
                    // didn't actually get turned into conversations (ie. the app was closed or crashed
                    // before the user sent a message)
                    let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
                    let contact: TypedTableAlias<Contact> = TypedTableAlias()
                    let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
                    let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
                    
                    try db.execute(literal: """
                        DELETE FROM \(SessionThread.self)
                        WHERE \(Column.rowID) IN (
                            SELECT \(thread[.rowId])
                            FROM \(SessionThread.self)
                            LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])
                            LEFT JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(thread[.id])
                            LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
                            WHERE (
                                \(contact[.id]) IS NULL AND
                                \(openGroup[.threadId]) IS NULL AND
                                \(closedGroup[.threadId]) IS NULL AND
                                \(thread[.shouldBeVisible]) = false AND
                                \(SQL("\(thread[.id]) != \(userSessionId.hexString)"))
                            )
                        )
                    """)
                }
            },
            completion: { _, _ in
                // Dispatch async so we can swap from the write queue to a read one (we are done writing)
                queue.async {
                    // Retrieve a list of all valid attachmnet and avatar file paths
                    struct FileInfo {
                        let attachmentLocalRelativePaths: Set<String>
                        let displayPictureFilenames: Set<String>
                    }
                    
                    let maybeFileInfo: FileInfo? = dependencies[singleton: .storage].read { db -> FileInfo in
                        var attachmentLocalRelativePaths: Set<String> = []
                        var displayPictureFilenames: Set<String> = []
                        
                        /// Orphaned attachment files - attachment files which don't have an associated record in the database
                        if finalTypesToCollect.contains(.orphanedAttachmentFiles) {
                            /// **Note:** Thumbnails are stored in the `NSCachesDirectory` directory which should be automatically manage
                            /// it's own garbage collection so we can just ignore it according to the various comments in the following stack overflow
                            /// post, the directory will be cleared during app updates as well as if the system is running low on memory (if the app isn't running)
                            /// https://stackoverflow.com/questions/6879860/when-are-files-from-nscachesdirectory-removed
                            attachmentLocalRelativePaths = try Attachment
                                .select(.localRelativeFilePath)
                                .filter(Attachment.Columns.localRelativeFilePath != nil)
                                .asRequest(of: String.self)
                                .fetchSet(db)
                        }

                        /// Orphaned display picture files - profile avatar files which don't have an associated record in the database
                        if finalTypesToCollect.contains(.orphanedDisplayPictures) {
                            displayPictureFilenames.insert(
                                contentsOf: try Profile
                                    .select(.profilePictureFileName)
                                    .filter(Profile.Columns.profilePictureFileName != nil)
                                    .asRequest(of: String.self)
                                    .fetchSet(db)
                            )
                            displayPictureFilenames.insert(
                                contentsOf: try ClosedGroup
                                    .select(.displayPictureFilename)
                                    .filter(ClosedGroup.Columns.displayPictureFilename != nil)
                                    .asRequest(of: String.self)
                                    .fetchSet(db)
                            )
                            displayPictureFilenames.insert(
                                contentsOf: try OpenGroup
                                    .select(.displayPictureFilename)
                                    .filter(OpenGroup.Columns.displayPictureFilename != nil)
                                    .asRequest(of: String.self)
                                    .fetchSet(db)
                            )
                        }
                        
                        return FileInfo(
                            attachmentLocalRelativePaths: attachmentLocalRelativePaths,
                            displayPictureFilenames: displayPictureFilenames
                        )
                    }
                    
                    // If we couldn't get the file lists then fail (invalid state and don't want to delete all attachment/profile files)
                    guard let fileInfo: FileInfo = maybeFileInfo else {
                        failure(job, StorageError.generic, false)
                        return
                    }
                        
                    var deletionErrors: [Error] = []
                    
                    // Orphaned attachment files (actual deletion)
                    if finalTypesToCollect.contains(.orphanedAttachmentFiles) {
                        // Note: Looks like in order to recursively look through files we need to use the
                        // enumerator method
                        let fileEnumerator = FileManager.default.enumerator(
                            at: URL(fileURLWithPath: Attachment.attachmentsFolder(using: dependencies)),
                            includingPropertiesForKeys: nil,
                            options: .skipsHiddenFiles  // Ignore the `.DS_Store` for the simulator
                        )
                        
                        let allAttachmentFilePaths: Set<String> = (fileEnumerator?
                            .allObjects
                            .compactMap { Attachment.localRelativeFilePath(from: ($0 as? URL)?.path, using: dependencies) })
                            .defaulting(to: [])
                            .asSet()
                        
                        // Note: Directories will have their own entries in the list, if there is a folder with content
                        // the file will include the directory in it's path with a forward slash so we can use this to
                        // distinguish empty directories from ones with content so we don't unintentionally delete a
                        // directory which contains content to keep as well as delete (directories which end up empty after
                        // this clean up will be removed during the next run)
                        let directoryNamesContainingContent: [String] = allAttachmentFilePaths
                            .filter { path -> Bool in path.contains("/") }  // stringlint:disable
                            .compactMap { path -> String? in path.components(separatedBy: "/").first }  // stringlint:disable
                        let orphanedAttachmentFiles: Set<String> = allAttachmentFilePaths
                            .subtracting(fileInfo.attachmentLocalRelativePaths)
                            .subtracting(directoryNamesContainingContent)
                        
                        orphanedAttachmentFiles.forEach { filepath in
                            // We don't want a single deletion failure to block deletion of the other files so try
                            // each one and store the error to be used to determine success/failure of the job
                            do {
                                try FileManager.default.removeItem(
                                    atPath: URL(fileURLWithPath: Attachment.attachmentsFolder(using: dependencies))
                                        .appendingPathComponent(filepath)
                                        .path
                                )
                            }
                            catch { deletionErrors.append(error) }
                        }
                        
                        Log.info("[GarbageCollectionJob] Removed \(orphanedAttachmentFiles.count) orphaned attachment\(plural: orphanedAttachmentFiles.count)")
                    }
                    
                    // Orphaned display picture files (actual deletion)
                    if finalTypesToCollect.contains(.orphanedDisplayPictures) {
                        let allDisplayPictureFilenames: Set<String> = (try? FileManager.default
                            .contentsOfDirectory(atPath: DisplayPictureManager.sharedDataDisplayPictureDirPath(using: dependencies)))
                            .defaulting(to: [])
                            .asSet()
                        let orphanedFiles: Set<String> = allDisplayPictureFilenames
                            .subtracting(fileInfo.displayPictureFilenames)
                        
                        orphanedFiles.forEach { filename in
                            // We don't want a single deletion failure to block deletion of the other files so try
                            // each one and store the error to be used to determine success/failure of the job
                            do {
                                try FileManager.default.removeItem(
                                    atPath: DisplayPictureManager.filepath(for: filename, using: dependencies)
                                )
                            }
                            catch { deletionErrors.append(error) }
                        }
                        
                        Log.info("[GarbageCollectionJob] Removed \(orphanedFiles.count) orphaned display picture\(plural: orphanedFiles.count)")
                    }
                    
                    // Report a single file deletion as a job failure (even if other content was successfully removed)
                    guard deletionErrors.isEmpty else {
                        failure(job, (deletionErrors.first ?? StorageError.generic), false)
                        return
                    }
                    
                    // If we did a full collection then update the 'lastGarbageCollection' date to
                    // prevent a full collection from running again in the next 23 hours
                    if job.behaviour == .recurringOnActive && dependencies.dateNow.timeIntervalSince(lastGarbageCollection) > (23 * 60 * 60) {
                        dependencies[defaults: .standard, key: .lastGarbageCollection] = dependencies.dateNow
                    }
                    
                    success(job, false)
                }
            }
        )
    }
}

// MARK: - GarbageCollectionJob.Details

extension GarbageCollectionJob {
    public enum Types: Codable, CaseIterable {
        case expiredControlMessageProcessRecords
        case threadTypingIndicators
        case oldOpenGroupMessages
        case orphanedJobs
        case orphanedLinkPreviews
        case orphanedOpenGroups
        case orphanedOpenGroupCapabilities
        case orphanedBlindedIdLookups
        case approvedBlindedContactRecords
        case orphanedProfiles
        case orphanedAttachments
        case orphanedAttachmentFiles
        case orphanedDisplayPictures
        case expiredUnreadDisappearingMessages // unread disappearing messages after 14 days
        case expiredPendingReadReceipts
        case shadowThreads
    }
    
    public struct Details: Codable {
        public let typesToCollect: [Types]
        
        public init(typesToCollect: [Types] = Types.allCases) {
            self.typesToCollect = typesToCollect
        }
    }
}
