// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SignalCoreKit
import SessionUtilitiesKit
import SessionSnodeKit

public enum GroupLeavingJob: JobExecutor {
    public static var maxFailureCount: Int = 0
    public static var requiresThreadId: Bool = true
    public static var requiresInteractionId: Bool = true
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies = Dependencies()
    ) {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder().decode(Details.self, from: detailsData),
            let threadId: String = job.threadId,
            let interactionId: Int64 = job.interactionId
        else {
            SNLog("[GroupLeavingJob] Failed due to missing details")
            return failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
        }
        
        let destination: Message.Destination = .closedGroup(groupPublicKey: threadId)
        
        dependencies.storage
            .writePublisher { db in
                guard (try? SessionThread.exists(db, id: threadId)) == true else {
                    SNLog("[GroupLeavingJob] Failed due to non-existent group conversation")
                    throw MessageSenderError.noThread
                }
                guard (try? ClosedGroup.exists(db, id: threadId)) == true else {
                    SNLog("[GroupLeavingJob] Failed due to non-existent group")
                    throw MessageSenderError.invalidClosedGroupUpdate
                }
                
                return try MessageSender.preparedSendData(
                    db,
                    message: ClosedGroupControlMessage(
                        kind: .memberLeft
                    ),
                    to: destination,
                    namespace: destination.defaultNamespace,
                    interactionId: job.interactionId,
                    using: dependencies
                )
            }
            .flatMap { MessageSender.sendImmediate(data: $0, using: dependencies) }
            .subscribe(on: queue)
            .receive(on: queue)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    // Handle the appropriate response
                    dependencies.storage.writeAsync { db in
                        let failureChanges: [ConfigColumnAssignment] = [
                            Interaction.Columns.variant
                                .set(to: Interaction.Variant.infoClosedGroupCurrentUserErrorLeaving),
                            Interaction.Columns.body
                                .set(to: "groupLeaveErrorFailed"
                                    .put(key: "group_name", value: ((try? ClosedGroup.fetchOne(db, id: threadId))?.name ?? ""))
                                    .localized()
                                )
                        ]
                        
                        let successfulChanges: [ConfigColumnAssignment] = [
                            Interaction.Columns.variant
                                .set(to: Interaction.Variant.infoClosedGroupCurrentUserLeft),
                            Interaction.Columns.body.set(to: "groupMemberYouLeft".localized())
                        ]
                        
                        // If it failed due to one of these errors then clear out any associated data (as somehow
                        // the 'SessionThread' exists but not the data required to send the 'MEMBER_LEFT' message
                        // which would leave the user in a state where they can't leave the group)
                        let errorsToSucceed: [MessageSenderError] = [
                            .invalidClosedGroupUpdate,
                            .noKeyPair
                        ]
                        let shouldSucceed: Bool = {
                            switch result {
                                case .failure(let error as MessageSenderError): return errorsToSucceed.contains(error)
                                case .failure: return false
                                default: return true
                            }
                        }()
                        
                        // Update the transaction
                        try Interaction
                            .filter(id: interactionId)
                            .updateAll(
                                db,
                                (shouldSucceed ? successfulChanges : failureChanges)
                            )
                        
                        // If we succeed in leaving then we should try to clear the group data
                        guard shouldSucceed else { return }
                        
                        // Update the group (if the admin leaves the group is disbanded)
                        let currentUserPublicKey: String = getUserHexEncodedPublicKey(db)
                        let wasAdminUser: Bool = GroupMember
                            .filter(GroupMember.Columns.groupId == threadId)
                            .filter(GroupMember.Columns.profileId == currentUserPublicKey)
                            .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                            .isNotEmpty(db)
                        
                        if wasAdminUser {
                            try GroupMember
                                .filter(GroupMember.Columns.groupId == threadId)
                                .deleteAll(db)
                        }
                        else {
                            try GroupMember
                                .filter(GroupMember.Columns.groupId == threadId)
                                .filter(GroupMember.Columns.profileId == currentUserPublicKey)
                                .deleteAll(db)
                        }
                        
                        // Clear out the group info as needed
                        try ClosedGroup.removeKeysAndUnsubscribe(
                            db,
                            threadId: threadId,
                            removeGroupData: details.deleteThread,
                            calledFromConfigHandling: false
                        )
                    }
                    
                    success(job, false, dependencies)
                }
            )
    }
}

// MARK: - GroupLeavingJob.Details

extension GroupLeavingJob {
    public struct Details: Codable {
        private enum CodingKeys: String, CodingKey {
            case deleteThread
        }
        
        public let deleteThread: Bool
        
        // MARK: - Initialization
        
        public init(deleteThread: Bool) {
            self.deleteThread = deleteThread
        }
        
        // MARK: - Codable
        
        public init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            self = Details(
                deleteThread: try container.decode(Bool.self, forKey: .deleteThread)
            )
        }
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(deleteThread, forKey: .deleteThread)
        }
    }
}

