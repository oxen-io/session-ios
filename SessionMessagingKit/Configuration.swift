import Foundation
import GRDB
import SessionUtilitiesKit

public enum SNMessagingKit: MigratableTarget { // Just to make the external API nice
    public static func migrations() -> TargetMigrations {
        return TargetMigrations(
            identifier: .messagingKit,
            migrations: [
                [
                    _001_InitialSetupMigration.self,
                    _002_SetupStandardJobs.self
                ],  // Initial DB Creation
                [
                    _003_YDBToGRDBMigration.self
                ],  // YDB to GRDB Migration
                [
                    _004_RemoveLegacyYDB.self
                ],  // Legacy DB removal
                [
                    _005_FixDeletedMessageReadState.self,
                    _006_FixHiddenModAdminSupport.self,
                    _007_HomeQueryOptimisationIndexes.self
                ],  // Add job priorities
                [
                    _008_EmojiReacts.self,
                    _009_OpenGroupPermission.self,
                    _010_AddThreadIdToFTS.self
                ],  // Fix thread FTS
                [
                    _011_AddPendingReadReceipts.self,
                    _012_AddFTSIfNeeded.self,
                    _013_SessionUtilChanges.self,
                    _014_GenerateInitialUserConfigDumps.self,
                    _015_BlockCommunityMessageRequests.self,
                    _016_MakeBrokenProfileTimestampsNullable.self,
                    _017_RebuildFTSIfNeeded_2_4_5.self,
                    _018_DisappearingMessagesConfiguration.self,
                    _019_ScheduleAppUpdateCheckJob.self,
                    _020_AddMissingWhisperFlag.self,
                    _021_ReworkRecipientState.self
                ]
            ]
        )
    }
    
    public static func configure() {
        // Configure the job executors
        JobRunner.setExecutor(DisappearingMessagesJob.self, for: .disappearingMessages)
        JobRunner.setExecutor(FailedMessageSendsJob.self, for: .failedMessageSends)
        JobRunner.setExecutor(FailedAttachmentDownloadsJob.self, for: .failedAttachmentDownloads)
        JobRunner.setExecutor(UpdateProfilePictureJob.self, for: .updateProfilePicture)
        JobRunner.setExecutor(RetrieveDefaultOpenGroupRoomsJob.self, for: .retrieveDefaultOpenGroupRooms)
        JobRunner.setExecutor(GarbageCollectionJob.self, for: .garbageCollection)
        JobRunner.setExecutor(MessageSendJob.self, for: .messageSend)
        JobRunner.setExecutor(MessageReceiveJob.self, for: .messageReceive)
        JobRunner.setExecutor(NotifyPushServerJob.self, for: .notifyPushServer)
        JobRunner.setExecutor(SendReadReceiptsJob.self, for: .sendReadReceipts)
        JobRunner.setExecutor(AttachmentUploadJob.self, for: .attachmentUpload)
        JobRunner.setExecutor(GroupLeavingJob.self, for: .groupLeaving)
        JobRunner.setExecutor(AttachmentDownloadJob.self, for: .attachmentDownload)
        JobRunner.setExecutor(ConfigurationSyncJob.self, for: .configurationSync)
        JobRunner.setExecutor(ConfigMessageReceiveJob.self, for: .configMessageReceive)
        JobRunner.setExecutor(ExpirationUpdateJob.self, for: .expirationUpdate)
        JobRunner.setExecutor(GetExpirationJob.self, for: .getExpiration)
        JobRunner.setExecutor(CheckForAppUpdatesJob.self, for: .checkForAppUpdates)
    }
}
