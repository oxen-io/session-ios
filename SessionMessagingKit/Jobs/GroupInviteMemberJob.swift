// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUIKit
import SessionUtilitiesKit
import SessionSnodeKit

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
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
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
        else {
            SNLog("[GroupInviteMemberJob] Failing due to missing details")
            failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
            return
        }
        
        let sentTimestamp: Int64 = SnodeAPI.currentOffsetTimestampMs(using: dependencies)
        
        /// Perform the actual message sending
        dependencies[singleton: .storage]
            .readPublisher { db -> HTTP.PreparedRequest<Void> in
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
                            sessionIdHexString: threadId,
                            using: dependencies
                        ),
                        using: dependencies
                    ),
                    to: .contact(publicKey: details.memberSessionIdHexString),
                    namespace: .default,
                    interactionId: nil,
                    fileIds: [],
                    isSyncMessage: false,
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
                            dependencies[singleton: .storage].write(using: dependencies) { db in
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
                                        using: dependencies
                                    )
                            }
                            
                            success(job, false, dependencies)
                            
                        case .failure(let error):
                            SNLog("[GroupInviteMemberJob] Couldn't send message due to error: \(error).")
                            
                            // Update the invite status of the group member (only if the role is 'standard' and
                            // the role status isn't already 'accepted')
                            dependencies[singleton: .storage].write(using: dependencies) { db in
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
                                    failure(job, error, true, dependencies)
                                    
                                case OnionRequestAPIError.httpRequestFailedAtDestination(let statusCode, _, _) where statusCode == 429: // Rate limited
                                    failure(job, error, true, dependencies)
                                    
                                case SnodeAPIError.clockOutOfSync:
                                    SNLog("[GroupInviteMemberJob] Permanently Failing to send due to clock out of sync issue.")
                                    failure(job, error, true, dependencies)
                                    
                                default: failure(job, error, false, dependencies)
                            }
                    }
                }
            )
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
                            dependencies.hasInitialised(singleton: .appContext),
                            let mainWindow: UIWindow = dependencies[singleton: .appContext].mainWindow
                        else { return }
                        
                        typealias FetchedData = (groupName: String, profileInfo: [String: Profile])
                        
                        let data: FetchedData = dependencies[singleton: .storage]
                            .read(using: dependencies) { db in
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
                                    (maybeName ?? "GROUP_TITLE_FALLBACK".localized()),
                                    profiles.reduce(into: [:]) { result, next in result[next.id] = next }
                                )
                            }
                            .defaulting(to: ("GROUP_TITLE_FALLBACK".localized(), [:]))
                        
                        let message: NSAttributedString = {
                            switch failedIds.count {
                                case 1:
                                    return NSAttributedString(
                                        format: "GROUP_ACTION_INVITE_FAILED_ONE".localized(),
                                        .font(
                                            (
                                                data.profileInfo[failedIds[0]]?.displayName(for: .group) ??
                                                Profile.truncated(id: failedIds[0], truncating: .middle)
                                            ),
                                            ToastController.boldFont
                                        ),
                                        .font(data.groupName, ToastController.boldFont)
                                    )
                                    
                                case 2:
                                    return NSAttributedString(
                                        format: "GROUP_ACTION_INVITE_FAILED_TWO".localized(),
                                        .font(
                                            (
                                                data.profileInfo[failedIds[0]]?.displayName(for: .group) ??
                                                Profile.truncated(id: failedIds[0], truncating: .middle)
                                            ),
                                            ToastController.boldFont
                                        ),
                                        .font(
                                            (
                                                data.profileInfo[failedIds[1]]?.displayName(for: .group) ??
                                                Profile.truncated(id: failedIds[1], truncating: .middle)
                                            ),
                                            ToastController.boldFont
                                        ),
                                        .font(data.groupName, ToastController.boldFont)
                                    )
                                    
                                default:
                                    let targetProfile: Profile? = data.profileInfo.values.first
                                    
                                    return NSAttributedString(
                                        format: "GROUP_ACTION_INVITE_FAILED_MULTIPLE".localized(),
                                        .font(
                                            (
                                                targetProfile?.displayName(for: .group) ??
                                                Profile.truncated(id: failedIds[0], truncating: .middle)
                                            ),
                                            ToastController.boldFont
                                        ),
                                        .plain("\(failedIds.count - 1)"),
                                        .font(data.groupName, ToastController.boldFont)
                                    )
                            }
                        }()
                        
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
