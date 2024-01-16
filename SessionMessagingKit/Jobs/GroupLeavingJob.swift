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
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData),
            let threadId: String = job.threadId,
            let interactionId: Int64 = job.interactionId
        else {
            SNLog("[GroupLeavingJob] Failed due to missing details")
            return failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
        }
        
        let destination: Message.Destination = .closedGroup(groupPublicKey: threadId)
        
        dependencies[singleton: .storage]
            .writePublisher { db -> LeaveType in
                guard
                    let threadVariant: SessionThread.Variant = try? SessionThread
                        .filter(id: threadId)
                        .select(.variant)
                        .asRequest(of: SessionThread.Variant.self)
                        .fetchOne(db)
                else {
                    SNLog("[GroupLeavingJob] Failed due to non-existent group conversation")
                    throw MessageSenderError.noThread
                }
                guard (try? ClosedGroup.exists(db, id: threadId)) == true else {
                    SNLog("[GroupLeavingJob] Failed due to non-existent group")
                    throw MessageSenderError.invalidClosedGroupUpdate
                }
                
                let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                let isAdminUser: Bool = GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .filter(GroupMember.Columns.profileId == userSessionId.hexString)
                    .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                    .isNotEmpty(db)
                let numAdminUsers: Int = (try? GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                    .distinct()
                    .fetchCount(db))
                    .defaulting(to: 0)
                
                switch (threadVariant, details.behaviour, (isAdminUser && numAdminUsers == 1)) {
                    case (.legacyGroup, _, _):
                        // Legacy group only supports the 'leave' behaviour so don't bother checking
                        return .leave(
                            try MessageSender.preparedSend(
                                db,
                                message: ClosedGroupControlMessage(kind: .memberLeft),
                                to: destination,
                                namespace: destination.defaultNamespace,
                                interactionId: job.interactionId,
                                fileIds: [],
                                isSyncMessage: false,
                                using: dependencies
                            )
                        )
                    
                    case (.group, .leave, false):
                        return .leave(
                            try MessageSender.preparedSend(
                                db,
                                message: GroupUpdateMemberLeftMessage(),
                                to: destination,
                                namespace: destination.defaultNamespace,
                                interactionId: job.interactionId,
                                fileIds: [],
                                isSyncMessage: false,
                                using: dependencies
                            )
                        )
                        
                    case (.group, .delete, _), (.group, .leave, true):
                        try LibSession.deleteGroupForEveryone(
                            db,
                            groupSessionId: SessionId(.group, hex: threadId),
                            using: dependencies
                        )
                        
                        return .delete
                        
                    default: throw MessageSenderError.invalidClosedGroupUpdate
                }
            }
            .flatMap { leaveType -> AnyPublisher<Void, Error> in
                switch leaveType {
                    case .leave(let leaveMessage):
                        return leaveMessage
                            .send(using: dependencies)
                            .map { _ in () }
                            .eraseToAnyPublisher()
                        
                    case .delete:
                        return ConfigurationSyncJob
                            .run(sessionIdHexString: threadId, using: dependencies)
                            .map { _ in () }
                            .eraseToAnyPublisher()
                }
            }
            .tryCatch { error -> AnyPublisher<Void, Error> in
                /// If it failed due to one of these errors then clear out any associated data (as the `SessionThread` exists but
                /// either the data required to send the `MEMBER_LEFT` message doesn't or the user has had their access to the
                /// group revoked which would leave the user in a state where they can't leave the group)
                switch (error as? MessageSenderError, error as? SnodeAPIError) {
                    case (.invalidClosedGroupUpdate, _), (.noKeyPair, _), (.encryptionFailed, _),
                        (_, .unauthorised):
                        return Just(()).setFailureType(to: Error.self).eraseToAnyPublisher()
                    
                    default: throw error
                }
            }
            .subscribe(on: queue, using: dependencies)
            .receive(on: queue, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .failure(let error):
                            let updatedBody: String = {
                                switch details.behaviour {
                                    case .leave: return "group_unable_to_leave".localized()
                                    case .delete: return "group_unable_to_delete".localized()
                                }
                            }()
                            
                            // Update the interaction to indicate we failed to leave the group
                            dependencies[singleton: .storage].writeAsync(using: dependencies) { db in
                                try Interaction
                                    .filter(id: interactionId)
                                    .updateAll(
                                        db,
                                        Interaction.Columns.variant
                                            .set(to: Interaction.Variant.infoGroupCurrentUserErrorLeaving),
                                        Interaction.Columns.body.set(to: updatedBody)
                                    )
                            }
                            
                            failure(job, error, true, dependencies)
                            
                        case .finished:
                            // Remove all of the group data
                            dependencies[singleton: .storage].writeAsync(using: dependencies) { db in
                                try ClosedGroup.removeData(
                                    db,
                                    threadIds: [threadId],
                                    dataToRemove: .allData,
                                    calledFromConfigHandling: false,
                                    using: dependencies
                                )
                            }
                            
                            success(job, false, dependencies)
                    }
                }
            )
    }
}

// MARK: - GroupLeavingJob.Details

extension GroupLeavingJob {
    public struct Details: Codable {
        private enum CodingKeys: String, CodingKey {
            case behaviour
        }
        
        public enum Behaviour: Int, Codable {
            /// Will leave the group, deleting it from the current device but letting the group continue to exist as long
            /// the current user isn't the only admin
            case leave = 1
            
            /// Will permanently delete the group, this will result in the group being deleted from all member devices
            case delete = 2
        }
        
        public let behaviour: Behaviour
        
        // MARK: - Initialization
        
        public init(behaviour: Behaviour) {
            self.behaviour = behaviour
        }
    }
}

// MARK: - Convenience

private extension GroupLeavingJob {
    enum LeaveType {
        case leave(HTTP.PreparedRequest<Void>)
        case delete
    }
}
