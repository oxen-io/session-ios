// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionSnodeKit
import SessionUtilitiesKit

public extension Message {
    enum Origin: Hashable {
        case swarm(
            publicKey: String,
            namespace: SnodeAPI.Namespace,
            serverHash: String,
            serverTimestampMs: Int64,
            serverExpirationTimestamp: TimeInterval
        )
        case community(
            openGroupId: String,
            sender: String,
            timestamp: TimeInterval,
            messageServerId: Int64
        )
        case openGroupInbox(
            timestamp: TimeInterval,
            messageServerId: Int64,
            serverPublicKey: String,
            senderId: String,
            recipientId: String
        )
        
        public var isConfigNamespace: Bool {
            switch self {
                case .swarm(_, let namespace, _, _, _): return namespace.isConfigNamespace
                default: return false
            }
        }
        
        public var serverHash: String? {
            switch self {
                case .swarm(_, _, let serverHash, _, _): return serverHash
                default: return nil
            }
        }
        
        public var serverExpirationTimestamp: TimeInterval? {
            switch self {
                case .swarm(_, _, _, _, let expirationTimestamp): return expirationTimestamp
                default: return nil
            }
        }
    }
}
