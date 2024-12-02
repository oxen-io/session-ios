// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

public struct ConfigDump: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "configDump" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case variant
        case publicKey
        case data
        case timestampMs
        
        /// Renamed accessor for `publicKey` column to reduce ambiguity
        static var sessionId: CodingKeys { publicKey }
    }
    
    public enum Variant: String, Codable, DatabaseValueConvertible, CaseIterable {
        case userProfile
        case contacts
        case convoInfoVolatile
        case userGroups
        
        case groupInfo
        case groupMembers
        case groupKeys
        
        case invalid    // Should only be used when failing to convert a namespace to a variant
    }
    
    /// The type of config this dump is for
    public let variant: Variant
    
    /// This has been renamed to `sessionId` to reduce ambiguity
    private let publicKey: String
    
    /// The sessionId for the swarm this dump is for
    ///
    /// **Note:** For user config items this will be an empty string
    public var sessionId: SessionId {
        switch variant {
            case .userProfile, .contacts, .convoInfoVolatile, .userGroups:
                return SessionId(.standard, hex: publicKey)
                
            case .groupInfo, .groupMembers, .groupKeys:
                return SessionId(.group, hex: publicKey)
                
            case .invalid:
                return SessionId(((try? SessionId.Prefix(from: publicKey)) ?? .standard), hex: publicKey)
        }
    }
    
    /// The data for this dump
    public let data: Data
    
    /// When the configDump was created in milliseconds since epoch
    public let timestampMs: Int64
    
    internal init(
        variant: Variant,
        sessionId: String,
        data: Data,
        timestampMs: Int64
    ) {
        self.variant = variant
        self.publicKey = sessionId
        self.data = data
        self.timestampMs = timestampMs
    }
}

// MARK: - Convenience

public extension ConfigDump.Variant {
    static let userVariants: Set<ConfigDump.Variant> = [
        .userProfile, .contacts, .convoInfoVolatile, .userGroups
    ]
    static let groupVariants: Set<ConfigDump.Variant> = [
        .groupInfo, .groupMembers, .groupKeys
    ]
    
    init(namespace: SnodeAPI.Namespace) {
        switch namespace {
            case .configUserProfile: self = .userProfile
            case .configContacts: self = .contacts
            case .configConvoInfoVolatile: self = .convoInfoVolatile
            case .configUserGroups: self = .userGroups
                
            case .configGroupInfo: self = .groupInfo
            case .configGroupMembers: self = .groupMembers
            case .configGroupKeys: self = .groupKeys
            
            default: self = .invalid
        }
    }
    
    /// Config messages should last for 30 days rather than the standard 14
    var ttl: UInt64 { 30 * 24 * 60 * 60 * 1000 }
    
    var namespace: SnodeAPI.Namespace {
        switch self {
            case .userProfile: return SnodeAPI.Namespace.configUserProfile
            case .contacts: return SnodeAPI.Namespace.configContacts
            case .convoInfoVolatile: return SnodeAPI.Namespace.configConvoInfoVolatile
            case .userGroups: return SnodeAPI.Namespace.configUserGroups
            
            case .groupInfo: return SnodeAPI.Namespace.configGroupInfo
            case .groupMembers: return SnodeAPI.Namespace.configGroupMembers
            case .groupKeys: return SnodeAPI.Namespace.configGroupKeys
                
            case .invalid: return SnodeAPI.Namespace.unknown
        }
    }
    
    /// This value defines the order that the ConfigDump records should be loaded in, we need to load the `groupKeys`
    /// config _after_ the `groupInfo` and `groupMembers` configs as it requires those to be passed as arguments
    var loadOrder: Int {
        switch self {
            case .groupKeys: return 1
            default: return 0
        }
    }
    
    /// This value defines the order that the config messages should be sent in, we need to send the `groupKeys`
    /// config _before_ the `groupInfo` and `groupMembers` configs as they both get encrypted with the latest key
    /// and we want to avoid weird edge-cases
    var sendOrder: Int {
        switch self {
            case .groupKeys: return 0
            default: return 1
        }
    }
}

// MARK: - CustomStringConvertible

// stringlint:ignore_contents
extension ConfigDump.Variant: CustomStringConvertible {
    public var description: String {
        switch self {
            case .userProfile: return "userProfile"
            case .contacts: return "contacts"
            case .convoInfoVolatile: return "convoInfoVolatile"
            case .userGroups: return "userGroups"
            
            case .groupInfo: return "groupInfo"
            case .groupMembers: return "groupMembers"
            case .groupKeys: return "groupKeys"
            
            case .invalid: return "invalid"
        }
    }
}
