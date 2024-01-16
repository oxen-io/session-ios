// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This type is duplicate in both the database and within the LibSession config so should only ever have it's data changes via the
/// `updateAllAndConfig` function. Updating it elsewhere could result in issues with syncing data between devices
public struct Contact: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "contact" }
    internal static let threadForeignKey = ForeignKey([Columns.id], to: [SessionThread.Columns.id])
    public static let profile = hasOne(Profile.self, using: Profile.contactForeignKey)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        
        case isTrusted
        case isApproved
        case isBlocked
        case lastKnownClientVersion
        case didApproveMe
        case hasBeenBlocked
    }

    /// The id for the contact (Note: This could be a sessionId, a blindedId or some future variant)
    public let id: String
    
    /// This flag is used to determine whether we should auto-download files sent by this contact.
    public let isTrusted: Bool
    
    /// This flag is used to determine whether message requests from this contact are approved
    public let isApproved: Bool
    
    /// This flag is used to determine whether message requests from this contact are blocked
    public let isBlocked: Bool
    
    /// The last known client version represented by pre defined enum values
    public let lastKnownClientVersion: FeatureVersion?
    
    /// This flag is used to determine whether this contact has approved the current users message request
    public let didApproveMe: Bool
    
    /// This flag is used to determine whether this contact has ever been blocked (will be included in the config message if so)
    public let hasBeenBlocked: Bool
    
    // MARK: - Relationships
    
    public var profile: QueryInterfaceRequest<Profile> {
        request(for: Contact.profile)
    }
    
    // MARK: - Initialization
    
    public init(
        _ db: Database? = nil,
        id: String,
        isTrusted: Bool = false,
        isApproved: Bool = false,
        isBlocked: Bool = false,
        lastKnownClientVersion: FeatureVersion? = nil,
        didApproveMe: Bool = false,
        hasBeenBlocked: Bool = false,
        using dependencies: Dependencies = Dependencies()
    ) {
        self.id = id
        self.isTrusted = (
            isTrusted ||
            id == getUserSessionId(db, using: dependencies).hexString  // Always trust ourselves
        )
        self.isApproved = isApproved
        self.isBlocked = isBlocked
        self.lastKnownClientVersion = lastKnownClientVersion
        self.didApproveMe = didApproveMe
        self.hasBeenBlocked = (isBlocked || hasBeenBlocked)
    }
}

// MARK: - GRDB Interactions

public extension Contact {
    /// Fetches or creates a Contact for the specified user
    ///
    /// **Note:** This method intentionally does **not** save the newly created Contact,
    /// it will need to be explicitly saved after calling
    static func fetchOrCreate(_ db: Database, id: ID) -> Contact {
        return ((try? fetchOne(db, id: id)) ?? Contact(db, id: id))
    }
}

// MARK: - Convenience

extension Contact: ProfileAssociated {
    public var profileId: String { id }
    
    public static func compare(lhs: WithProfile<Contact>, rhs: WithProfile<Contact>) -> Bool {
        let lhsDisplayName: String = (lhs.profile?.displayName(for: .contact))
            .defaulting(to: Profile.truncated(id: lhs.profileId, threadVariant: .contact))
        let rhsDisplayName: String = (rhs.profile?.displayName(for: .contact))
            .defaulting(to: Profile.truncated(id: rhs.profileId, threadVariant: .contact))
        
        return (lhsDisplayName < rhsDisplayName)
    }
}
