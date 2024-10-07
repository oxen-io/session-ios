// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUIKit
import SessionUtilitiesKit
import SessionSnodeKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("GroupInviteMemberJob", defaultLevel: .info)
}

// MARK: - GroupInviteMemberJob

public enum GroupInviteMemberJob: JobExecutor {
    public static var maxFailureCount: Int = 1
    public static var requiresThreadId: Bool = true
    public static var requiresInteractionId: Bool = false
    
    private static let notificationDebounceDuration: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(1500)
    private static var notifyFailurePublisher: AnyPublisher<Void, Never>?
    private static let notifyFailureTrigger: PassthroughSubject<(), Never> = PassthroughSubject()
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        guard
            let threadId: String = job.threadId,
            let detailsData: Data = job.details,
            let currentInfo: (groupName: String, adminProfile: Profile) = dependencies[singleton: .storage].read({ db in
                let maybeGroupName: String? = try ClosedGroup
                    .filter(id: threadId)
                    .select(.name)
                    .asRequest(of: String.self)
                    .fetchOne(db)
                
                guard let groupName: String = maybeGroupName else { throw StorageError.objectNotFound }
                
                return (groupName, Profile.fetchOrCreateCurrentUser(db, using: dependencies))
            }),
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { return failure(job, JobRunnerError.missingRequiredDetails, true) }
        
        let sentTimestamp: Int64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        
        /// Perform the actual message sending
        dependencies[singleton: .storage]
            .readPublisher { db -> Network.PreparedRequest<Void> in
                try MessageSender.preparedSend(
                    db,
                    message: try GroupUpdateInviteMessage(
                        inviteeSessionIdHexString: details.memberSessionIdHexString,
                        groupSessionId: SessionId(.group, hex: threadId),
                        groupName: currentInfo.groupName,
                        memberAuthData: details.memberAuthData,
                        profile: VisibleMessage.VMProfile.init(
                            profile: currentInfo.adminProfile,
                            blocksCommunityMessageRequests: nil
                        ),
                        sentTimestamp: UInt64(sentTimestamp),
                        authMethod: try Authentication.with(
                            db,
                            swarmPublicKey: threadId,
                            using: dependencies
                        ),
                        using: dependencies
                    ),
                    to: .contact(publicKey: details.memberSessionIdHexString),
                    namespace: .default,
                    interactionId: nil,
                    fileIds: [],
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
                            dependencies[singleton: .storage].write { db in
                                try GroupMember
                                    .filter(
                                        GroupMember.Columns.groupId == threadId &&
                                        GroupMember.Columns.profileId == details.memberSessionIdHexString &&
                                        GroupMember.Columns.role == GroupMember.Role.standard &&
                                        GroupMember.Columns.roleStatus != GroupMember.RoleStatus.accepted
                                    )
                                    .updateAllAndConfig(
                                        db,
                                        GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.pending),
                                        calledFromConfig: nil,
                                        using: dependencies
                                    )
                            }
                            
                            success(job, false)
                            
                        case .failure(let error):
                            Log.error(.cat, "Couldn't send message due to error: \(error).")
                            
                            // Update the invite status of the group member (only if the role is 'standard' and
                            // the role status isn't already 'accepted')
                            dependencies[singleton: .storage].write { db in
                                try GroupMember
                                    .filter(
                                        GroupMember.Columns.groupId == threadId &&
                                        GroupMember.Columns.profileId == details.memberSessionIdHexString &&
                                        GroupMember.Columns.role == GroupMember.Role.standard &&
                                        GroupMember.Columns.roleStatus != GroupMember.RoleStatus.accepted
                                    )
                                    .updateAllAndConfig(
                                        db,
                                        GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.failed),
                                        calledFromConfig: nil,
                                        using: dependencies
                                    )
                            }
                            
                            // Notify about the failure
                            GroupInviteMemberJob.notifyOfFailure(
                                groupId: threadId,
                                memberId: details.memberSessionIdHexString,
                                using: dependencies
                            )
                            
                            // Register the failure
                            switch error {
                                case let senderError as MessageSenderError where !senderError.isRetryable:
                                    failure(job, error, true)
                                    
                                case SnodeAPIError.rateLimited:
                                    failure(job, error, true)
                                    
                                case SnodeAPIError.clockOutOfSync:
                                    Log.error(.cat, "Permanently Failing to send due to clock out of sync issue.")
                                    failure(job, error, true)
                                    
                                default: failure(job, error, false)
                            }
                    }
                }
            )
    }
    
    public static func failureMessage(groupName: String, memberIds: [String], profileInfo: [String: Profile]) -> NSAttributedString {
        switch memberIds.count {
            case 1:
                return "groupInviteFailedUser"
                    .put(
                        key: "name",
                        value: (
                            profileInfo[memberIds[0]]?.displayName(for: .group) ??
                            Profile.truncated(id: memberIds[0], truncating: .middle)
                        )
                    )
                    .put(key: "group_name", value: groupName)
                    .localizedFormatted(baseFont: ToastController.font)

            case 2:
                return "groupInviteFailedTwo"
                    .put(
                        key: "name",
                        value: (
                            profileInfo[memberIds[0]]?.displayName(for: .group) ??
                            Profile.truncated(id: memberIds[0], truncating: .middle)
                        )
                    )
                    .put(
                        key: "other_name",
                        value: (
                            profileInfo[memberIds[1]]?.displayName(for: .group) ??
                            Profile.truncated(id: memberIds[1], truncating: .middle)
                        )
                    )
                    .put(key: "group_name", value: groupName)
                    .localizedFormatted(baseFont: ToastController.font)

            default:
                return "groupInviteFailedMultiple"
                    .put(
                        key: "name",
                        value: (
                            profileInfo[memberIds[0]]?.displayName(for: .group) ??
                            Profile.truncated(id: memberIds[0], truncating: .middle)
                        )
                    )
                    .put(key: "count", value: memberIds.count - 1)
                    .put(key: "group_name", value: groupName)
                    .localizedFormatted(baseFont: ToastController.font)
        }
    }
    
    private static func notifyOfFailure(groupId: String, memberId: String, using dependencies: Dependencies) {
        dependencies.mutate(cache: .groupInviteMemberJob) { cache in
            cache.failedMemberIds.insert(memberId)
        }
        
        /// This method can be triggered by each individual invitation failure so we want to throttle the updates to 250ms so that we can group failures
        /// and show a single toast
        if notifyFailurePublisher == nil {
            notifyFailurePublisher = notifyFailureTrigger
                .debounce(for: notificationDebounceDuration, scheduler: DispatchQueue.global(qos: .userInitiated))
                .handleEvents(
                    receiveOutput: { [dependencies] _ in
                        let failedIds: [String] = dependencies.mutate(cache: .groupInviteMemberJob) { cache in
                            let result: Set<String> = cache.failedMemberIds
                            cache.failedMemberIds.removeAll()
                            return Array(result)
                        }
                        
                        // Don't do anything if there are no 'failedIds' values or we can't get a window
                        guard
                            !failedIds.isEmpty,
                            let mainWindow: UIWindow = dependencies[singleton: .appContext].mainWindow
                        else { return }
                        
                        typealias FetchedData = (groupName: String, profileInfo: [String: Profile])
                        
                        let data: FetchedData = dependencies[singleton: .storage]
                            .read { db in
                                (
                                    try ClosedGroup
                                        .filter(id: groupId)
                                        .select(.name)
                                        .asRequest(of: String.self)
                                        .fetchOne(db),
                                    try Profile.filter(ids: failedIds).fetchAll(db)
                                )
                            }
                            .map { maybeName, profiles -> FetchedData in
                                (
                                    (maybeName ?? "groupUnknown".localized()),
                                    profiles.reduce(into: [:]) { result, next in result[next.id] = next }
                                )
                            }
                            .defaulting(to: ("groupUnknown".localized(), [:]))
                        let message: NSAttributedString = failureMessage(
                            groupName: data.groupName,
                            memberIds: failedIds,
                            profileInfo: data.profileInfo
                        )
                        
                        DispatchQueue.main.async {
                            let toastController: ToastController = ToastController(
                                text: message,
                                background: .backgroundSecondary
                            )
                            toastController.presentToastView(fromBottomOfView: mainWindow, inset: Values.largeSpacing)
                        }
                    }
                )
                .map { _ in () }
                .eraseToAnyPublisher()
            
            notifyFailurePublisher?.sinkUntilComplete()
        }
        
        notifyFailureTrigger.send(())
    }
}

// MARK: - GroupInviteMemberJob Cache

public extension GroupInviteMemberJob {
    class Cache: GroupInviteMemberJobCacheType {
        public var failedMemberIds: Set<String> = []
    }
}

public extension Cache {
    static let groupInviteMemberJob: CacheConfig<GroupInviteMemberJobCacheType, GroupInviteMemberJobImmutableCacheType> = Dependencies.create(
        identifier: "groupInviteMemberJob",
        createInstance: { _ in GroupInviteMemberJob.Cache() },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - GroupInviteMemberJobCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol GroupInviteMemberJobImmutableCacheType: ImmutableCacheType {
    var failedMemberIds: Set<String> { get }
}

public protocol GroupInviteMemberJobCacheType: GroupInviteMemberJobImmutableCacheType, MutableCacheType {
    var failedMemberIds: Set<String> { get set }
}

// MARK: - GroupInviteMemberJob.Details

extension GroupInviteMemberJob {
    public struct Details: Codable {
        public let memberSessionIdHexString: String
        public let memberAuthData: Data
        
        public init(
            memberSessionIdHexString: String,
            authInfo: Authentication.Info
        ) throws {
            self.memberSessionIdHexString = memberSessionIdHexString
            
            switch authInfo {
                case .groupMember(_, let authData): self.memberAuthData = authData
                default: throw MessageSenderError.invalidMessage
            }
        }
    }
}
