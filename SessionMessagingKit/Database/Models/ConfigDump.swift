// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

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
    }
    
    public enum Variant: String, Codable, DatabaseValueConvertible {
        case userProfile
        case contacts
        case convoInfoVolatile
        case userGroups
        
        case invalid    // Should only be used when failing to convert a namespace to a variant
    }
    
    /// The type of config this dump is for
    public let variant: Variant
    
    /// The public key for the swarm this dump is for
    ///
    /// **Note:** For user config items this will be an empty string
    public let publicKey: String
    
    /// The data for this dump
    public let data: Data
    
    /// When the configDump was created in milliseconds since epoch
    public let timestampMs: Int64
    
    internal init(
        variant: Variant,
        publicKey: String,
        data: Data,
        timestampMs: Int64
    ) {
        self.variant = variant
        self.publicKey = publicKey
        self.data = data
        self.timestampMs = timestampMs
    }
}

// MARK: - Convenience

public extension ConfigDump.Variant {
    static let userVariants: [ConfigDump.Variant] = [
        .userProfile, .contacts, .convoInfoVolatile, .userGroups
    ]
    
    init(namespace: SnodeAPI.Namespace) {
        switch namespace {
            case .configUserProfile: self = .userProfile
            case .configContacts: self = .contacts
            case .configConvoInfoVolatile: self = .convoInfoVolatile
            case .configUserGroups: self = .userGroups
            
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
                
            case .invalid: return SnodeAPI.Namespace.unknown
        }
    }
}

// MARK: - CustomStringConvertible

extension ConfigDump.Variant: CustomStringConvertible {
    public var description: String {
        switch self {
            case .userProfile: return "userProfile"
            case .contacts: return "contacts"
            case .convoInfoVolatile: return "convoInfoVolatile"
            case .userGroups: return "userGroups"
                
            case .invalid: return "invalid"
        }
    }
}
