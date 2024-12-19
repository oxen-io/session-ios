// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUIKit
import SessionUtilitiesKit

public struct GroupMember: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "groupMember" }
    internal static let openGroupForeignKey = ForeignKey([Columns.groupId], to: [OpenGroup.Columns.threadId])
    internal static let closedGroupForeignKey = ForeignKey([Columns.groupId], to: [ClosedGroup.Columns.threadId])
    public static let openGroup = belongsTo(OpenGroup.self, using: openGroupForeignKey)
    public static let closedGroup = belongsTo(ClosedGroup.self, using: closedGroupForeignKey)
    public static let profile = hasOne(Profile.self, using: Profile.groupMemberForeignKey)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case groupId
        case profileId
        case role
        case roleStatus
        case isHidden
    }
    
    public enum Role: Int, Codable, Comparable, DatabaseValueConvertible {
        case standard
        case zombie
        case moderator
        case admin
        
        public static func < (lhs: Role, rhs: Role) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    
    public enum RoleStatus: Int, Codable, DatabaseValueConvertible {
        case accepted
        case pending
        case failed
        case notSentYet
        case sending
        case pendingRemoval
        
        case unknown = 100
    }

    public let groupId: String
    public let profileId: String
    public let role: Role
    public let roleStatus: RoleStatus
    public let isHidden: Bool
    
    // MARK: - Relationships
    
    public var openGroup: QueryInterfaceRequest<OpenGroup> {
        request(for: GroupMember.openGroup)
    }
    
    public var closedGroup: QueryInterfaceRequest<ClosedGroup> {
        request(for: GroupMember.closedGroup)
    }
    
    public var profile: QueryInterfaceRequest<Profile> {
        request(for: GroupMember.profile)
    }
    
    // MARK: - Initialization
    
    public init(
        groupId: String,
        profileId: String,
        role: Role,
        roleStatus: RoleStatus,
        isHidden: Bool
    ) {
        self.groupId = groupId
        self.profileId = profileId
        self.role = role
        self.roleStatus = roleStatus
        self.isHidden = isHidden
    }
}

// MARK: - Decoding

extension GroupMember {
    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        self = GroupMember(
            groupId: try container.decode(String.self, forKey: .groupId),
            profileId: try container.decode(String.self, forKey: .profileId),
            role: try container.decode(Role.self, forKey: .role),
            // Added in `_018_GroupsRebuildChanges`
            roleStatus: ((try? container.decode(RoleStatus.self, forKey: .roleStatus)) ?? .accepted),
            // Added in `_006_FixHiddenModAdminSupport`
            isHidden: ((try? container.decode(Bool.self, forKey: .isHidden)) ?? false)
        )
    }
}

// MARK: - Convenience

public extension GroupMember {
    var statusDescription: String? {
        switch (role, roleStatus) {
            case (_, .accepted): return nil                 // Nothing for "final" state
            case (.zombie, _), (.moderator, _): return nil  // Unused cases
            case (.standard, .notSentYet): return "groupInviteNotSent".localized()
            case (.standard, .sending): return "groupInviteSending".putNumber(1).localized()
            case (.standard, .pending): return "groupInviteSent".localized()
            case (.standard, .failed): return "groupInviteFailed".localized()
            case (_, .pendingRemoval): return "groupPendingRemoval".localized()
            case (.standard, .unknown): return "groupInviteStatusUnknown".localized()
            case (.admin, .notSentYet): return "adminPromotionNotSent".localized()
            case (.admin, .sending): return "adminSendingPromotion".putNumber(1).localized()
            case (.admin, .pending): return "adminPromotionSent".localized()
            case (.admin, .failed): return "adminPromotionFailed".localized()
            case (.admin, .unknown): return "adminPromotionStatusUnknown".localized()
        }
    }
    
    var statusDescriptionColor: ThemeValue {
        switch (role, roleStatus) {
            case (.zombie, _), (.moderator, _): return .textPrimary
            case (_, .failed): return .danger
            default: return .textPrimary
        }
    }
}

extension GroupMember: ProfileAssociated {
    public var profileIcon: ProfilePictureView.ProfileIcon {
        switch role {
            case .moderator, .admin: return .crown
            default: return .none
        }
    }
    
    public func itemDescription(using dependencies: Dependencies) -> String? { return statusDescription }
    public func itemDescriptionColor(using dependencies: Dependencies) -> ThemeValue { return statusDescriptionColor }
    
    public static func compare(
        lhs: WithProfile<GroupMember>,
        rhs: WithProfile<GroupMember>
    ) -> Bool {
        let isUpdatedGroup: Bool = (((try? SessionId.Prefix(from: lhs.value.groupId)) ?? .group) == .group)
        let lhsDisplayName: String = (lhs.profile?.displayName(for: .contact))
            .defaulting(to: Profile.truncated(id: lhs.profileId, threadVariant: .contact))
        let rhsDisplayName: String = (rhs.profile?.displayName(for: .contact))
            .defaulting(to: Profile.truncated(id: rhs.profileId, threadVariant: .contact))
        
        // Legacy groups have a different sorting behaviour
        guard isUpdatedGroup else {
            switch (lhs.value.role, rhs.value.role) {
                case (.zombie, .standard), (.zombie, .moderator), (.zombie, .admin): return true
                case (.standard, .zombie), (.moderator, .zombie), (.admin, .zombie): return false
                default:
                    guard lhs.value.role == rhs.value.role else { return lhs.value.role < rhs.value.role }
                    
                    return (lhsDisplayName.lowercased() < rhsDisplayName.lowercased())
            }
        }
        
        /// We want to sort the member list so the most important info is at the top of the list, this means that we want to prioritise
        /// • Invite failed, sorted as NameSortingOrder
        /// • Invite not sent, sorted as NameSortingOrder
        /// • Sending invite, sorted as NameSortingOrder
        /// • Invite sent, sorted as NameSortingOrder
        /// • Invite status unknown, sorted as NameSortingOrder
        /// • Pending removal, sorted as NameSortingOrder
        /// • Admin promotion failed, sorted as NameSortingOrder
        /// • Admin promotion not sent, sorted as NameSortingOrder
        /// • Sending admin promotion, sorted as NameSortingOrder
        /// • Admin promotion sent, sorted as NameSortingOrder
        /// • Admin promotion status unknown, sorted as NameSortingOrder
        /// • Admin, sorted as NameSortingOrder
        /// • Member, sorted as NameSortingOrder
        ///
        /// And the current user should appear at the top of their respective group
        let userSessionId: SessionId = lhs.currentUserSessionId
        let desiredStatusOrder: [RoleStatus] = [
            .failed, .notSentYet, .sending, .pending, .unknown, .pendingRemoval
        ]
        
        /// If the role and status match then we want to sort by current user, no-name members by id, then by name
        guard lhs.value.role != rhs.value.role || lhs.value.roleStatus != rhs.value.roleStatus else {
            switch (lhs.profileId, rhs.profileId, lhs.profile?.name, rhs.profile?.name) {
                case (userSessionId.hexString, _, _, _): return true
                case (_, userSessionId.hexString, _, _): return false
                case (_, _, .none, .some): return true
                case (_, _, .some, .none): return false
                case (_, _, .none, .none): return (lhsDisplayName.lowercased() < rhsDisplayName.lowercased())
                case (_, _, .some, .some): return (lhsDisplayName.lowercased() < rhsDisplayName.lowercased())
            }
        }
        
        switch (lhs.value.role, lhs.value.roleStatus, rhs.value.role, rhs.value.roleStatus) {
            /// Non-accepted standard before admin
            case (.standard, .failed, .admin, _), (.standard, .notSentYet, .admin, _),
                (.standard, .sending, .admin, _), (.standard, .pending, .admin, _),
                (.standard, .unknown, .admin, _), (.standard, .pendingRemoval, .admin, _):
                return true

            /// Non-accepted admin before accepted standard
            case (.admin, .failed, .standard, .accepted), (.admin, .notSentYet, .standard, .accepted),
                (.admin, .sending, .standard, .accepted), (.admin, .pending, .standard, .accepted),
                (.admin, .unknown, .standard, .accepted), (.admin, .pendingRemoval, .standard, .accepted):
                return true
            
            /// Accepted admin before accepted standard
            case (.admin, .accepted, .standard, .accepted): return true
                
            /// Otherwise we should order based on the status position in `desiredStatusOrder`
            default:
                let lhsIndex = desiredStatusOrder.firstIndex(of: lhs.value.roleStatus)
                let rhsIndex = desiredStatusOrder.firstIndex(of: rhs.value.roleStatus)
                
                return ((lhsIndex ?? desiredStatusOrder.endIndex) < rhsIndex ?? desiredStatusOrder.endIndex)
        }
    }
}
