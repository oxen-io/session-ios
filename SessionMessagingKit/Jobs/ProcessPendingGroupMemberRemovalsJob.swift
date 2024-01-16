// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUIKit
import SessionUtilitiesKit
import SessionSnodeKit

public enum ProcessPendingGroupMemberRemovalsJob: JobExecutor {
    public static var maxFailureCount: Int = 1
    public static var requiresThreadId: Bool = true
    public static var requiresInteractionId: Bool = false
    private static let maxRunFrequency: TimeInterval = 3
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies
    ) {
        guard
            let groupSessionId: SessionId = job.threadId.map({ SessionId(.group, hex: $0) }),
            let detailsData: Data = job.details,
            let groupIdentityPrivateKey: Data = dependencies[singleton: .storage].read({ db in
                try ClosedGroup
                    .filter(id: groupSessionId.hexString)
                    .select(.groupIdentityPrivateKey)
                    .asRequest(of: Data.self)
                    .fetchOne(db)
            }),
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else {
            SNLog("[ProcessPendingGroupMemberRemovalsJob] Failing due to missing details")
            failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
            return
        }
        
        /// It's possible for multiple jobs with the same target (group) to try to run at the same time, rather than adding dependencies between the jobs
        /// we just continue to defer the subsequent job while the first one is running in order to prevent multiple jobs with the same target from running
        /// at the same time
        guard
            dependencies[singleton: .jobRunner]
                .jobInfoFor(state: .running, variant: .processPendingGroupMemberRemovals)
                .filter({ key, info in
                    key != job.id &&                // Exclude this job
                    info.threadId == job.threadId   // Exclude jobs for different ids
                })
                .isEmpty
        else {
            // Defer the job to run 'maxRunFrequency' from when this one ran (if we don't it'll try start
            // it again immediately which is pointless)
            let updatedJob: Job? = dependencies[singleton: .storage].write { db in
                try job
                    .with(nextRunTimestamp: dependencies.dateNow.timeIntervalSince1970 + maxRunFrequency)
                    .upserted(db)
            }
            
            SNLog("[ProcessPendingGroupMemberRemovalsJob] For \(job.threadId ?? "UnknownId") deferred due to in progress job")
            return deferred(updatedJob ?? job, dependencies)
        }
        
        /// If there are no pending removals then we can just complete
        guard
            let pendingRemovals: [String: Bool] = try? LibSession.getPendingMemberRemovals(
                groupSessionId: groupSessionId,
                using: dependencies
            ),
            !pendingRemovals.isEmpty
        else {
            return success(job, false, dependencies)
        }
        
        /// Define a timestamp to use for all messages created by the removal changes
        ///
        /// **Note:** The `targetChangeTimestampMs` will differ from the `messageSendTimestamp` as it's the time the
        /// member was originally removed whereas the `messageSendTimestamp` is the time it will be uploaded to the swarm
        let targetChangeTimestampMs: Int64 = (
            details.changeTimestampMs ??
            SnodeAPI.currentOffsetTimestampMs(using: dependencies)
        )
        let messageSendTimestamp: Int64 = SnodeAPI.currentOffsetTimestampMs(using: dependencies)
        
        return Just(())
            .setFailureType(to: Error.self)
            .tryMap { _ -> HTTP.PreparedRequest<HTTP.BatchResponse> in
                /// Revoke the members authData from the group so the server rejects API calls from the ex-members (fire-and-forget
                /// this request, we don't want it to be blocking)
                let preparedRevokeSubaccounts: HTTP.PreparedRequest<Void> = try SnodeAPI.preparedRevokeSubaccounts(
                    subaccountsToRevoke: try Array(pendingRemovals.keys).map { memberId in
                        try LibSession.generateSubaccountToken(
                            groupSessionId: groupSessionId,
                            memberId: memberId,
                            using: dependencies
                        )
                    },
                    authMethod: Authentication.groupAdmin(
                        groupSessionId: groupSessionId,
                        ed25519SecretKey: Array(groupIdentityPrivateKey)
                    ),
                    using: dependencies
                )
                
                /// Prepare a `GroupUpdateDeleteMessage` to be sent (instruct their clients to delete the group content)
                let currentGen: Int = try LibSession.currentGeneration(
                    groupSessionId: groupSessionId,
                    using: dependencies
                )
                let deleteMessageData: [(recipient: SessionId, message: Data)] = pendingRemovals.keys
                    .compactMap { try? LibSessionMessage.groupKicked(memberId: $0, groupKeysGen: currentGen) }
                let encryptedDeleteMessageData: Data = try dependencies[singleton: .crypto].tryGenerate(
                    .ciphertextWithMultiEncrypt(
                        messages: deleteMessageData.map { $0.message },
                        toRecipients: deleteMessageData.map { $0.recipient },
                        ed25519PrivateKey: Array(groupIdentityPrivateKey),
                        domain: .kickedMessage
                    )
                )
                let preparedGroupDeleteMessage: HTTP.PreparedRequest<Void> = try SnodeAPI
                    .preparedSendMessage(
                        message: SnodeMessage(
                            recipient: groupSessionId.hexString,
                            data: encryptedDeleteMessageData.base64EncodedString(),
                            ttl: Message().ttl,
                            timestampMs: UInt64(messageSendTimestamp)
                        ),
                        in: .revokedRetrievableGroupMessages,
                        authMethod: Authentication.groupAdmin(
                            groupSessionId: groupSessionId,
                            ed25519SecretKey: Array(groupIdentityPrivateKey)
                        ),
                        using: dependencies
                    )
                    .map { _, _ in () }
                
                /// Combine the two requests to be sent at the same time
                return try SnodeAPI.preparedSequence(
                    requests: [preparedRevokeSubaccounts, preparedGroupDeleteMessage],
                    requireAllBatchResponses: true,
                    associatedWith: groupSessionId.hexString,
                    using: dependencies
                )
            }
            .flatMap { $0.send(using: dependencies) }
            .tryMap { _, response -> Void in
                /// If any one of the requests failed then we didn't successfully remove the members access so try again later
                guard
                    response.allSatisfy({ subResponse in
                        200...299 ~= ((subResponse as? HTTP.BatchSubResponse<Void>)?.code ?? 400)
                    })
                else { throw MessageSenderError.invalidClosedGroupUpdate }
                
                return ()
            }
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .failure(let error):
                            SNLog("[ProcessPendingGroupMemberRemovalsJob] Failed due to error: \(error).")
                            failure(job, error, false, dependencies)
                            
                        case .finished:
                            dependencies[singleton: .storage]
                                .writeAsync(
                                    using: dependencies,
                                    updates: { db in
                                        /// Remove the members from the `GROUP_MEMBERS` config
                                        try LibSession.removeMembers(
                                            db,
                                            groupSessionId: groupSessionId,
                                            memberIds: Set(pendingRemovals.keys),
                                            using: dependencies
                                        )
                                        
                                        /// We need to update the group keys when removing members so they can't decrypt any
                                        /// more group messages
                                        ///
                                        /// **Note:** This **MUST** be called _after_ the members have been removed, otherwise
                                        /// the removed members may still be able to access the keys
                                        try LibSession.rekey(
                                            db,
                                            groupSessionId: groupSessionId,
                                            using: dependencies
                                        )
                                        
                                        /// Remove the members from the database
                                        try GroupMember
                                            .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
                                            .filter(pendingRemovals.keys.contains(GroupMember.Columns.profileId))
                                            .deleteAll(db)
                                        
                                        /// If we want to remove the messages sent by the removed members then do so and send
                                        /// an instruction to other members to remove the messages as well
                                        let memberIdsToRemoveContent: Set<String> = pendingRemovals
                                            .filter { _, shouldRemoveContent -> Bool in shouldRemoveContent }
                                            .map { memberId, _ -> String in memberId }
                                            .asSet()
                                        
                                        if !memberIdsToRemoveContent.isEmpty {
                                            let messageHashesToRemove: Set<String> = try Interaction
                                                .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                                                .filter(memberIdsToRemoveContent.contains(Interaction.Columns.authorId))
                                                .filter(Interaction.Columns.serverHash != nil)
                                                .select(.serverHash)
                                                .asRequest(of: String.self)
                                                .fetchSet(db)
                                            
                                            /// Delete the messages from my device
                                            try Interaction
                                                .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                                                .filter(memberIdsToRemoveContent.contains(Interaction.Columns.authorId))
                                                .deleteAll(db)
                                            
                                            /// Tell other members devices to delete the messages
                                            try MessageSender.send(
                                                db,
                                                message: GroupUpdateDeleteMemberContentMessage(
                                                    memberSessionIds: Array(memberIdsToRemoveContent),
                                                    messageHashes: [],
                                                    sentTimestamp: UInt64(targetChangeTimestampMs),
                                                    authMethod: Authentication.groupAdmin(
                                                        groupSessionId: groupSessionId,
                                                        ed25519SecretKey: Array(groupIdentityPrivateKey)
                                                    ),
                                                    using: dependencies
                                                ),
                                                interactionId: nil,
                                                threadId: groupSessionId.hexString,
                                                threadVariant: .group,
                                                using: dependencies
                                            )
                                            
                                            /// Delete the messages from the swarm so users won't download them again
                                            try? SnodeAPI
                                                .preparedDeleteMessages(
                                                    serverHashes: Array(messageHashesToRemove),
                                                    requireSuccessfulDeletion: false,
                                                    authMethod: Authentication.groupAdmin(
                                                        groupSessionId: groupSessionId,
                                                        ed25519SecretKey: Array(groupIdentityPrivateKey)
                                                    ),
                                                    using: dependencies
                                                )
                                                .send(using: dependencies)
                                                .subscribe(on: queue, using: dependencies)
                                                .sinkUntilComplete()
                                        }
                                    },
                                    completion: { db, result in
                                        queue.async(using: dependencies) {
                                            switch result {
                                                case .success: success(job, false, dependencies)
                                                case .failure(let error):
                                                    SNLog("[ProcessPendingGroupMemberRemovalsJob] Failed due to error: \(error).")
                                                    failure(job, error, false, dependencies)
                                            }
                                        }
                                    }
                                )
                    }
                }
            )
    }
}

// MARK: - ProcessPendingGroupMemberRemovalsJob.Details

extension ProcessPendingGroupMemberRemovalsJob {
    public struct Details: Codable {
        public let changeTimestampMs: Int64?
        
        public init(changeTimestampMs: Int64? = nil) {
            self.changeTimestampMs = changeTimestampMs
        }
    }
}
