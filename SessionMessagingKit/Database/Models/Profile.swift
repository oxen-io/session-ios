// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionUtilitiesKit

/// This type is duplicate in both the database and within the LibSession config so should only ever have it's data changes via the
/// `updateAllAndConfig` function. Updating it elsewhere could result in issues with syncing data between devices
public struct Profile: Codable, Identifiable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible, CustomStringConvertible, Differentiable {
    public static var databaseTableName: String { "profile" }
    internal static let interactionForeignKey = ForeignKey([Columns.id], to: [Interaction.Columns.authorId])
    internal static let contactForeignKey = ForeignKey([Columns.id], to: [Contact.Columns.id])
    internal static let groupMemberForeignKey = ForeignKey([Columns.id], to: [GroupMember.Columns.profileId])
    internal static let contact = hasOne(Contact.self, using: contactForeignKey)
    public static let groupMembers = hasMany(GroupMember.self, using: groupMemberForeignKey)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        
        case name
        case lastNameUpdate
        case nickname
        
        case profilePictureUrl
        case profilePictureFileName
        case profileEncryptionKey
        case lastProfilePictureUpdate
        
        case blocksCommunityMessageRequests
        case lastBlocksCommunityMessageRequests
    }

    /// The id for the user that owns the profile (Note: This could be a sessionId, a blindedId or some future variant)
    public let id: String
    
    /// The name of the contact. Use this whenever you need the "real", underlying name of a user (e.g. when sending a message).
    public let name: String
    
    /// The timestamp (in seconds since epoch) that the name was last updated
    public let lastNameUpdate: TimeInterval?
    
    /// A custom name for the profile set by the current user
    public let nickname: String?

    /// The URL from which to fetch the contact's profile picture.
    public let profilePictureUrl: String?

    /// The file name of the contact's profile picture on local storage.
    public let profilePictureFileName: String?

    /// The key with which the profile is encrypted.
    public let profileEncryptionKey: Data?
    
    /// The timestamp (in seconds since epoch) that the profile picture was last updated
    public let lastProfilePictureUpdate: TimeInterval?
    
    /// A flag indicating whether this profile has reported that it blocks community message requests
    public let blocksCommunityMessageRequests: Bool?
    
    /// The timestamp (in seconds since epoch) that the `blocksCommunityMessageRequests` setting was last updated
    public let lastBlocksCommunityMessageRequests: TimeInterval?
    
    // MARK: - Initialization
    
    public init(
        id: String,
        name: String,
        lastNameUpdate: TimeInterval? = nil,
        nickname: String? = nil,
        profilePictureUrl: String? = nil,
        profilePictureFileName: String? = nil,
        profileEncryptionKey: Data? = nil,
        lastProfilePictureUpdate: TimeInterval? = nil,
        blocksCommunityMessageRequests: Bool? = nil,
        lastBlocksCommunityMessageRequests: TimeInterval? = nil
    ) {
        self.id = id
        self.name = name
        self.lastNameUpdate = lastNameUpdate
        self.nickname = nickname
        self.profilePictureUrl = profilePictureUrl
        self.profilePictureFileName = profilePictureFileName
        self.profileEncryptionKey = profileEncryptionKey
        self.lastProfilePictureUpdate = lastProfilePictureUpdate
        self.blocksCommunityMessageRequests = blocksCommunityMessageRequests
        self.lastBlocksCommunityMessageRequests = lastBlocksCommunityMessageRequests
    }
    
    // MARK: - Description
    
    public var description: String {
        """
        Profile(
            name: \(name),
            profileKey: \(profileEncryptionKey?.description ?? "null"),
            profilePictureUrl: \(profilePictureUrl ?? "null")
        )
        """
    }
}

// MARK: - Codable

public extension Profile {
    init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        var profileKey: Data?
        var profilePictureUrl: String?
        
        // If we have both a `profileKey` and a `profilePicture` then the key MUST be valid
        if
            let profileKeyData: Data = try? container.decode(Data?.self, forKey: .profileEncryptionKey),
            let profilePictureUrlValue: String = try? container.decode(String?.self, forKey: .profilePictureUrl)
        {
            profileKey = profileKeyData
            profilePictureUrl = profilePictureUrlValue
        }
        
        self = Profile(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            lastNameUpdate: try? container.decode(TimeInterval?.self, forKey: .lastNameUpdate),
            nickname: try? container.decode(String?.self, forKey: .nickname),
            profilePictureUrl: profilePictureUrl,
            profilePictureFileName: try? container.decode(String?.self, forKey: .profilePictureFileName),
            profileEncryptionKey: profileKey,
            lastProfilePictureUpdate: try? container.decode(TimeInterval?.self, forKey: .lastProfilePictureUpdate),
            blocksCommunityMessageRequests: try? container.decode(Bool?.self, forKey: .blocksCommunityMessageRequests),
            lastBlocksCommunityMessageRequests: try? container.decode(TimeInterval?.self, forKey: .lastBlocksCommunityMessageRequests)
        )
    }
    
    func encode(to encoder: Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(lastNameUpdate, forKey: .lastNameUpdate)
        try container.encodeIfPresent(nickname, forKey: .nickname)
        try container.encodeIfPresent(profilePictureUrl, forKey: .profilePictureUrl)
        try container.encodeIfPresent(profilePictureFileName, forKey: .profilePictureFileName)
        try container.encodeIfPresent(profileEncryptionKey, forKey: .profileEncryptionKey)
        try container.encodeIfPresent(lastProfilePictureUpdate, forKey: .lastProfilePictureUpdate)
        try container.encodeIfPresent(blocksCommunityMessageRequests, forKey: .blocksCommunityMessageRequests)
        try container.encodeIfPresent(lastBlocksCommunityMessageRequests, forKey: .lastBlocksCommunityMessageRequests)
    }
}

// MARK: - Protobuf

public extension Profile {
    static func fromProto(_ proto: SNProtoDataMessage, id: String) -> Profile? {
        guard let profileProto = proto.profile, let displayName = profileProto.displayName else { return nil }
        
        var profileKey: Data?
        var profilePictureUrl: String?
        let sentTimestamp: TimeInterval = (proto.hasTimestamp ? (TimeInterval(proto.timestamp) / 1000) : 0)
        
        // If we have both a `profileKey` and a `profilePicture` then the key MUST be valid
        if let profileKeyData: Data = proto.profileKey, profileProto.profilePicture != nil {
            profileKey = profileKeyData
            profilePictureUrl = profileProto.profilePicture
        }
        
        return Profile(
            id: id,
            name: displayName,
            lastNameUpdate: sentTimestamp,
            nickname: nil,
            profilePictureUrl: profilePictureUrl,
            profilePictureFileName: nil,
            profileEncryptionKey: profileKey,
            lastProfilePictureUpdate: sentTimestamp,
            blocksCommunityMessageRequests: (proto.hasBlocksCommunityMessageRequests ? proto.blocksCommunityMessageRequests : nil),
            lastBlocksCommunityMessageRequests: (proto.hasBlocksCommunityMessageRequests ? sentTimestamp : 0)
        )
    }

    func toProto() -> SNProtoDataMessage? {
        let dataMessageProto = SNProtoDataMessage.builder()
        let profileProto = SNProtoLokiProfile.builder()
        profileProto.setDisplayName(name)
        
        if let profileKey: Data = profileEncryptionKey, let profilePictureUrl: String = profilePictureUrl {
            dataMessageProto.setProfileKey(profileKey)
            profileProto.setProfilePicture(profilePictureUrl)
        }
        
        do {
            dataMessageProto.setProfile(try profileProto.build())
            return try dataMessageProto.build()
        }
        catch {
            SNLog("Couldn't construct profile proto from: \(self).")
            return nil
        }
    }
}

// MARK: - GRDB Interactions

public extension Profile {
    static func allContactProfiles(excluding idsToExclude: Set<String> = []) -> QueryInterfaceRequest<Profile> {
        return Profile
            .filter(!idsToExclude.contains(Profile.Columns.id))
            .joining(
                required: Profile.contact
                    .filter(Contact.Columns.isApproved == true)
                    .filter(Contact.Columns.didApproveMe == true)
            )
    }
    
    static func fetchAllContactProfiles(excluding: Set<String> = [], excludeCurrentUser: Bool = true) -> [Profile] {
        return Storage.shared
            .read { db in
                // Sort the contacts by their displayName value
                try Profile
                    .allContactProfiles(
                        excluding: excluding
                            .inserting(excludeCurrentUser ? getUserHexEncodedPublicKey(db) : nil)
                    )
                    .fetchAll(db)
                    .sorted(by: { lhs, rhs -> Bool in lhs.displayName() < rhs.displayName() })
            }
            .defaulting(to: [])
    }
    
    static func displayName(_ db: Database? = nil, id: ID, threadVariant: SessionThread.Variant = .contact, customFallback: String? = nil) -> String {
        guard let db: Database = db else {
            return Storage.shared
                .read { db in displayName(db, id: id, threadVariant: threadVariant, customFallback: customFallback) }
                .defaulting(to: (customFallback ?? id))
        }
        
        let existingDisplayName: String? = (try? Profile.fetchOne(db, id: id))?
            .displayName(for: threadVariant)
        
        return (existingDisplayName ?? (customFallback ?? id))
    }
    
    static func displayNameNoFallback(_ db: Database? = nil, id: ID, threadVariant: SessionThread.Variant = .contact) -> String? {
        guard let db: Database = db else {
            return Storage.shared.read { db in displayNameNoFallback(db, id: id, threadVariant: threadVariant) }
        }
        
        return (try? Profile.fetchOne(db, id: id))?
            .displayName(for: threadVariant)
    }
    
    // MARK: - Fetch or Create
    
    private static func defaultFor(_ id: String) -> Profile {
        return Profile(
            id: id,
            name: "",
            lastNameUpdate: nil,
            nickname: nil,
            profilePictureUrl: nil,
            profilePictureFileName: nil,
            profileEncryptionKey: nil,
            lastProfilePictureUpdate: nil,
            blocksCommunityMessageRequests: nil,
            lastBlocksCommunityMessageRequests: nil
        )
    }
    
    /// Fetches or creates a Profile for the current user
    ///
    /// **Note:** This method intentionally does **not** save the newly created Profile,
    /// it will need to be explicitly saved after calling
    static func fetchOrCreateCurrentUser(_ db: Database? = nil, using dependencies: Dependencies = Dependencies()) -> Profile {
        let userPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
        
        guard let db: Database = db else {
            return dependencies.storage
                .read { db in fetchOrCreateCurrentUser(db, using: dependencies) }
                .defaulting(to: defaultFor(userPublicKey))
        }
        
        return (
            (try? Profile.fetchOne(db, id: userPublicKey)) ??
            defaultFor(userPublicKey)
        )
    }
    
    /// Fetches or creates a Profile for the specified user
    ///
    /// **Note:** This method intentionally does **not** save the newly created Profile,
    /// it will need to be explicitly saved after calling
    static func fetchOrCreate(_ db: Database, id: String) -> Profile {
        return (
            (try? Profile.fetchOne(db, id: id)) ??
            defaultFor(id)
        )
    }
}

// MARK: - Search Queries

public extension Profile {
    struct FullTextSearch: Decodable, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case nickname
            case name
        }
        
        let nickname: String?
        let name: String
    }
}

// MARK: - Convenience

public extension Profile {
    // MARK: - Truncation
    
    enum Truncation {
        case start
        case middle
        case end
    }
    
    /// A standardised mechanism for truncating a user id for a given thread
    static func truncated(id: String, threadVariant: SessionThread.Variant) -> String {
        return truncated(id: id, truncating: .middle)
    }
    
    /// A standardised mechanism for truncating a user id
    static func truncated(id: String, truncating: Truncation) -> String {
        guard id.count > 8 else { return id }
        
        switch truncating {
            case .start: return "...\(id.suffix(8))"                    //stringlint:disable
            case .middle: return "\(id.prefix(4))...\(id.suffix(4))"    //stringlint:disable
            case .end: return "\(id.prefix(8))..."                      //stringlint:disable
        }
    }
    
    /// The name to display in the UI for a given thread variant
    func displayName(for threadVariant: SessionThread.Variant = .contact) -> String {
        return Profile.displayName(for: threadVariant, id: id, name: name, nickname: nickname, suppressId: false)
    }
    
    static func displayName(
        for threadVariant: SessionThread.Variant,
        id: String,
        name: String?,
        nickname: String?,
        suppressId: Bool,
        customFallback: String? = nil
    ) -> String {
        if let nickname: String = nickname, !nickname.isEmpty { return nickname }
        
        guard let name: String = name, name != id, !name.isEmpty else {
            return (customFallback ?? Profile.truncated(id: id, threadVariant: threadVariant))
        }
        
        switch (threadVariant, suppressId) {
            case (.contact, _), (.legacyGroup, _), (.group, _), (.community, true): return name
                
            case (.community, false):
                // In open groups, where it's more likely that multiple users have the same name,
                // we display a bit of the Session ID after a user's display name for added context
                return "\(name) (\(Profile.truncated(id: id, truncating: .middle)))"
        }
    }
}
