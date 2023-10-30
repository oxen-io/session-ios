// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUIKit
import SessionUtilitiesKit
import SessionSnodeKit

public enum GroupPromoteMemberJob: JobExecutor {
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
            let groupIdentityPrivateKey: Data = dependencies[singleton: .storage].read({ db in
                try ClosedGroup
                    .filter(id: threadId)
                    .select(.groupIdentityPrivateKey)
                    .asRequest(of: Data.self)
                    .fetchOne(db)
            }),
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else {
            SNLog("[GroupPromoteMemberJob] Failing due to missing details")
            failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
            return
        }
        
        // The first 32 bytes of a 64 byte ed25519 private key are the seed which can be used
        // to generate the KeyPair so extract those and send along with the promotion message
        let sentTimestamp: Int64 = SnodeAPI.currentOffsetTimestampMs(using: dependencies)
        let message: GroupUpdatePromoteMessage = GroupUpdatePromoteMessage(
            groupIdentitySeed: groupIdentityPrivateKey.prefix(32),
            sentTimestamp: UInt64(sentTimestamp)
        )
        
        /// Perform the actual message sending
        dependencies[singleton: .storage]
            .readPublisher { db -> HTTP.PreparedRequest<Void> in
                try MessageSender.preparedSend(
                    db,
                    message: message,
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
                                        GroupMember.Columns.role == GroupMember.Role.admin &&
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
                            SNLog("[GroupPromoteMemberJob] Couldn't send message due to error: \(error).")
                            
                            // Update the promotion status of the group member (only if the role is 'admin' and
                            // the role status isn't already 'accepted')
                            dependencies[singleton: .storage].write(using: dependencies) { db in
                                try GroupMember
                                    .filter(
                                        GroupMember.Columns.groupId == threadId &&
                                        GroupMember.Columns.profileId == details.memberSessionIdHexString &&
                                        GroupMember.Columns.role == GroupMember.Role.admin &&
                                        GroupMember.Columns.roleStatus != GroupMember.RoleStatus.accepted
                                    )
                                    .updateAllAndConfig(
                                        db,
                                        GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.failed),
                                        using: dependencies
                                    )
                            }
                            
                            // Notify about the failure
                            GroupPromoteMemberJob.notifyOfFailure(
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
                                    SNLog("[GroupPromoteMemberJob] Permanently Failing to send due to clock out of sync issue.")
                                    failure(job, error, true, dependencies)
                                    
                                default: failure(job, error, false, dependencies)
                            }
                    }
                }
            )
    }
    
    private static func notifyOfFailure(groupId: String, memberId: String, using dependencies: Dependencies) {
        dependencies.mutate(cache: .groupPromoteMemberJob) { cache in
            cache.failedMemberIds.insert(memberId)
        }
        
        /// This method can be triggered by each individual invitation failure so we want to throttle the updates to 250ms so that we can group failures
        /// and show a single toast
        if notifyFailurePublisher == nil {
            notifyFailurePublisher = notifyFailureTrigger
                .debounce(for: notificationDebounceDuration, scheduler: DispatchQueue.global(qos: .userInitiated))
                .handleEvents(
                    receiveOutput: { [dependencies] _ in
                        let failedIds: [String] = dependencies.mutate(cache: .groupPromoteMemberJob) { cache in
                            let result: Set<String> = cache.failedMemberIds
                            cache.failedMemberIds.removeAll()
                            return Array(result)
                        }
                        
                        // Don't do anything if there are no 'failedIds' values or we can't get a window
                        guard
                            !failedIds.isEmpty,
                            HasAppContext(),
                            let mainWindow: UIWindow = CurrentAppContext().mainWindow
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
                        
                        let message: String = {
                            switch failedIds.count {
                                case 1:
                                    return String(
                                        format: "GROUP_ACTION_PROMOTE_FAILED_ONE".localized(),
                                        (
                                            data.profileInfo[failedIds[0]]?.displayName(for: .group) ??
                                            Profile.truncated(id: failedIds[0], truncating: .middle)
                                        ),
                                        data.groupName
                                    )
                                    
                                case 2:
                                    return String(
                                        format: "GROUP_ACTION_PROMOTE_FAILED_TWO".localized(),
                                        (
                                            data.profileInfo[failedIds[0]]?.displayName(for: .group) ??
                                            Profile.truncated(id: failedIds[0], truncating: .middle)
                                        ),
                                        (
                                            data.profileInfo[failedIds[1]]?.displayName(for: .group) ??
                                            Profile.truncated(id: failedIds[1], truncating: .middle)
                                        ),
                                        data.groupName
                                    )
                                    
                                default:
                                    let targetProfile: Profile? = data.profileInfo.values.first
                                    
                                    return String(
                                        format: "GROUP_ACTION_PROMOTE_FAILED_MULTIPLE".localized(),
                                        (
                                            targetProfile?.displayName(for: .group) ??
                                            Profile.truncated(id: failedIds[0], truncating: .middle)
                                        ),
                                        "\(failedIds.count - 1)",
                                        data.groupName
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

// MARK: - GroupPromoteMemberJob Cache

public extension GroupPromoteMemberJob {
    class Cache: GroupPromoteMemberJobCacheType {
        public var failedMemberIds: Set<String> = []
    }
}

public extension Cache {
    static let groupPromoteMemberJob: CacheConfig<GroupPromoteMemberJobCacheType, GroupPromoteMemberJobImmutableCacheType> = Dependencies.create(
        identifier: "groupPromoteMemberJob",
        createInstance: { _ in GroupPromoteMemberJob.Cache() },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - GroupPromoteMemberJobCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol GroupPromoteMemberJobImmutableCacheType: ImmutableCacheType {
    var failedMemberIds: Set<String> { get }
}

public protocol GroupPromoteMemberJobCacheType: GroupPromoteMemberJobImmutableCacheType, MutableCacheType {
    var failedMemberIds: Set<String> { get set }
}

// MARK: - GroupPromoteMemberJob.Details

extension GroupPromoteMemberJob {
    public struct Details: Codable {
        public let memberSessionIdHexString: String
    }
}
