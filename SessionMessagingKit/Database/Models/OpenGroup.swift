// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUtilitiesKit

public struct OpenGroup: Codable, Equatable, Hashable, Identifiable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "openGroup" }
    internal static let threadForeignKey = ForeignKey([Columns.threadId], to: [SessionThread.Columns.id])
    private static let thread = belongsTo(SessionThread.self, using: threadForeignKey)
    public static let members = hasMany(GroupMember.self, using: GroupMember.openGroupForeignKey)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case threadId
        case server
        case roomToken
        case publicKey
        case name
        case isActive
        case roomDescription = "description"
        case imageId
        @available(*, deprecated, message: "use 'DisplayPictureManager' instead") case imageData
        case userCount
        case infoUpdates
        case sequenceNumber
        case inboxLatestMessageId
        case outboxLatestMessageId
        case pollFailureCount
        case permissions
        
        case displayPictureFilename
        case lastDisplayPictureUpdate
    }
    
    public struct Permissions: OptionSet, Codable, DatabaseValueConvertible, Hashable {
        public let rawValue: UInt16
        
        public init(rawValue: UInt16) {
            self.rawValue = rawValue
        }
        
        public init(roomInfo: OpenGroupAPI.RoomPollInfo) {
            var permissions: Permissions = []
            
            if roomInfo.read { permissions.insert(.read) }
            if roomInfo.write { permissions.insert(.write) }
            if roomInfo.upload { permissions.insert(.upload) }
            
            self.init(rawValue: permissions.rawValue)
        }
        
        public func toString() -> String {
            return ""
                .appending(self.contains(.read) ? "r" : "-")
                .appending(self.contains(.write) ? "w" : "-")
                .appending(self.contains(.upload) ? "u" : "-")
        }

        static let read: Permissions = Permissions(rawValue: 1 << 0)
        static let write: Permissions = Permissions(rawValue: 1 << 1)
        static let upload: Permissions = Permissions(rawValue: 1 << 2)
        
        static let all: Permissions = [ .read, .write, .upload ]
    }
    
    /// The Community public key takes up 32 bytes
    static let pubkeyByteLength: Int = 32
    
    public var id: String { threadId }  // Identifiable
    
    /// The id for the thread this open group belongs to
    ///
    /// **Note:** This value will always be `\(server).\(room)` (This needs it’s own column to
    /// allow for db joining to the Thread table)
    public let threadId: String
    
    /// The server for the group
    ///
    /// **Note:** The `server` value will always be in lowercase
    public let server: String
    
    /// The specific room on the server for the group
    ///
    /// **Note:** In order to support the default open group query we need an OpenGroup entry in
    /// the database, for this entry the `roomToken` value will be an empty string so we can ignore
    /// it when polling
    public let roomToken: String
    
    /// The public key for the group
    public let publicKey: String
    
    /// Flag indicating whether this is an OpenGroup the user has actively joined (we store inactive
    /// open groups so we can display them in the UI but they won't be polled for)
    public let isActive: Bool
    
    /// The name for the group
    public let name: String
    
    /// The description for the room
    public let roomDescription: String?
    
    /// The ID with which the image can be retrieved from the server
    public let imageId: String?
    
    /// The image for the group
    @available(*, deprecated, message: "use 'DisplayPictureManager' instead")
    public let imageData: Data? = nil
    
    /// The number of users in the group
    public let userCount: Int64
    
    /// Monotonic room information counter that increases each time the room's metadata changes
    public let infoUpdates: Int64
    
    /// Sequence number for the most recently received message from the open group
    public let sequenceNumber: Int64
    
    /// The id of the most recently received inbox message
    ///
    /// **Note:** This value is unique per server rather than per room (ie. all rooms in the same server will be
    /// updated whenever this value changes)
    public let inboxLatestMessageId: Int64
    
    /// The id of the most recently received outbox message
    ///
    /// **Note:** This value is unique per server rather than per room (ie. all rooms in the same server will be
    /// updated whenever this value changes)
    public let outboxLatestMessageId: Int64
    
    /// The number of times this room has failed to poll since the last successful poll
    public let pollFailureCount: Int64
    
    /// The permissions this room has for current user
    public let permissions: Permissions?
    
    /// The file name of the groups's display picture on local storage.
    public let displayPictureFilename: String?
    
    /// The timestamp (in seconds since epoch) that the display picture was last updated
    public let lastDisplayPictureUpdate: TimeInterval?

    // MARK: - Relationships
    
    public var thread: QueryInterfaceRequest<SessionThread> {
        request(for: OpenGroup.thread)
    }

    public var moderatorIds: QueryInterfaceRequest<GroupMember> {
        request(for: OpenGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.moderator)
    }
    
    public var adminIds: QueryInterfaceRequest<GroupMember> {
        request(for: OpenGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.admin)
    }
    
    // MARK: - Initialization
    
    public init(
        server: String,
        roomToken: String,
        publicKey: String,
        isActive: Bool,
        name: String,
        roomDescription: String? = nil,
        imageId: String? = nil,
        userCount: Int64,
        infoUpdates: Int64,
        sequenceNumber: Int64 = 0,
        inboxLatestMessageId: Int64 = 0,
        outboxLatestMessageId: Int64 = 0,
        pollFailureCount: Int64 = 0,
        permissions: Permissions? = nil,
        displayPictureFilename: String? = nil,
        lastDisplayPictureUpdate: TimeInterval? = nil
    ) {
        self.threadId = OpenGroup.idFor(roomToken: roomToken, server: server)
        self.server = server.lowercased()
        self.roomToken = roomToken
        self.publicKey = publicKey
        self.isActive = isActive
        self.name = name
        self.roomDescription = roomDescription
        self.imageId = imageId
        self.userCount = userCount
        self.infoUpdates = infoUpdates
        self.sequenceNumber = sequenceNumber
        self.inboxLatestMessageId = inboxLatestMessageId
        self.outboxLatestMessageId = outboxLatestMessageId
        self.pollFailureCount = pollFailureCount
        self.permissions = permissions
        self.displayPictureFilename = displayPictureFilename
        self.lastDisplayPictureUpdate = lastDisplayPictureUpdate
    }
}

// MARK: - GRDB Interactions

public extension OpenGroup {
    static func fetchOrCreate(
        _ db: Database,
        server: String,
        roomToken: String,
        publicKey: String
    ) -> OpenGroup {
        guard let existingGroup: OpenGroup = try? OpenGroup.fetchOne(db, id: OpenGroup.idFor(roomToken: roomToken, server: server)) else {
            return OpenGroup(
                server: server,
                roomToken: roomToken,
                publicKey: publicKey,
                isActive: false,
                name: roomToken,    // Default the name to the `roomToken` until we get retrieve the actual name
                roomDescription: nil,
                imageId: nil,
                userCount: 0,
                infoUpdates: 0
            )
        }
        
        return existingGroup
    }
}

// MARK: - Search Queries

public extension OpenGroup {
    struct FullTextSearch: Decodable, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case name
        }
        
        let name: String
    }
}

// MARK: - Convenience

public extension OpenGroup {
    static func idFor(roomToken: String, server: String) -> String {
        // Always force the server to lowercase
        return "\(server.lowercased()).\(roomToken)"
    }
}

extension OpenGroup: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "\(name) (Server: \(server), Room: \(roomToken))" }
    public var debugDescription: String {
        return """
        OpenGroup(
            server: \"\(server)\",
            roomToken: \"\(roomToken)\",
            id: \"\(id)\",
            publicKey: \"\(publicKey)\",
            isActive: \(isActive),
            name: \"\(name)\",
            roomDescription: \(roomDescription.map { "\"\($0)\"" } ?? "null"),
            imageId: \(imageId ?? "null"),
            userCount: \(userCount),
            infoUpdates: \(infoUpdates),
            sequenceNumber: \(sequenceNumber),
            inboxLatestMessageId: \(inboxLatestMessageId),
            outboxLatestMessageId: \(outboxLatestMessageId),
            pollFailureCount: \(pollFailureCount),
            permissions: \(permissions?.toString() ?? "---"),
            displayPictureFilename: \(displayPictureFilename.map { "\"\($0)\"" } ?? "null"),
            lastDisplayPictureUpdate: \(lastDisplayPictureUpdate ?? 0)
        )
        """
    }
}
