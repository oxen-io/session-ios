// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit

public struct ClosedGroup: Codable, Equatable, Hashable, Identifiable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "closedGroup" }
    internal static let threadForeignKey = ForeignKey([Columns.threadId], to: [SessionThread.Columns.id])
    public static let thread = belongsTo(SessionThread.self, using: threadForeignKey)
    internal static let keyPairs = hasMany(
        ClosedGroupKeyPair.self,
        using: ClosedGroupKeyPair.closedGroupForeignKey
    )
    public static let members = hasMany(GroupMember.self, using: GroupMember.closedGroupForeignKey)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case threadId
        case name
        case groupDescription
        case formationTimestamp
        
        case displayPictureUrl
        case displayPictureFilename
        case displayPictureEncryptionKey
        case lastDisplayPictureUpdate
        
        case shouldPoll
        case groupIdentityPrivateKey
        case authData
        case invited
    }
    
    public var id: String { threadId }  // Identifiable
    public var publicKey: String { threadId }

    /// The id for the thread this closed group belongs to
    ///
    /// **Note:** This value will always be publicKey for the closed group
    public let threadId: String
    public let name: String
    public let groupDescription: String?
    public let formationTimestamp: TimeInterval
    
    /// The URL from which to fetch the groups's display picture.
    public let displayPictureUrl: String?

    /// The file name of the groups's display picture on local storage.
    public let displayPictureFilename: String?

    /// The key with which the display picture is encrypted.
    public let displayPictureEncryptionKey: Data?
    
    /// The timestamp (in seconds since epoch) that the display picture was last updated
    public let lastDisplayPictureUpdate: TimeInterval?
    
    /// A flag indicating whether we should poll for messages in this group
    public let shouldPoll: Bool?
    
    /// The private key for performing admin actions on this group
    public let groupIdentityPrivateKey: Data?
    
    /// The unique authData for the current user within the group
    ///
    /// **Note:** This will be `null` if the `groupIdentityPrivateKey`  is set
    public let authData: Data?
    
    /// A flag indicating whether this group is in the "invite" state
    public let invited: Bool?
    
    // MARK: - Relationships
    
    public var thread: QueryInterfaceRequest<SessionThread> {
        request(for: ClosedGroup.thread)
    }
    
    public var keyPairs: QueryInterfaceRequest<ClosedGroupKeyPair> {
        request(for: ClosedGroup.keyPairs)
    }
    
    public var allMembers: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
    }
    
    public var members: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.standard)
    }
    
    public var zombies: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.zombie)
    }
    
    public var moderators: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.moderator)
    }
    
    public var admins: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.admin)
    }
    
    // MARK: - Initialization
    
    public init(
        threadId: String,
        name: String,
        groupDescription: String? = nil,
        formationTimestamp: TimeInterval,
        displayPictureUrl: String? = nil,
        displayPictureFilename: String? = nil,
        displayPictureEncryptionKey: Data? = nil,
        lastDisplayPictureUpdate: TimeInterval? = nil,
        shouldPoll: Bool?,
        groupIdentityPrivateKey: Data? = nil,
        authData: Data? = nil,
        invited: Bool?
    ) {
        self.threadId = threadId
        self.name = name
        self.groupDescription = groupDescription
        self.formationTimestamp = formationTimestamp
        self.displayPictureUrl = displayPictureUrl
        self.displayPictureFilename = displayPictureFilename
        self.displayPictureEncryptionKey = displayPictureEncryptionKey
        self.lastDisplayPictureUpdate = lastDisplayPictureUpdate
        self.shouldPoll = shouldPoll
        self.groupIdentityPrivateKey = groupIdentityPrivateKey
        self.authData = authData
        self.invited = invited
    }
}

// MARK: - GRDB Interactions

public extension ClosedGroup {
    func fetchLatestKeyPair(_ db: Database) throws -> ClosedGroupKeyPair? {
        return try keyPairs
            .order(ClosedGroupKeyPair.Columns.receivedTimestamp.desc)
            .fetchOne(db)
    }
}

// MARK: - Search Queries

public extension ClosedGroup {
    struct FullTextSearch: Decodable, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case name
        }
        
        let name: String
    }
}

// MARK: - Convenience

public extension ClosedGroup {
    enum LeaveType {
        case standard
        case silent
        case forced
    }
    
    enum RemovableGroupData: CaseIterable {
        case poller
        case pushNotifications
        case messages
        case members
        case encryptionKeys
        case authDetails
        case libSessionState
        case thread
        case userGroup
    }
    
    static func approveGroup(
        _ db: Database,
        group: ClosedGroup,
        calledFromConfigHandling: Bool,
        using dependencies: Dependencies
    ) throws {
        guard let userED25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db, using: dependencies) else {
            throw MessageReceiverError.noUserED25519KeyPair
        }
        
        /// Update the database state
        if group.invited == true || group.shouldPoll != true {
            try ClosedGroup
                .filter(id: group.id)
                .updateAllAndConfig(
                    db,
                    ClosedGroup.Columns.invited.set(to: false),
                    ClosedGroup.Columns.shouldPoll.set(to: true),
                    calledFromConfigHandling: calledFromConfigHandling,
                    using: dependencies
                )
        }
        
        /// Create the libSession state for the group
        try LibSession.createGroupState(
            groupSessionId: SessionId(.group, hex: group.id),
            userED25519KeyPair: userED25519KeyPair,
            groupIdentityPrivateKey: group.groupIdentityPrivateKey,
            shouldLoadState: true,
            using: dependencies
        )
        
        /// Update the `USER_GROUPS` config
        if !calledFromConfigHandling {
            try? LibSession.update(
                db,
                groupSessionId: group.id,
                invited: false,
                using: dependencies
            )
        }
        
        /// Start polling
        dependencies[singleton: .groupsPoller].startIfNeeded(for: group.id, using: dependencies)
        
        /// Subscribe for group push notifications
        if let token: String = dependencies[defaults: .standard, key: .deviceToken] {
            try? PushNotificationAPI
                .preparedSubscribe(
                    db,
                    token: Data(hex: token),
                    sessionIds: [SessionId(.group, hex: group.id)],
                    using: dependencies
                )
                .send(using: dependencies)
                .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                .sinkUntilComplete()
        }
    }
    
    static func removeData(
        _ db: Database,
        threadIds: [String],
        dataToRemove: [RemovableGroupData],
        calledFromConfigHandling: Bool,
        using dependencies: Dependencies
    ) throws {
        guard !threadIds.isEmpty && !dataToRemove.isEmpty else { return }
        
        struct ThreadIdVariant: Decodable, FetchableRecord {
            let id: String
            let variant: SessionThread.Variant
        }
        
        // Remove the group from the database and unsubscribe from PNs
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        let threadVariants: [ThreadIdVariant] = try {
            guard
                dataToRemove.contains(.pushNotifications) ||
                (dataToRemove.contains(.userGroup) && !calledFromConfigHandling) ||
                (dataToRemove.contains(.libSessionState) && !calledFromConfigHandling)
            else { return [] }
            
            return try SessionThread
                .select(.id, .variant)
                .filter(ids: threadIds)
                .asRequest(of: ThreadIdVariant.self)
                .fetchAll(db)
        }()
        
        // This data isn't located in the database so we can't perform bulk actions
        if !dataToRemove.asSet().intersection([.poller, .pushNotifications, .libSessionState]).isEmpty {
            threadIds.forEach { threadId in
                if dataToRemove.contains(.poller) {
                    dependencies[singleton: .groupsPoller].stopPolling(for: threadId)
                }
                
                if dataToRemove.contains(.poller) {
                    threadVariants.forEach { threadIdVariant in
                        switch threadIdVariant.variant {
                            case .legacyGroup:
                                try? PushNotificationAPI
                                    .preparedUnsubscribeFromLegacyGroup(
                                        legacyGroupId: threadId,
                                        userSessionId: userSessionId,
                                        using: dependencies
                                    )
                                    .send(using: dependencies)
                                    .sinkUntilComplete()
                                
                            case .group:
                                if let token: String = dependencies[defaults: .standard, key: .deviceToken] {
                                    try? PushNotificationAPI
                                        .preparedUnsubscribe(
                                            db,
                                            token: Data(hex: token),
                                            sessionIds: [userSessionId],
                                            using: dependencies
                                        )
                                        .send(using: dependencies)
                                        .sinkUntilComplete()
                                }
                                
                            default: break
                        }
                    }
                }
                
                // Ignore if called from the config handling
                if dataToRemove.contains(.libSessionState) && !calledFromConfigHandling {
                    threadVariants
                        .filter { $0.variant == .group }
                        .forEach { threadIdVariant in
                            LibSession.removeGroupStateIfNeeded(
                                db,
                                groupSessionId: SessionId(.group, hex: threadIdVariant.id),
                                using: dependencies
                            )
                        }
                }
            }
        }
        
        // Remove database-located data
        if dataToRemove.contains(.encryptionKeys) {
            try ClosedGroupKeyPair
                .filter(threadIds.contains(ClosedGroupKeyPair.Columns.threadId))
                .deleteAll(db)
        }
        
        if dataToRemove.contains(.authDetails) {
            /// Need to explicitly trigger config updates here because relying on `updateAllAndConfig` will result in an
            /// error being thrown by `libSession` because it'll attempt to update the `GROUP_INFO` config if the user
            /// was an admin (which will fail because we have removed the auth data for the group)
            try ClosedGroup
                .filter(ids: threadIds)
                .updateAll(
                    db,
                    ClosedGroup.Columns.groupIdentityPrivateKey.set(to: nil),
                    ClosedGroup.Columns.authData.set(to: nil)
                )
            
            try LibSession.markAsKicked(
                db,
                groupSessionIds: threadIds,
                using: dependencies
            )
        }
        
        if dataToRemove.contains(.messages) {
            let messageHashes: Set<String> = try Interaction
                .filter(threadIds.contains(Interaction.Columns.threadId))
                .filter(Interaction.Columns.serverHash != nil)
                .select(.serverHash)
                .asRequest(of: String.self)
                .fetchSet(db)
            
            try Interaction
                .filter(threadIds.contains(Interaction.Columns.threadId))
                .deleteAll(db)
            
            /// Delete any `ControlMessageProcessRecord` entries that we want to reprocess if the member gets
            /// re-invited to the group with historic access (these are repeatable records so won't cause issues if we re-run them)
            try ControlMessageProcessRecord
                .filter(threadIds.contains(ControlMessageProcessRecord.Columns.threadId))
                .filter([
                    ControlMessageProcessRecord.Variant.visibleMessageDedupe,
                    ControlMessageProcessRecord.Variant.groupUpdateInfoChange,
                    ControlMessageProcessRecord.Variant.groupUpdateMemberChange,
                    ControlMessageProcessRecord.Variant.groupUpdateMemberLeft,
                    ControlMessageProcessRecord.Variant.groupUpdateDeleteMemberContent
                ].contains(ControlMessageProcessRecord.Columns.variant))
                .deleteAll(db)
            
            /// Also want to delete the `SnodeReceivedMessageInfo` so if the member gets re-invited to the group with
            /// historic access they can re-download and process all of the old messages
            try SnodeReceivedMessageInfo
                .filter(messageHashes.contains(SnodeReceivedMessageInfo.Columns.hash))
                .deleteAll(db)
        }
        
        if dataToRemove.contains(.members) {
            try GroupMember
                .filter(threadIds.contains(GroupMember.Columns.groupId))
                .deleteAll(db)
        }
        
        // If we remove the poller but don't remove the thread then update the group so it doesn't poll
        // on the next launch
        if dataToRemove.contains(.poller) && !dataToRemove.contains(.thread) {
            /// Should not call `updateAllAndConfig` here as that can result in an error being thrown by `libSession` if the current
            /// user was an admin as it'll attempt, and fail, to update the `GROUP_INFO` because we have already removed the auth data
            try ClosedGroup
                .filter(ids: threadIds)
                .updateAll(
                    db,
                    ClosedGroup.Columns.shouldPoll.set(to: false)
                )
        }
        
        if dataToRemove.contains(.thread) {
            try SessionThread   // Intentionally use `deleteAll` here as this gets triggered via `deleteOrLeave`
                .filter(ids: threadIds)
                .deleteAll(db)
        }
        
        // Ignore if called from the config handling
        if dataToRemove.contains(.userGroup) && !calledFromConfigHandling {
            try LibSession.remove(
                db,
                legacyGroupIds: threadVariants
                    .filter { $0.variant == .legacyGroup }
                    .map { $0.id },
                using: dependencies
            )
            
            try LibSession.remove(
                db,
                groupSessionIds: threadVariants
                    .filter { $0.variant == .group }
                    .map { $0.id },
                using: dependencies
            )
        }
    }
}

// MARK: - ClosedGroup.MessageInfo

public extension ClosedGroup {
    enum MessageInfo: Codable {
        case invited(String, String)
        case invitedFallback(String)
        case updatedName(String)
        case updatedNameFallback
        case updatedDisplayPicture
        case addedUsers(names: [String])
        case removedUsers(names: [String])
        case memberLeft(name: String)
        case promotedUsers(names: [String])
        
        var attributedPreviewText: NSAttributedString {
            // FIXME: Including styling within SessionMessagingKit is bad so we should remove this as part of Strings
            switch self {
                case .invited(let adminName, let groupName):
                    return NSAttributedString(
                        format: "GROUP_MESSAGE_INFO_INVITED".localized(),
                        .font(adminName, .boldSystemFont(ofSize: Values.verySmallFontSize)),
                        .font(groupName, .boldSystemFont(ofSize: Values.verySmallFontSize))
                    )
                    
                case .invitedFallback(let groupName):
                    return NSAttributedString(
                        format: "GROUP_MESSAGE_INFO_INVITED_FALLBACK".localized(),
                        .font(groupName, .boldSystemFont(ofSize: Values.verySmallFontSize))
                    )
                    
                case .updatedName(let name):
                    return NSAttributedString(
                        format: "GROUP_MESSAGE_INFO_NAME_UPDATED_TO".localized(),
                        .font(name, .boldSystemFont(ofSize: Values.verySmallFontSize))
                    )
                    
                case .updatedNameFallback:
                    return NSAttributedString(string: "GROUP_MESSAGE_INFO_NAME_UPDATED".localized())
                    
                case .updatedDisplayPicture:
                    return NSAttributedString(string: "GROUP_MESSAGE_INFO_PICTURE_UPDATED".localized())
                
                case .addedUsers(let names) where names.count > 2:
                    return NSAttributedString(
                        format: "GROUP_MESSAGE_INFO_MULTIPLE_MEMBERS_ADDED".localized(),
                        .font(names[0], .boldSystemFont(ofSize: Values.verySmallFontSize)),
                        .plain("\(names.count - 1)")
                    )
                    
                case .addedUsers(let names) where names.count == 2:
                    return NSAttributedString(
                        format: "GROUP_MESSAGE_INFO_TWO_MEMBERS_ADDED".localized(),
                        .font(names[0], .boldSystemFont(ofSize: Values.verySmallFontSize)),
                        .font(names[1], .boldSystemFont(ofSize: Values.verySmallFontSize))
                    )
                    
                case .addedUsers(let names):
                    return NSAttributedString(
                        format: "GROUP_MESSAGE_INFO_MEMBER_ADDED".localized(),
                        .font((names.first ?? "Anonymous"), .boldSystemFont(ofSize: Values.verySmallFontSize))
                    )
                    
                case .removedUsers(let names) where names.count > 2:
                    return NSAttributedString(
                        format: "GROUP_MESSAGE_INFO_MULTIPLE_MEMBERS_REMOVED".localized(),
                        .font(names[0], .boldSystemFont(ofSize: Values.verySmallFontSize)),
                        .plain("\(names.count - 1)")
                    )
                    
                case .removedUsers(let names) where names.count == 2:
                    return NSAttributedString(
                        format: "GROUP_MESSAGE_INFO_TWO_MEMBERS_REMOVED".localized(),
                        .font(names[0], .boldSystemFont(ofSize: Values.verySmallFontSize)),
                        .font(names[1], .boldSystemFont(ofSize: Values.verySmallFontSize))
                    )
                    
                case .removedUsers(let names):
                    return NSAttributedString(
                        format: "GROUP_MESSAGE_INFO_MEMBER_REMOVED".localized(),
                        .font((names.first ?? "Anonymous"), .boldSystemFont(ofSize: Values.verySmallFontSize))
                    )
                    
                case .memberLeft(let name):
                    return NSAttributedString(
                        format: "GROUP_MESSAGE_INFO_MEMBER_LEFT".localized(),
                        .font(name, .boldSystemFont(ofSize: Values.verySmallFontSize))
                    )
                    
                case .promotedUsers(let names) where names.count > 2:
                    return NSAttributedString(
                        format: "GROUP_MESSAGE_INFO_MULTIPLE_MEMBERS_PROMOTED".localized(),
                        .font(names[0], .boldSystemFont(ofSize: Values.verySmallFontSize)),
                        .plain("\(names.count - 1)")
                    )
                    
                case .promotedUsers(let names) where names.count == 2:
                    return NSAttributedString(
                        format: "GROUP_MESSAGE_INFO_TWO_MEMBERS_PROMOTED".localized(),
                        .font(names[0], .boldSystemFont(ofSize: Values.verySmallFontSize)),
                        .font(names[1], .boldSystemFont(ofSize: Values.verySmallFontSize))
                    )
                    
                case .promotedUsers(let names):
                    return NSAttributedString(
                        format: "GROUP_MESSAGE_INFO_MEMBER_PROMOTED".localized(),
                        .font((names.first ?? "Anonymous"), .boldSystemFont(ofSize: Values.verySmallFontSize))
                    )
            }
        }
        
        func infoString(using dependencies: Dependencies) -> String? {
            guard let messageInfoData: Data = try? JSONEncoder(using: dependencies).encode(self) else { return nil }
            
            return String(data: messageInfoData, encoding: .utf8)
        }
    }
}

public extension [ClosedGroup.RemovableGroupData] {
    static var allData: [ClosedGroup.RemovableGroupData] { ClosedGroup.RemovableGroupData.allCases }
    static var noData: [ClosedGroup.RemovableGroupData] { [] }
}
