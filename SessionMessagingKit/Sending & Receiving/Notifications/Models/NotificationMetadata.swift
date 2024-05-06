// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionSnodeKit

extension PushNotificationAPI {
    public struct NotificationMetadata: Codable {
        private enum CodingKeys: String, CodingKey {
            case accountId = "@"
            case hash = "#"
            case namespace = "n"
            case createdTimestampMs = "t"
            case expirationTimestampMs = "z"
            case dataLength = "l"
            case dataTooLong = "B"
        }
        
        /// Account ID (such as Session ID or closed group ID) where the message arrived.
        public let accountId: String
        
        /// The hash of the message in the swarm.
        public let hash: String
        
        /// The swarm namespace in which this message arrived.
        public let namespace: SnodeAPI.Namespace
        
        /// The swarm timestamp when the message was created (unix epoch milliseconds)
        public let createdTimestampMs: Int64
        
        /// The message's swarm expiry timestamp (unix epoch milliseconds)
        public let expirationTimestampMs: Int64
        
        /// The length of the message data.  This is always included, even if the message content
        /// itself was too large to fit into the push notification.
        public let dataLength: Int
        
        /// This will be `true` if the data was omitted because it was too long to fit in a push
        /// notification (around 2.5kB of raw data), in which case the push notification includes
        /// only this metadata but not the message content itself.
        public let dataTooLong: Bool
    }
}

// MARK: - Decodable

extension PushNotificationAPI.NotificationMetadata {
    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        let namespace: SnodeAPI.Namespace = SnodeAPI.Namespace(
            rawValue: try container.decode(Int.self, forKey: .namespace)
        ).defaulting(to: .unknown)
        
        self = PushNotificationAPI.NotificationMetadata(
            accountId: try container.decode(String.self, forKey: .accountId),
            hash: try container.decode(String.self, forKey: .hash),
            namespace: namespace,
            createdTimestampMs: try container.decode(Int64.self, forKey: .createdTimestampMs),
            expirationTimestampMs: try container.decode(Int64.self, forKey: .expirationTimestampMs),
            dataLength: try container.decode(Int.self, forKey: .dataLength),
            dataTooLong: ((try? container.decode(Int.self, forKey: .dataTooLong) != 0) ?? false)
        )
    }
}

// MARK: - Convenience

extension PushNotificationAPI.NotificationMetadata {
    static var invalid: PushNotificationAPI.NotificationMetadata {
        PushNotificationAPI.NotificationMetadata(
            accountId: "",
            hash: "",
            namespace: .unknown,
            createdTimestampMs: 0,
            expirationTimestampMs: 0,
            dataLength: 0,
            dataTooLong: false
        )
    }
    
    static func legacyGroupMessage(envelope: SNProtoEnvelope) throws -> PushNotificationAPI.NotificationMetadata {
        guard let publicKey: String = envelope.source else { throw MessageReceiverError.invalidMessage }
        
        return PushNotificationAPI.NotificationMetadata(
            accountId: publicKey,
            hash: "",
            namespace: .legacyClosedGroup,
            createdTimestampMs: 0,
            expirationTimestampMs: 0,
            dataLength: 0,
            dataTooLong: false
        )
    }
}
