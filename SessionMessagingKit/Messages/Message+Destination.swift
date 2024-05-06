// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

public extension Message {
    enum Destination: Codable, Hashable {
        /// A one-to-one destination where `publicKey` is a `standard` `SessionId`
        case contact(publicKey: String)
        
        /// A message that was originally sent to another user but needs to be replicated to the current users swarm
        case syncMessage(originalRecipientPublicKey: String)
        
        /// A one-to-one destination where `groupPublicKey` is a `standard` `SessionId` for legacy groups
        /// and a `group` `SessionId` for updated groups
        case closedGroup(groupPublicKey: String)
        
        /// A message directed to an open group
        case openGroup(
            roomToken: String,
            server: String,
            whisperTo: String? = nil,
            whisperMods: Bool = false
        )
        
        /// A message directed to an open group inbox
        case openGroupInbox(server: String, openGroupPublicKey: String, blindedPublicKey: String)
        
        public var defaultNamespace: SnodeAPI.Namespace? {
            switch self {
                case .contact, .syncMessage: return .`default`
                case .closedGroup(let groupId) where (try? SessionId.Prefix(from: groupId)) == .group:
                    return .groupMessages
                
                case .closedGroup: return .legacyClosedGroup
                case .openGroup, .openGroupInbox: return nil
            }
        }
        
        public static func from(
            _ db: Database,
            threadId: String,
            threadVariant: SessionThread.Variant
        ) throws -> Message.Destination {
            switch threadVariant {
                case .contact:
                    let prefix: SessionId.Prefix? = try? SessionId.Prefix(from: threadId)
                    
                    if prefix == .blinded15 || prefix == .blinded25 {
                        guard let lookup: BlindedIdLookup = try? BlindedIdLookup.fetchOne(db, id: threadId) else {
                            preconditionFailure("Attempting to send message to blinded id without the Open Group information")
                        }
                        
                        return .openGroupInbox(
                            server: lookup.openGroupServer,
                            openGroupPublicKey: lookup.openGroupPublicKey,
                            blindedPublicKey: threadId
                        )
                    }
                    
                    return .contact(publicKey: threadId)
                
                case .legacyGroup, .group: return .closedGroup(groupPublicKey: threadId)
                
                case .community:
                    guard let openGroup: OpenGroup = try OpenGroup.fetchOne(db, id: threadId) else {
                        throw StorageError.objectNotFound
                    }
                    
                    return .openGroup(roomToken: openGroup.roomToken, server: openGroup.server)
            }
        }
    }
}
