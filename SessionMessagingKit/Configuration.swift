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
                    _019_GroupsRebuildChanges.self
                ]
            ]
        )
    }
    
    public static func configure(using dependencies: Dependencies) {
        // Configure the job executors
        let executors: [Job.Variant: JobExecutor.Type] = [
            .disappearingMessages: DisappearingMessagesJob.self,
            .failedMessageSends: FailedMessageSendsJob.self,
            .failedAttachmentDownloads: FailedAttachmentDownloadsJob.self,
            .updateProfilePicture: UpdateProfilePictureJob.self,
            .retrieveDefaultOpenGroupRooms: RetrieveDefaultOpenGroupRoomsJob.self,
            .garbageCollection: GarbageCollectionJob.self,
            .messageSend: MessageSendJob.self,
            .messageReceive: MessageReceiveJob.self,
            .notifyPushServer: NotifyPushServerJob.self,
            .sendReadReceipts: SendReadReceiptsJob.self,
            .attachmentUpload: AttachmentUploadJob.self,
            .groupLeaving: GroupLeavingJob.self,
            .attachmentDownload: AttachmentDownloadJob.self,
            .configurationSync: ConfigurationSyncJob.self,
            .configMessageReceive: ConfigMessageReceiveJob.self,
            .expirationUpdate: ExpirationUpdateJob.self,
            .displayPictureDownload: DisplayPictureDownloadJob.self,
            .getExpiration: GetExpirationJob.self,
            .groupInviteMember: GroupInviteMemberJob.self,
            .groupPromoteMember: GroupPromoteMemberJob.self,
            .processPendingGroupMemberRemovals: ProcessPendingGroupMemberRemovalsJob.self
        ]
        
        executors.forEach { variant, executor in
            dependencies[singleton: .jobRunner].setExecutor(executor, for: variant)
        }
    }
}
