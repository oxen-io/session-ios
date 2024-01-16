// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

public enum OpenGroupAPI {
    // MARK: - Settings
    
    public static let legacyDefaultServerIP = "116.203.70.33"
    public static let defaultServer = "https://open.getsession.org"
    public static let defaultServerPublicKey = "a03c383cf63c3c4efe67acc52112a6dd734b3a946b9545f488aaa93da7991238"

    public static let workQueue = DispatchQueue(label: "OpenGroupAPI.workQueue", qos: .userInitiated) // It's important that this is a serial queue

    // MARK: - Batching & Polling
    
    /// This is a convenience method which calls `/batch` with a pre-defined set of requests used to update an Open
    /// Group, currently this will retrieve:
    /// - Capabilities for the server
    /// - For each room:
    ///    - Poll Info
    ///    - Messages (includes additions and deletions)
    /// - Inbox for the server
    /// - Outbox for the server
    public static func preparedPoll(
        _ db: Database,
        server: String,
        hasPerformedInitialPoll: Bool,
        timeSinceLastPoll: TimeInterval,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<HTTP.BatchResponseMap<Endpoint>> {
        let lastInboxMessageId: Int64 = (try? OpenGroup
            .select(.inboxLatestMessageId)
            .filter(OpenGroup.Columns.server == server)
            .asRequest(of: Int64.self)
            .fetchOne(db))
            .defaulting(to: 0)
        let lastOutboxMessageId: Int64 = (try? OpenGroup
            .select(.outboxLatestMessageId)
            .filter(OpenGroup.Columns.server == server)
            .asRequest(of: Int64.self)
            .fetchOne(db))
            .defaulting(to: 0)
        let capabilities: Set<Capability.Variant> = (try? Capability
            .select(.variant)
            .filter(Capability.Columns.openGroupServer == server)
            .asRequest(of: Capability.Variant.self)
            .fetchSet(db))
            .defaulting(to: [])
        let openGroupRooms: [OpenGroup] = (try? OpenGroup
            .filter(OpenGroup.Columns.server == server.lowercased()) // Note: The `OpenGroup` type converts to lowercase in init
            .filter(OpenGroup.Columns.isActive == true)
            .filter(OpenGroup.Columns.roomToken != "")
            .fetchAll(db))
            .defaulting(to: [])

        let preparedRequests: [any ErasedPreparedRequest] = [
            try preparedCapabilities(
                db,
                server: server,
                using: dependencies
            )
        ].appending(
            // Per-room requests
            contentsOf: try openGroupRooms
                .flatMap { openGroup -> [any ErasedPreparedRequest] in
                    let shouldRetrieveRecentMessages: Bool = (
                        openGroup.sequenceNumber == 0 || (
                            // If it's the first poll for this launch and it's been longer than
                            // 'maxInactivityPeriod' then just retrieve recent messages instead
                            // of trying to get all messages since the last one retrieved
                            !hasPerformedInitialPoll &&
                            timeSinceLastPoll > OpenGroupAPI.Poller.maxInactivityPeriod
                        )
                    )
                    
                    return [
                        try preparedRoomPollInfo(
                            db,
                            lastUpdated: openGroup.infoUpdates,
                            for: openGroup.roomToken,
                            on: openGroup.server,
                            using: dependencies
                        ),
                        (shouldRetrieveRecentMessages ?
                            try preparedRecentMessages(
                                db,
                                in: openGroup.roomToken,
                                on: openGroup.server,
                                using: dependencies
                            ) :
                            try preparedMessagesSince(
                                db,
                                seqNo: openGroup.sequenceNumber,
                                in: openGroup.roomToken,
                                on: openGroup.server,
                                using: dependencies
                            )
                        )
                    ]
                }
        )
        .appending(
            contentsOf: (
                // The 'inbox' and 'outbox' only work with blinded keys so don't bother polling them if not blinded
                !capabilities.contains(.blind) ? [] :
                [
                    // Inbox (only check the inbox if the user want's community message requests)
                    (!db[.checkForCommunityMessageRequests] ? nil :
                        (lastInboxMessageId == 0 ?
                            try preparedInbox(db, on: server, using: dependencies) :
                            try preparedInboxSince(db, id: lastInboxMessageId, on: server, using: dependencies)
                        )
                    ),
                    
                    // Outbox
                    (lastOutboxMessageId == 0 ?
                        try preparedOutbox(db, on: server, using: dependencies) :
                        try preparedOutboxSince(db, id: lastOutboxMessageId, on: server, using: dependencies)
                    ),
                ].compactMap { $0 }
            )
        )
        
        return try OpenGroupAPI
            .preparedBatch(
                db,
                server: server,
                requests: preparedRequests,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Submits multiple requests wrapped up in a single request, runs them all, then returns the result of each one
    ///
    /// Requests are performed independently, that is, if one fails the others will still be attempted - there is no guarantee on the order in which
    /// requests will be carried out (for sequential, related requests invoke via `/sequence` instead)
    ///
    /// For contained subrequests that specify a body (i.e. POST or PUT requests) exactly one of `json`, `b64`, or `bytes` must be provided
    /// with the request body.
    private static func preparedBatch(
        _ db: Database,
        server: String,
        requests: [any ErasedPreparedRequest],
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<HTTP.BatchResponseMap<Endpoint>> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request(
                    db,
                    method: .post,
                    server: server,
                    endpoint: .batch,
                    body: HTTP.BatchRequest(requests: requests)
                ),
                responseType: HTTP.BatchResponseMap<Endpoint>.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// This is like `/batch`, except that it guarantees to perform requests sequentially in the order provided and will stop processing requests
    /// if the previous request returned a non-`2xx` response
    ///
    /// For example, this can be used to ban and delete all of a user's messages by sequencing the ban followed by the `delete_all`: if the
    /// ban fails (e.g. because permission is denied) then the `delete_all` will not occur. The batch body and response are identical to the
    /// `/batch` endpoint; requests that are not carried out because of an earlier failure will have a response code of `412` (Precondition Failed)."
    ///
    /// Like `/batch`, responses are returned in the same order as requests, but unlike `/batch` there may be fewer elements in the response
    /// list (if requests were stopped because of a non-2xx response) - In such a case, the final, non-2xx response is still included as the final
    /// response value
    private static func preparedSequence(
        _ db: Database,
        server: String,
        requests: [any ErasedPreparedRequest],
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<HTTP.BatchResponseMap<Endpoint>> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request(
                    db,
                    method: .post,
                    server: server,
                    endpoint: .sequence,
                    body: HTTP.BatchRequest(requests: requests)
                ),
                responseType: HTTP.BatchResponseMap<Endpoint>.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    // MARK: - Capabilities
    
    /// Return the list of server features/capabilities
    ///
    /// Optionally takes a `required` parameter containing a comma-separated list of capabilites; if any are not satisfied a 412 (Precondition Failed)
    /// response will be returned with missing requested capabilities in the `missing` key
    ///
    /// Eg. `GET /capabilities` could return `{"capabilities": ["sogs", "batch"]}` `GET /capabilities?required=magic,batch`
    /// could return: `{"capabilities": ["sogs", "batch"], "missing": ["magic"]}`
    public static func preparedCapabilities(
        _ db: Database,
        server: String,
        forceBlinded: Bool = false,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<Capabilities> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    server: server,
                    endpoint: .capabilities,
                    forceBlinded: forceBlinded
                ),
                responseType: Capabilities.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    // MARK: - Room
    
    /// Returns a list of available rooms on the server
    ///
    /// Rooms to which the user does not have access (e.g. because they are banned, or the room has restricted access permissions) are not included
    public static func preparedRooms(
        _ db: Database,
        server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<[Room]> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    server: server,
                    endpoint: .rooms
                ),
                responseType: [Room].self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Returns the details of a single room
    public static func preparedRoom(
        _ db: Database,
        for roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<Room> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    server: server,
                    endpoint: .room(roomToken)
                ),
                responseType: Room.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Polls a room for metadata updates
    ///
    /// The endpoint polls room metadata for this room, always including the instantaneous room details (such as the user's permission and current
    /// number of active users), and including the full room metadata if the room's info_updated counter has changed from the provided value
    public static func preparedRoomPollInfo(
        _ db: Database,
        lastUpdated: Int64,
        for roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<RoomPollInfo> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    server: server,
                    endpoint: .roomPollInfo(roomToken, lastUpdated)
                ),
                responseType: RoomPollInfo.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    public typealias CapabilitiesAndRoomResponse = (
        capabilities: (info: ResponseInfoType, data: Capabilities),
        room: (info: ResponseInfoType, data: Room)
    )
    
    /// This is a convenience method which constructs a `/sequence` of the `capabilities` and `room`  requests, refer to those
    /// methods for the documented behaviour of each method
    public static func preparedCapabilitiesAndRoom(
        _ db: Database,
        for roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<CapabilitiesAndRoomResponse> {
        return try OpenGroupAPI
            .preparedSequence(
                db,
                server: server,
                requests: [
                    // Get the latest capabilities for the server (in case it's a new server or the
                    // cached ones are stale)
                    preparedCapabilities(db, server: server, using: dependencies),
                    preparedRoom(db, for: roomToken, on: server, using: dependencies)
                ],
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
            .map { (info: ResponseInfoType, response: HTTP.BatchResponseMap<Endpoint>) -> CapabilitiesAndRoomResponse in
                let maybeCapabilities: HTTP.BatchSubResponse<Capabilities>? = (response[.capabilities] as? HTTP.BatchSubResponse<Capabilities>)
                let maybeRoomResponse: Any? = response.data
                    .first(where: { key, _ in
                        switch key {
                            case .room: return true
                            default: return false
                        }
                    })
                    .map { _, value in value }
                let maybeRoom: HTTP.BatchSubResponse<Room>? = (maybeRoomResponse as? HTTP.BatchSubResponse<Room>)
                
                guard
                    let capabilitiesInfo: ResponseInfoType = maybeCapabilities,
                    let capabilities: Capabilities = maybeCapabilities?.body,
                    let roomInfo: ResponseInfoType = maybeRoom,
                    let room: Room = maybeRoom?.body
                else { throw HTTPError.parsingFailed }
                
                return (
                    capabilities: (info: capabilitiesInfo, data: capabilities),
                    room: (info: roomInfo, data: room)
                )
            }
    }
    
    public typealias CapabilitiesAndRoomsResponse = (
        capabilities: (info: ResponseInfoType, data: Capabilities),
        rooms: (info: ResponseInfoType, data: [Room])
    )
    
    /// This is a convenience method which constructs a `/sequence` of the `capabilities` and `rooms`  requests, refer to those
    /// methods for the documented behaviour of each method
    public static func preparedCapabilitiesAndRooms(
        _ db: Database,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<CapabilitiesAndRoomsResponse> {
        return try OpenGroupAPI
            .preparedSequence(
                db,
                server: server,
                requests: [
                    // Get the latest capabilities for the server (in case it's a new server or the
                    // cached ones are stale)
                    preparedCapabilities(db, server: server, using: dependencies),
                    preparedRooms(db, server: server, using: dependencies)
                ],
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
            .map { (info: ResponseInfoType, response: HTTP.BatchResponseMap<Endpoint>) -> CapabilitiesAndRoomsResponse in
                let maybeCapabilities: HTTP.BatchSubResponse<Capabilities>? = (response[.capabilities] as? HTTP.BatchSubResponse<Capabilities>)
                let maybeRooms: HTTP.BatchSubResponse<[Room]>? = response.data
                    .first(where: { key, _ in
                        switch key {
                            case .rooms: return true
                            default: return false
                        }
                    })
                    .map { _, value in value as? HTTP.BatchSubResponse<[Room]> }
                
                guard
                    let capabilitiesInfo: ResponseInfoType = maybeCapabilities,
                    let capabilities: Capabilities = maybeCapabilities?.body,
                    let roomsInfo: ResponseInfoType = maybeRooms,
                    let rooms: [Room] = maybeRooms?.body
                else { throw HTTPError.parsingFailed }
                
                return (
                    capabilities: (info: capabilitiesInfo, data: capabilities),
                    rooms: (info: roomsInfo, data: rooms)
                )
            }
    }
    
    // MARK: - Messages
    
    /// Posts a new message to a room
    public static func preparedSend(
        _ db: Database,
        plaintext: Data,
        to roomToken: String,
        on server: String,
        whisperTo: String?,
        whisperMods: Bool,
        fileIds: [String]?,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<Message> {
        let signResult: (publicKey: String, signature: [UInt8]) = try sign(
            db,
            messageBytes: plaintext.bytes,
            for: server,
            fallbackSigningType: .standard,
            using: dependencies
        )
        
        return try OpenGroupAPI
            .prepareRequest(
                request: Request(
                    db,
                    method: .post,
                    server: server,
                    endpoint: Endpoint.roomMessage(roomToken),
                    body: SendMessageRequest(
                        data: plaintext,
                        signature: Data(signResult.signature),
                        whisperTo: whisperTo,
                        whisperMods: whisperMods,
                        fileIds: fileIds
                    )
                ),
                responseType: Message.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Returns a single message by ID
    public static func preparedMessage(
        _ db: Database,
        id: Int64,
        in roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<Message> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    server: server,
                    endpoint: .roomMessageIndividual(roomToken, id: id)
                ),
                responseType: Message.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Edits a message, replacing its existing content with new content and a new signature
    ///
    /// **Note:** This edit may only be initiated by the creator of the post, and the poster must currently have write permissions in the room
    public static func preparedMessageUpdate(
        _ db: Database,
        id: Int64,
        plaintext: Data,
        fileIds: [Int64]?,
        in roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<NoResponse> {
        let signResult: (publicKey: String, signature: [UInt8]) = try sign(
            db,
            messageBytes: plaintext.bytes,
            for: server,
            fallbackSigningType: .standard,
            using: dependencies
        )
        
        return try OpenGroupAPI
            .prepareRequest(
                request: Request(
                    db,
                    method: .put,
                    server: server,
                    endpoint: Endpoint.roomMessageIndividual(roomToken, id: id),
                    body: UpdateMessageRequest(
                        data: plaintext,
                        signature: Data(signResult.signature),
                        fileIds: fileIds
                    )
                ),
                responseType: NoResponse.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Remove a message by its message id
    public static func preparedMessageDelete(
        _ db: Database,
        id: Int64,
        in roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<NoResponse> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    method: .delete,
                    server: server,
                    endpoint: .roomMessageIndividual(roomToken, id: id)
                ),
                responseType: NoResponse.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Retrieves recent messages posted to this room
    ///
    /// Returns the most recent limit messages (100 if no limit is given). This only returns extant messages, and always returns the latest
    /// versions: that is, deleted message indicators and pre-editing versions of messages are not returned. Messages are returned in order
    /// from most recent to least recent
    public static func preparedRecentMessages(
        _ db: Database,
        in roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<[Failable<Message>]> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    server: server,
                    endpoint: .roomMessagesRecent(roomToken),
                    queryParameters: [
                        .updateTypes: UpdateTypes.reaction.rawValue,
                        .reactors: "5"
                    ]
                ),
                responseType: [Failable<Message>].self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Retrieves messages from the room preceding a given id.
    ///
    /// This endpoint is intended to be used with .../recent to allow a client to retrieve the most recent messages and then walk backwards
    /// through batches of ever-older messages. As with .../recent, messages are returned in order from most recent to least recent.
    ///
    /// As with .../recent, this endpoint does not include deleted messages and always returns the current version, for edited messages.
    public static func preparedMessagesBefore(
        _ db: Database,
        messageId: Int64,
        in roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<[Failable<Message>]> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    server: server,
                    endpoint: .roomMessagesBefore(roomToken, id: messageId),
                    queryParameters: [
                        .updateTypes: UpdateTypes.reaction.rawValue,
                        .reactors: "5"
                    ]
                ),
                responseType: [Failable<Message>].self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Retrieves message updates from a room. This is the main message polling endpoint in SOGS.
    ///
    /// This endpoint retrieves new, edited, and deleted messages or message reactions posted to this room since the given message
    /// sequence counter. Returns limit messages at a time (100 if no limit is given). Returned messages include any new messages, updates
    /// to existing messages (i.e. edits), and message deletions made to the room since the given update id. Messages are returned in "update"
    /// order, that is, in the order in which the change was applied to the room, from oldest the newest.
    public static func preparedMessagesSince(
        _ db: Database,
        seqNo: Int64,
        in roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<[Failable<Message>]> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    server: server,
                    endpoint: .roomMessagesSince(roomToken, seqNo: seqNo),
                    queryParameters: [
                        .updateTypes: UpdateTypes.reaction.rawValue,
                        .reactors: "5"
                    ]
                ),
                responseType: [Failable<Message>].self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Deletes all messages from a given sessionId within the provided rooms (or globally) on a server
    ///
    /// - Parameters:
    ///   - sessionId: The sessionId (either standard or blinded) of the user whose messages should be deleted
    ///
    ///   - roomToken: The room token from which the messages should be deleted
    ///
    ///     The invoking user **must** be a moderator of the given room or an admin if trying to delete the messages
    ///     of another admin.
    ///
    ///   - server: The server to delete messages from
    ///
    ///   - dependencies: Injected dependencies (used for unit testing)
    public static func preparedMessagesDeleteAll(
        _ db: Database,
        sessionId: String,
        in roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<NoResponse> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    method: .delete,
                    server: server,
                    endpoint: Endpoint.roomDeleteMessages(roomToken, sessionId: sessionId)
                ),
                responseType: NoResponse.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    // MARK: - Reactions
    
    /// Returns the list of all reactors who have added a particular reaction to a particular message.
    public static func preparedReactors(
        _ db: Database,
        emoji: String,
        id: Int64,
        in roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<NoResponse> {
        /// URL(String:) won't convert raw emojis, so need to do a little encoding here.
        /// The raw emoji will come back when calling url.path
        guard let encodedEmoji: String = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw OpenGroupAPIError.invalidEmoji
        }
        
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    method: .get,
                    server: server,
                    endpoint: .reactors(roomToken, id: id, emoji: encodedEmoji)
                ),
                responseType: NoResponse.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Adds a reaction to the given message in this room. The user must have read access in the room.
    ///
    /// Reactions are short strings of 1-12 unicode codepoints, typically emoji (or character sequences to produce an emoji variant,
    /// such as 👨🏿‍🦰, which is composed of 4 unicode "characters" but usually renders as a single emoji "Man: Dark Skin Tone, Red Hair").
    public static func preparedReactionAdd(
        _ db: Database,
        emoji: String,
        id: Int64,
        in roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<ReactionAddResponse> {
        /// URL(String:) won't convert raw emojis, so need to do a little encoding here.
        /// The raw emoji will come back when calling url.path
        guard let encodedEmoji: String = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw OpenGroupAPIError.invalidEmoji
        }
        
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    method: .put,
                    server: server,
                    endpoint: .reaction(roomToken, id: id, emoji: encodedEmoji)
                ),
                responseType: ReactionAddResponse.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Removes a reaction from a post this room. The user must have read access in the room. This only removes the user's own reaction
    /// but does not affect the reactions of other users.
    public static func preparedReactionDelete(
        _ db: Database,
        emoji: String,
        id: Int64,
        in roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<ReactionRemoveResponse> {
        /// URL(String:) won't convert raw emojis, so need to do a little encoding here.
        /// The raw emoji will come back when calling url.path
        guard let encodedEmoji: String = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw OpenGroupAPIError.invalidEmoji
        }
        
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    method: .delete,
                    server: server,
                    endpoint: .reaction(roomToken, id: id, emoji: encodedEmoji)
                ),
                responseType: ReactionRemoveResponse.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Removes all reactions of all users from a post in this room. The calling must have moderator permissions in the room. This endpoint
    /// can either remove a single reaction (e.g. remove all 🍆 reactions) by specifying it after the message id (following a /), or remove all
    /// reactions from the post by not including the /<reaction> suffix of the URL.
    public static func preparedReactionDeleteAll(
        _ db: Database,
        emoji: String,
        id: Int64,
        in roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<ReactionRemoveAllResponse> {
        /// URL(String:) won't convert raw emojis, so need to do a little encoding here.
        /// The raw emoji will come back when calling url.path
        guard let encodedEmoji: String = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw OpenGroupAPIError.invalidEmoji
        }
        
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    method: .delete,
                    server: server,
                    endpoint: .reactionDelete(roomToken, id: id, emoji: encodedEmoji)
                ),
                responseType: ReactionRemoveAllResponse.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    // MARK: - Pinning
    
    /// Adds a pinned message to this room
    ///
    /// **Note:** Existing pinned messages are not removed: the new message is added to the pinned message list (If you want to remove existing
    /// pins then build a sequence request that first calls .../unpin/all)
    ///
    /// The user must have admin (not just moderator) permissions in the room in order to pin messages
    ///
    /// Pinned messages that are already pinned will be re-pinned (that is, their pin timestamp and pinning admin user will be updated) - because pinned
    /// messages are returned in pinning-order this allows admins to order multiple pinned messages in a room by re-pinning (via this endpoint) in the
    /// order in which pinned messages should be displayed
    public static func preparedPinMessage(
        _ db: Database,
        id: Int64,
        in roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<NoResponse> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    method: .post,
                    server: server,
                    endpoint: .roomPinMessage(roomToken, id: id)
                ),
                responseType: NoResponse.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Remove a message from this room's pinned message list
    ///
    /// The user must have `admin` (not just `moderator`) permissions in the room
    public static func preparedUnpinMessage(
        _ db: Database,
        id: Int64,
        in roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<NoResponse> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    method: .post,
                    server: server,
                    endpoint: .roomUnpinMessage(roomToken, id: id)
                ),
                responseType: NoResponse.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Removes _all_ pinned messages from this room
    ///
    /// The user must have `admin` (not just `moderator`) permissions in the room
    public static func preparedUnpinAll(
        _ db: Database,
        in roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<NoResponse> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    method: .post,
                    server: server,
                    endpoint: .roomUnpinAll(roomToken)
                ),
                responseType: NoResponse.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    // MARK: - Files
    
    /// Uploads a file to a room.
    ///
    /// Takes the request as binary in the body and takes other properties (specifically the suggested filename) via submitted headers.
    ///
    /// The user must have upload and posting permissions for the room. The file will have a default lifetime of 1 hour, which is extended
    /// to 15 days (by default) when a post referencing the uploaded file is posted or edited.
    public static func preparedUploadFile(
        _ db: Database,
        bytes: [UInt8],
        fileName: String? = nil,
        to roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<FileUploadResponse> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request(
                    db,
                    method: .post,
                    server: server,
                    endpoint: Endpoint.roomFile(roomToken),
                    headers: [
                        .contentDisposition: [ "attachment", fileName.map { "filename=\"\($0)\"" } ]
                            .compactMap{ $0 }
                            .joined(separator: "; "),
                        .contentType: "application/octet-stream"
                    ],
                    body: bytes
                ),
                responseType: FileUploadResponse.self,
                timeout: FileServerAPI.fileUploadTimeout,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Retrieves a file uploaded to the room.
    ///
    /// Retrieves a file via its numeric id from the room, returning the file content directly as the binary response body. The file's suggested
    /// filename (as provided by the uploader) is provided in the Content-Disposition header, if available.
    public static func preparedDownloadFile(
        _ db: Database,
        fileId: String,
        from roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<Data> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    server: server,
                    endpoint: .roomFileIndividual(roomToken, fileId)
                ),
                responseType: Data.self,
                timeout: FileServerAPI.fileDownloadTimeout,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    // MARK: - Inbox/Outbox (Message Requests)

    /// Retrieves all of the user's current DMs (up to limit)
    ///
    /// **Note:** `inbox` will return a `304` with an empty response if no messages (hence the optional return type)
    public static func preparedInbox(
        _ db: Database,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<[DirectMessage]?> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    server: server,
                    endpoint: .inbox
                ),
                responseType: [DirectMessage]?.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Polls for any DMs received since the given id, this method will return a `304` with an empty response if there are no messages
    ///
    /// **Note:** `inboxSince` will return a `304` with an empty response if no messages (hence the optional return type)
    public static func preparedInboxSince(
        _ db: Database,
        id: Int64,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<[DirectMessage]?> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    server: server,
                    endpoint: .inboxSince(id: id)
                ),
                responseType: [DirectMessage]?.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Remove all message requests from inbox, this methrod will return the number of messages deleted
    public static func preparedClearInbox(
        _ db: Database,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<DeleteInboxResponse> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    method: .delete,
                    server: server,
                    endpoint: .inbox
                ),
                responseType: DeleteInboxResponse.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Delivers a direct message to a user via their blinded Session ID
    ///
    /// The body of this request is a JSON object containing a message key with a value of the encrypted-then-base64-encoded message to deliver
    public static func preparedSend(
        _ db: Database,
        ciphertext: Data,
        toInboxFor blindedSessionId: String,
        on server: String,
        using dependencies: Dependencies
    ) throws -> HTTP.PreparedRequest<SendDirectMessageResponse> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request(
                    db,
                    method: .post,
                    server: server,
                    endpoint: Endpoint.inboxFor(sessionId: blindedSessionId),
                    body: SendDirectMessageRequest(
                        message: ciphertext
                    )
                ),
                responseType: SendDirectMessageResponse.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Retrieves all of the user's sent DMs (up to limit)
    ///
    /// **Note:** `outbox` will return a `304` with an empty response if no messages (hence the optional return type)
    public static func preparedOutbox(
        _ db: Database,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<[DirectMessage]?> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    server: server,
                    endpoint: .outbox
                ),
                responseType: [DirectMessage]?.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Polls for any DMs sent since the given id, this method will return a `304` with an empty response if there are no messages
    ///
    /// **Note:** `outboxSince` will return a `304` with an empty response if no messages (hence the optional return type)
    public static func preparedOutboxSince(
        _ db: Database,
        id: Int64,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<[DirectMessage]?> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request<NoBody, Endpoint>(
                    db,
                    server: server,
                    endpoint: .outboxSince(id: id)
                ),
                responseType: [DirectMessage]?.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    // MARK: - Users
    
    /// Applies a ban of a user from specific rooms, or from the server globally
    ///
    /// The invoking user must have `moderator` (or `admin`) permission in all given rooms when specifying rooms, and must be a
    /// `globalModerator` (or `globalAdmin`) if using the global parameter
    ///
    /// **Note:** The user's messages are not deleted by this request - In order to ban and delete all messages use the `/sequence` endpoint to
    /// bundle a `/user/.../ban` with a `/user/.../deleteMessages` request
    ///
    /// - Parameters:
    ///   - sessionId: The sessionId (either standard or blinded) of the user whose messages should be deleted
    ///
    ///   - timeout: Value specifying a time limit on the ban, in seconds
    ///
    ///     The applied ban will expire and be removed after the given interval - If omitted (or `null`) then the ban is permanent
    ///
    ///     If this endpoint is called multiple times then the timeout of the last call takes effect (eg. a permanent ban can be replaced
    ///     with a time-limited ban by calling the endpoint again with a timeout value, and vice versa)
    ///
    ///   - roomTokens: List of one or more room tokens from which the user should be banned from
    ///
    ///     The invoking user **must** be a moderator of all of the given rooms.
    ///
    ///     This may be set to the single-element list `["*"]` to ban the user from all rooms in which the current user has moderator
    ///     permissions (the call will succeed if the calling user is a moderator in at least one channel)
    ///
    ///     **Note:** You can ban from all rooms on a server by providing a `nil` value for this parameter (the invoking user must be a
    ///     global moderator in order to add a global ban)
    ///
    ///   - server: The server to delete messages from
    ///
    ///   - dependencies: Injected dependencies (used for unit testing)
    public static func preparedUserBan(
        _ db: Database,
        sessionId: String,
        for timeout: TimeInterval? = nil,
        from roomTokens: [String]? = nil,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<NoResponse> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request(
                    db,
                    method: .post,
                    server: server,
                    endpoint: Endpoint.userBan(sessionId),
                    body: UserBanRequest(
                        rooms: roomTokens,
                        global: (roomTokens == nil ? true : nil),
                        timeout: timeout
                    )
                ),
                responseType: NoResponse.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Removes a user ban from specific rooms, or from the server globally
    ///
    /// The invoking user must have `moderator` (or `admin`) permission in all given rooms when specifying rooms, and must be a global server `moderator`
    /// (or `admin`) if using the `global` parameter
    ///
    /// **Note:** Room and global bans are independent: if a user is banned globally and has a room-specific ban then removing the global ban does not remove
    /// the room specific ban, and removing the room-specific ban does not remove the global ban (to fully unban a user globally and from all rooms, submit a
    /// `/sequence` request with a global unban followed by a "rooms": ["*"] unban)
    ///
    /// - Parameters:
    ///   - sessionId: The sessionId (either standard or blinded) of the user whose messages should be deleted
    ///
    ///   - roomTokens: List of one or more room tokens from which the user should be unbanned from
    ///
    ///     The invoking user **must** be a moderator of all of the given rooms.
    ///
    ///     This may be set to the single-element list `["*"]` to unban the user from all rooms in which the current user has moderator
    ///     permissions (the call will succeed if the calling user is a moderator in at least one channel)
    ///
    ///     **Note:** You can ban from all rooms on a server by providing a `nil` value for this parameter
    ///
    ///   - server: The server to delete messages from
    ///
    ///   - dependencies: Injected dependencies (used for unit testing)
    public static func preparedUserUnban(
        _ db: Database,
        sessionId: String,
        from roomTokens: [String]?,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<NoResponse> {
        return try OpenGroupAPI
            .prepareRequest(
                request: Request(
                    db,
                    method: .post,
                    server: server,
                    endpoint: Endpoint.userUnban(sessionId),
                    body: UserUnbanRequest(
                        rooms: roomTokens,
                        global: (roomTokens == nil ? true : nil)
                    )
                ),
                responseType: NoResponse.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// Appoints or removes a moderator or admin
    ///
    /// This endpoint is used to appoint or remove moderator/admin permissions either for specific rooms or for server-wide global moderator permissions
    ///
    /// Admins/moderators of rooms can only be appointed or removed by a user who has admin permissions in the room (including global admins)
    ///
    /// Global admins/moderators may only be appointed by a global admin
    ///
    /// The admin/moderator paramters interact as follows:
    /// - **admin=true, moderator omitted:** This adds admin permissions, which automatically also implies moderator permissions
    /// - **admin=true, moderator=true:** Exactly the same as above
    /// - **admin=false, moderator=true:** Removes any existing admin permissions from the rooms (or globally), if present, and adds
    /// moderator permissions to the rooms/globally (if not already present)
    /// - **admin=false, moderator omitted:** This removes admin permissions but leaves moderator permissions, if present (this
    /// effectively "downgrades" an admin to a moderator).  Unlike the above this does **not** add moderator permissions to matching rooms
    /// if not already present
    /// - **moderator=true, admin omitted:** Adds moderator permissions to the given rooms (or globally), if not already present.  If
    /// the user already has admin permissions this does nothing (that is, admin permission is *not* removed, unlike the above)
    /// - **moderator=false, admin omitted:** This removes moderator **and** admin permissions from all given rooms (or globally)
    /// - **moderator=false, admin=false:** Exactly the same as above
    /// - **moderator=false, admin=true:** This combination is **not permitted** (because admin permissions imply moderator
    /// permissions) and will result in Bad Request error if given
    ///
    /// - Parameters:
    ///   - sessionId: The sessionId (either standard or blinded) of the user to modify the permissions of
    ///
    ///   - moderator: Value indicating that this user should have moderator permissions added (true), removed (false), or left alone (null)
    ///
    ///   - admin: Value indicating that this user should have admin permissions added (true), removed (false), or left alone (null)
    ///
    ///     Granting admin permission automatically includes granting moderator permission (and thus it is an error to use admin=true with
    ///     moderator=false)
    ///
    ///   - visible: Value indicating whether the moderator/admin should be made publicly visible as a moderator/admin of the room(s)
    ///   (if true) or hidden (false)
    ///
    ///     Hidden moderators/admins still have all the same permissions as visible moderators/admins, but are visible only to other
    ///     moderators/admins; regular users in the room will not know their moderator status
    ///
    ///   - roomTokens: List of one or more room tokens to which the permission changes should be applied
    ///
    ///     The invoking user **must** be an admin of all of the given rooms.
    ///
    ///     This may be set to the single-element list `["*"]` to add or remove the moderator from all rooms in which the current user has admin
    ///     permissions (the call will succeed if the calling user is an admin in at least one channel)
    ///
    ///     **Note:** You can specify a change to global permisisons by providing a `nil` value for this parameter
    ///
    ///   - server: The server to perform the permission changes on
    ///
    ///   - dependencies: Injected dependencies (used for unit testing)
    public static func preparedUserModeratorUpdate(
        _ db: Database,
        sessionId: String,
        moderator: Bool? = nil,
        admin: Bool? = nil,
        visible: Bool,
        for roomTokens: [String]?,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<NoResponse> {
        guard (moderator != nil && admin == nil) || (moderator == nil && admin != nil) else {
            throw HTTPError.generic
        }
        
        return try OpenGroupAPI
            .prepareRequest(
                request: Request(
                    db,
                    method: .post,
                    server: server,
                    endpoint: Endpoint.userModerator(sessionId),
                    body: UserModeratorRequest(
                        rooms: roomTokens,
                        global: (roomTokens == nil ? true : nil),
                        moderator: moderator,
                        admin: admin,
                        visible: visible
                    )
                ),
                responseType: NoResponse.self,
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    /// This is a convenience method which constructs a `/sequence` of the `userBan` and `userDeleteMessages`  requests, refer to those
    /// methods for the documented behaviour of each method
    public static func preparedUserBanAndDeleteAllMessages(
        _ db: Database,
        sessionId: String,
        in roomToken: String,
        on server: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<HTTP.BatchResponseMap<Endpoint>> {
        return try OpenGroupAPI
            .preparedSequence(
                db,
                server: server,
                requests: [
                    preparedUserBan(
                        db,
                        sessionId: sessionId,
                        from: [roomToken],
                        on: server,
                        using: dependencies
                    ),
                    preparedMessagesDeleteAll(
                        db,
                        sessionId: sessionId,
                        in: roomToken,
                        on: server,
                        using: dependencies
                    )
                ],
                using: dependencies
            )
            .signed(db, with: OpenGroupAPI.signRequest, using: dependencies)
    }
    
    // MARK: - Authentication
    
    /// Sign a message to be sent to SOGS (handles both un-blinded and blinded signing based on the server capabilities)
    private static func sign(
        _ db: Database,
        messageBytes: [UInt8],
        for serverName: String,
        fallbackSigningType signingType: SessionId.Prefix,
        forceBlinded: Bool = false,
        using dependencies: Dependencies
    ) throws -> (publicKey: String, signature: [UInt8]) {
        guard
            let userEdKeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db, using: dependencies),
            let serverPublicKey: String = try? OpenGroup
                .select(.publicKey)
                .filter(OpenGroup.Columns.server == serverName.lowercased())
                .asRequest(of: String.self)
                .fetchOne(db)
        else { throw OpenGroupAPIError.signingFailed }
        
        let capabilities: Set<Capability.Variant> = (try? Capability
            .select(.variant)
            .filter(Capability.Columns.openGroupServer == serverName.lowercased())
            .asRequest(of: Capability.Variant.self)
            .fetchSet(db))
            .defaulting(to: [])

        // If we have no capabilities or if the server supports blinded keys then sign using the blinded key
        if forceBlinded || capabilities.isEmpty || capabilities.contains(.blind) {
            guard
                let blinded15KeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                    .blinded15KeyPair(serverPublicKey: serverPublicKey, ed25519SecretKey: userEdKeyPair.secretKey)
                ),
                let signatureResult: [UInt8] = dependencies[singleton: .crypto].generate(
                    .signatureBlind15(message: messageBytes, serverPublicKey: serverPublicKey, ed25519SecretKey: userEdKeyPair.secretKey)
                )
            else {
                throw OpenGroupAPIError.signingFailed
            }

            return (
                publicKey: SessionId(.blinded15, publicKey: blinded15KeyPair.publicKey).hexString,
                signature: signatureResult
            )
        }

        // Otherwise sign using the fallback type
        switch signingType {
            case .unblinded:
                guard
                    let signature: Authentication.Signature = dependencies[singleton: .crypto].generate(
                        .signature(message: messageBytes, ed25519SecretKey: userEdKeyPair.secretKey)
                    ),
                    case .standard(let signatureResult) = signature
                else { throw OpenGroupAPIError.signingFailed }

                return (
                    publicKey: SessionId(.unblinded, publicKey: userEdKeyPair.publicKey).hexString,
                    signature: signatureResult
                )
                
            // Default to using the 'standard' key
            default:
                guard
                    let userKeyPair: KeyPair = Identity.fetchUserKeyPair(db, using: dependencies),
                    let signatureResult: [UInt8] = dependencies[singleton: .crypto].generate(
                        .signatureXed25519(data: messageBytes, curve25519PrivateKey: userKeyPair.secretKey)
                    )
                else { throw OpenGroupAPIError.signingFailed }
                
                return (
                    publicKey: SessionId(.standard, publicKey: userKeyPair.publicKey).hexString,
                    signature: signatureResult
                )
        }
    }
    
    /// Sign a request to be sent to SOGS (handles both un-blinded and blinded signing based on the server capabilities)
    private static func signRequest<R>(
        _ db: Database,
        preparedRequest: HTTP.PreparedRequest<R>,
        using dependencies: Dependencies = Dependencies()
    ) throws -> URLRequest {
        guard
            let url: URL = preparedRequest.request.url,
            let target: HTTP.OpenGroupAPITarget = preparedRequest.target as? HTTP.OpenGroupAPITarget
        else { throw OpenGroupAPIError.signingFailed }
        
        var updatedRequest: URLRequest = preparedRequest.request
        let path: String = url.path
            .appending(url.query.map { value in "?\(value)" })
        let method: String = preparedRequest.method.rawValue
        let timestamp: Int = Int(floor(dependencies.dateNow.timeIntervalSince1970))
        let serverPublicKeyData: Data = Data(hex: target.serverPublicKey)
        
        guard
            !serverPublicKeyData.isEmpty,
            let nonce: [UInt8] = dependencies[singleton: .crypto].generate(.randomBytes(16)),
            let timestampBytes: [UInt8] = "\(timestamp)".data(using: .ascii).map({ Array($0) })
        else { throw OpenGroupAPIError.signingFailed }
        
        /// Get a hash of any body content
        let bodyHash: [UInt8]? = {
            guard let body: Data = preparedRequest.request.httpBody else { return nil }
            
            return dependencies[singleton: .crypto].generate(.hash(message: body.bytes, length: 64))
        }()
        
        /// Generate the signature message
        /// "ServerPubkey || Nonce || Timestamp || Method || Path || Blake2b Hash(Body)
        ///     `ServerPubkey`
        ///     `Nonce`
        ///     `Timestamp` is the bytes of an ascii decimal string
        ///     `Method`
        ///     `Path`
        ///     `Body` is a Blake2b hash of the data (if there is a body)
        let messageBytes: [UInt8] = serverPublicKeyData.bytes
            .appending(contentsOf: nonce)
            .appending(contentsOf: timestampBytes)
            .appending(contentsOf: method.bytes)
            .appending(contentsOf: path.bytes)
            .appending(contentsOf: bodyHash ?? [])
        
        /// Sign the above message
        let signResult: (publicKey: String, signature: [UInt8]) = try sign(
            db,
            messageBytes: messageBytes,
            for: target.server,
            fallbackSigningType: .unblinded,
            forceBlinded: target.forceBlinded,
            using: dependencies
        )
        
        updatedRequest.allHTTPHeaderFields = (preparedRequest.request.allHTTPHeaderFields ?? [:])
            .updated(with: [
                HTTPHeader.sogsPubKey: signResult.publicKey,
                HTTPHeader.sogsTimestamp: "\(timestamp)",
                HTTPHeader.sogsNonce: Data(nonce).base64EncodedString(),
                HTTPHeader.sogsSignature: signResult.signature.toBase64()
            ])
        
        return updatedRequest
    }
    
    // MARK: - Convenience
    
    /// Takes the reuqest information and generates a `PreparedRequest<R, Endpoint>` pbject which is ready for sending to the API, this
    /// method is mainly here so we can separate the preparation of a request, which requires access to the database for signing, from the
    /// actual sending of the reuqest to ensure we don't run into any unexpected blocking of the database write thread
    private static func prepareRequest<T: Encodable, R: Decodable>(
        request: Request<T, Endpoint>,
        responseType: R.Type,
        timeout: TimeInterval = HTTP.defaultTimeout,
        using dependencies: Dependencies
    ) throws -> HTTP.PreparedRequest<R> {
        return HTTP.PreparedRequest(
            request: request,
            urlRequest: try request.generateUrlRequest(using: dependencies),
            responseType: responseType,
            timeout: timeout
        )
    }
}
