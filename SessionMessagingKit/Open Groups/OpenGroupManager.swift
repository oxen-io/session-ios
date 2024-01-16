// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

// MARK: - OpenGroupManager

public final class OpenGroupManager {
    public typealias DefaultRoomInfo = (room: OpenGroupAPI.Room, openGroup: OpenGroup)
    
    // MARK: - Variables
    
    public static let shared: OpenGroupManager = OpenGroupManager()
    
    // MARK: - Polling

    public func startPolling(using dependencies: Dependencies = Dependencies()) {
        // Run on the 'workQueue' to ensure any 'Atomic' access doesn't block the main thread
        // on startup
        OpenGroupAPI.workQueue.async(using: dependencies) {
            guard !dependencies[cache: .openGroupManager].isPolling else { return }
        
            let servers: Set<String> = dependencies[singleton: .storage]
                .read { db in
                    // The default room promise creates an OpenGroup with an empty `roomToken` value,
                    // we don't want to start a poller for this as the user hasn't actually joined a room
                    try OpenGroup
                        .select(.server)
                        .filter(OpenGroup.Columns.isActive == true)
                        .filter(OpenGroup.Columns.roomToken != "")
                        .distinct()
                        .asRequest(of: String.self)
                        .fetchSet(db)
                }
                .defaulting(to: [])
            
            // Update the cache state and re-create all of the pollers
            dependencies.mutate(cache: .openGroupManager) { cache in
                cache.isPolling = true
                cache.pollers = servers
                    .reduce(into: [:]) { result, server in
                        result[server.lowercased()]?.stop() // Should never occur
                        result[server.lowercased()] = OpenGroupAPI.Poller(for: server.lowercased())
                    }
            }
            
            // Now that the pollers have been created actually start them
            dependencies[cache: .openGroupManager].pollers
                .forEach { _, poller in poller.startIfNeeded(using: dependencies) }
        }
    }

    public func stopPolling(using dependencies: Dependencies = Dependencies()) {
        dependencies.mutate(cache: .openGroupManager) {
            $0.pollers.forEach { _, openGroupPoller in openGroupPoller.stop() }
            $0.pollers.removeAll()
            $0.isPolling = false
        }
    }

    // MARK: - Adding & Removing
    
    private static func port(for server: String, serverUrl: URL) -> String {
        if let port: Int = serverUrl.port {
            return ":\(port)"
        }
        
        let components: [String] = server.components(separatedBy: ":")
        
        guard
            let port: String = components.last,
            (
                port != components.first &&
                !port.starts(with: "//")
            )
        else { return "" }
        
        return ":\(port)"
    }
    
    public static func isSessionRunOpenGroup(server: String) -> Bool {
        guard let serverUrl: URL = (URL(string: server.lowercased()) ?? URL(string: "http://\(server.lowercased())")) else {
            return false
        }
        
        let serverPort: String = OpenGroupManager.port(for: server, serverUrl: serverUrl)
        let serverHost: String = serverUrl.host
            .defaulting(
                to: server
                    .lowercased()
                    .replacingOccurrences(of: serverPort, with: "")
            )
        let options: Set<String> = Set([
            OpenGroupAPI.legacyDefaultServerIP,
            OpenGroupAPI.defaultServer
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "https://", with: "")
        ])
        
        return options.contains(serverHost)
    }
    
    public func hasExistingOpenGroup(
        _ db: Database,
        roomToken: String,
        server: String,
        publicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) -> Bool {
        guard let serverUrl: URL = URL(string: server.lowercased()) else { return false }
        
        let serverPort: String = OpenGroupManager.port(for: server, serverUrl: serverUrl)
        let serverHost: String = serverUrl.host
            .defaulting(
                to: server
                    .lowercased()
                    .replacingOccurrences(of: serverPort, with: "")
            )
        let defaultServerHost: String = OpenGroupAPI.defaultServer
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
        var serverOptions: Set<String> = Set([
            server.lowercased(),
            "\(serverHost)\(serverPort)",
            "http://\(serverHost)\(serverPort)",
            "https://\(serverHost)\(serverPort)"
        ])
        
        // If the server is run by Session then include all configurations in case one of the alternate configurations
        // was used
        if OpenGroupManager.isSessionRunOpenGroup(server: server) {
            serverOptions.insert(defaultServerHost)
            serverOptions.insert("http://\(defaultServerHost)")
            serverOptions.insert("https://\(defaultServerHost)")
            serverOptions.insert(OpenGroupAPI.legacyDefaultServerIP)
            serverOptions.insert("http://\(OpenGroupAPI.legacyDefaultServerIP)")
            serverOptions.insert("https://\(OpenGroupAPI.legacyDefaultServerIP)")
        }
        
        // First check if there is no poller for the specified server
        if Set(dependencies[cache: .openGroupManager].pollers.keys).intersection(serverOptions).isEmpty {
            return false
        }
        
        // Then check if there is an existing open group thread
        let hasExistingThread: Bool = serverOptions.contains(where: { serverName in
            (try? SessionThread
                .exists(
                    db,
                    id: OpenGroup.idFor(roomToken: roomToken, server: serverName)
                ))
                .defaulting(to: false)
        })
                                                                  
        return hasExistingThread
    }
    
    public func add(
        _ db: Database,
        roomToken: String,
        server: String,
        publicKey: String,
        calledFromConfigHandling: Bool,
        using dependencies: Dependencies = Dependencies()
    ) -> Bool {
        // If we are currently polling for this server and already have a TSGroupThread for this room the do nothing
        if hasExistingOpenGroup(db, roomToken: roomToken, server: server, publicKey: publicKey, using: dependencies) {
            SNLog("Ignoring join open group attempt (already joined), user initiated: \(!calledFromConfigHandling)")
            return false
        }
        
        // Store the open group information
        let targetServer: String = {
            guard OpenGroupManager.isSessionRunOpenGroup(server: server) else {
                return server.lowercased()
            }
            
            return OpenGroupAPI.defaultServer
        }()
        let threadId: String = OpenGroup.idFor(roomToken: roomToken, server: targetServer)
        
        // Optionally try to insert a new version of the OpenGroup (it will fail if there is already an
        // inactive one but that won't matter as we then activate it)
        _ = try? SessionThread
            .fetchOrCreate(
                db,
                id: threadId,
                variant: .community,
                /// If we didn't add this open group via config handling then flag it to be visible (if it did come via config handling then
                /// we want to wait until it actually has messages before making it visible)
                ///
                /// **Note:** We **MUST** provide a `nil` value if this method was called from the config handling as updating
                /// the `shouldVeVisible` state can trigger a config update which could result in an infinite loop in the future
                shouldBeVisible: (calledFromConfigHandling ? nil : true),
                calledFromConfigHandling: calledFromConfigHandling,
                using: dependencies
            )
        
        if (try? OpenGroup.exists(db, id: threadId)) == false {
            try? OpenGroup
                .fetchOrCreate(db, server: targetServer, roomToken: roomToken, publicKey: publicKey)
                .upsert(db)
        }
        
        // Set the group to active and reset the sequenceNumber (handle groups which have
        // been deactivated)
        if calledFromConfigHandling {
            _ = try? OpenGroup
                .filter(id: OpenGroup.idFor(roomToken: roomToken, server: targetServer))
                .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                    db,
                    OpenGroup.Columns.isActive.set(to: true),
                    OpenGroup.Columns.sequenceNumber.set(to: 0)
                )
        }
        else {
            _ = try? OpenGroup
                .filter(id: OpenGroup.idFor(roomToken: roomToken, server: targetServer))
                .updateAllAndConfig(
                    db,
                    OpenGroup.Columns.isActive.set(to: true),
                    OpenGroup.Columns.sequenceNumber.set(to: 0),
                    calledFromConfigHandling: calledFromConfigHandling,
                    using: dependencies
                )
        }
        
        return true
    }
    
    public func performInitialRequestsAfterAdd(
        successfullyAddedGroup: Bool,
        roomToken: String,
        server: String,
        publicKey: String,
        calledFromConfigHandling: Bool,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        guard successfullyAddedGroup else {
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        // Store the open group information
        let targetServer: String = {
            guard OpenGroupManager.isSessionRunOpenGroup(server: server) else {
                return server.lowercased()
            }
            
            return OpenGroupAPI.defaultServer
        }()
        
        return dependencies[singleton: .storage]
            .readPublisher { db in
                try OpenGroupAPI
                    .preparedCapabilitiesAndRoom(
                        db,
                        for: roomToken,
                        on: targetServer,
                        using: dependencies
                    )
            }
            .flatMap { $0.send(using: dependencies) }
            .flatMap { info, response -> Future<Void, Error> in
                Future<Void, Error> { resolver in
                    dependencies[singleton: .storage].write { db in
                        // Add the new open group to libSession
                        if !calledFromConfigHandling {
                            try LibSession.add(
                                db,
                                server: server,
                                rootToken: roomToken,
                                publicKey: publicKey,
                                using: dependencies
                            )
                        }
                        
                        // Store the capabilities first
                        OpenGroupManager.handleCapabilities(
                            db,
                            capabilities: response.capabilities.data,
                            on: targetServer
                        )
                        
                        // Then the room
                        try OpenGroupManager.handlePollInfo(
                            db,
                            pollInfo: OpenGroupAPI.RoomPollInfo(room: response.room.data),
                            publicKey: publicKey,
                            for: roomToken,
                            on: targetServer,
                            using: dependencies
                        ) {
                            resolver(Result.success(()))
                        }
                    }
                }
            }
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error): SNLog("Failed to join open group with error: \(error).")
                    }
                }
            )
            .eraseToAnyPublisher()
    }

    public func delete(
        _ db: Database,
        openGroupId: String,
        calledFromConfigHandling: Bool,
        using dependencies: Dependencies = Dependencies()
    ) {
        let server: String? = try? OpenGroup
            .select(.server)
            .filter(id: openGroupId)
            .asRequest(of: String.self)
            .fetchOne(db)
        let roomToken: String? = try? OpenGroup
            .select(.roomToken)
            .filter(id: openGroupId)
            .asRequest(of: String.self)
            .fetchOne(db)
        
        // Stop the poller if needed
        //
        // Note: The default room promise creates an OpenGroup with an empty `roomToken` value,
        // we don't want to start a poller for this as the user hasn't actually joined a room
        let numActiveRooms: Int = (try? OpenGroup
            .filter(OpenGroup.Columns.server == server?.lowercased())
            .filter(OpenGroup.Columns.roomToken != "")
            .filter(OpenGroup.Columns.isActive)
            .fetchCount(db))
            .defaulting(to: 1)
        
        if numActiveRooms == 1, let server: String = server?.lowercased() {
            let poller = dependencies[cache: .openGroupManager].pollers[server]
            poller?.stop()
            dependencies.mutate(cache: .openGroupManager) { $0.pollers[server] = nil }
        }
        
        // Remove all the data (everything should cascade delete)
        _ = try? SessionThread
            .filter(id: openGroupId)
            .deleteAll(db)
        
        // Remove any MessageProcessRecord entries (we will want to reprocess all OpenGroup messages
        // if they get re-added)
        _ = try? ControlMessageProcessRecord
            .filter(ControlMessageProcessRecord.Columns.threadId == openGroupId)
            .deleteAll(db)
        
        // Remove the open group (no foreign key to the thread so it won't auto-delete)
        if server?.lowercased() != OpenGroupAPI.defaultServer.lowercased() {
            _ = try? OpenGroup
                .filter(id: openGroupId)
                .deleteAll(db)
        }
        else {
            // If it's a session-run room then just set it to inactive
            _ = try? OpenGroup
                .filter(id: openGroupId)
                .updateAllAndConfig(
                    db,
                    OpenGroup.Columns.isActive.set(to: false),
                    calledFromConfigHandling: calledFromConfigHandling,
                    using: dependencies
                )
        }
        
        if !calledFromConfigHandling, let server: String = server, let roomToken: String = roomToken {
            try? LibSession.remove(db, server: server, roomToken: roomToken, using: dependencies)
        }
    }
    
    // MARK: - Response Processing
    
    internal static func handleCapabilities(
        _ db: Database,
        capabilities: OpenGroupAPI.Capabilities,
        on server: String
    ) {
        // Remove old capabilities first
        _ = try? Capability
            .filter(Capability.Columns.openGroupServer == server.lowercased())
            .deleteAll(db)
        
        // Then insert the new capabilities (both present and missing)
        capabilities.capabilities.forEach { capability in
            _ = try? Capability(
                openGroupServer: server.lowercased(),
                variant: capability,
                isMissing: false
            )
            .upserted(db)
        }
        capabilities.missing?.forEach { capability in
            _ = try? Capability(
                openGroupServer: server.lowercased(),
                variant: capability,
                isMissing: true
            )
            .upserted(db)
        }
    }
    
    internal static func handlePollInfo(
        _ db: Database,
        pollInfo: OpenGroupAPI.RoomPollInfo,
        publicKey maybePublicKey: String?,
        for roomToken: String,
        on server: String,
        using dependencies: Dependencies,
        completion: (() -> ())? = nil
    ) throws {
        // Create the open group model and get or create the thread
        let threadId: String = OpenGroup.idFor(roomToken: roomToken, server: server)
        
        guard let openGroup: OpenGroup = try OpenGroup.fetchOne(db, id: threadId) else { return }
        
        // Only update the database columns which have changed (this is to prevent the UI from triggering
        // updates due to changing database columns to the existing value)
        let hasDetails: Bool = (pollInfo.details != nil)
        let permissions: OpenGroup.Permissions = OpenGroup.Permissions(roomInfo: pollInfo)
        let changes: [ConfigColumnAssignment] = []
            .appending(openGroup.publicKey == maybePublicKey ? nil :
                maybePublicKey.map { OpenGroup.Columns.publicKey.set(to: $0) }
            )
            .appending(openGroup.userCount == pollInfo.activeUsers ? nil :
                OpenGroup.Columns.userCount.set(to: pollInfo.activeUsers)
            )
            .appending(openGroup.permissions == permissions ? nil :
                OpenGroup.Columns.permissions.set(to: permissions)
            )
            .appending(!hasDetails || openGroup.name == pollInfo.details?.name ? nil :
                OpenGroup.Columns.name.set(to: pollInfo.details?.name)
            )
            .appending(!hasDetails || openGroup.roomDescription == pollInfo.details?.roomDescription ? nil :
                OpenGroup.Columns.roomDescription.set(to: pollInfo.details?.roomDescription)
            )
            .appending(!hasDetails || openGroup.imageId == pollInfo.details?.imageId ? nil :
                OpenGroup.Columns.imageId.set(to: pollInfo.details?.imageId)
            )
            .appending(!hasDetails || openGroup.infoUpdates == pollInfo.details?.infoUpdates ? nil :
                OpenGroup.Columns.infoUpdates.set(to: pollInfo.details?.infoUpdates)
            )
        
        try OpenGroup
            .filter(id: openGroup.id)
            .updateAllAndConfig(db, changes, using: dependencies)
        
        // Update the admin/moderator group members
        if let roomDetails: OpenGroupAPI.Room = pollInfo.details {
            _ = try? GroupMember
                .filter(GroupMember.Columns.groupId == threadId)
                .deleteAll(db)
            
            try roomDetails.admins.forEach { adminId in
                try GroupMember(
                    groupId: threadId,
                    profileId: adminId,
                    role: .admin,
                    roleStatus: .accepted,  // Community members don't have role statuses
                    isHidden: false
                ).upsert(db)
            }
            
            try roomDetails.hiddenAdmins
                .defaulting(to: [])
                .forEach { adminId in
                    try GroupMember(
                        groupId: threadId,
                        profileId: adminId,
                        role: .admin,
                        roleStatus: .accepted,  // Community members don't have role statuses
                        isHidden: true
                    ).upsert(db)
                }
            
            try roomDetails.moderators.forEach { moderatorId in
                try GroupMember(
                    groupId: threadId,
                    profileId: moderatorId,
                    role: .moderator,
                    roleStatus: .accepted,      // Community members don't have role statuses
                    isHidden: false
                ).upsert(db)
            }
            
            try roomDetails.hiddenModerators
                .defaulting(to: [])
                .forEach { moderatorId in
                    try GroupMember(
                        groupId: threadId,
                        profileId: moderatorId,
                        role: .moderator,
                        roleStatus: .accepted,  // Community members don't have role statuses
                        isHidden: true
                    ).upsert(db)
                }
        }
        
        /// Schedule the room image download (if we don't have one or it's been updated)
        if
            let imageId: String = (pollInfo.details?.imageId ?? openGroup.imageId),
            (
                openGroup.displayPictureFilename == nil ||
                openGroup.imageId != imageId
            )
        {
            dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .displayPictureDownload,
                    shouldBeUnique: true,
                    details: DisplayPictureDownloadJob.Details(
                        target: .community(
                            imageId: imageId,
                            roomToken: openGroup.roomToken,
                            server: openGroup.server
                        ),
                        timestamp: TimeInterval(Double(SnodeAPI.currentOffsetTimestampMs(using: dependencies)) / 1000)
                    )
                ),
                canStartJob: true,
                using: dependencies
            )
        }
        
        db.afterNextTransactionNested { _ in
            // Dispatch async to the workQueue to prevent holding up the DBWrite thread from the
            // above transaction
            OpenGroupAPI.workQueue.async(using: dependencies) {
                // Start the poller if needed
                if dependencies[cache: .openGroupManager].pollers[server.lowercased()] == nil {
                    dependencies.mutate(cache: .openGroupManager) {
                        $0.pollers[server.lowercased()]?.stop()
                        $0.pollers[server.lowercased()] = OpenGroupAPI.Poller(for: server.lowercased())
                    }
                    
                    dependencies[cache: .openGroupManager].pollers[server.lowercased()]?
                        .startIfNeeded(using: dependencies)
                }
                
                // Finish
                completion?()
            }
        }
    }
    
    internal static func handleMessages(
        _ db: Database,
        messages: [OpenGroupAPI.Message],
        for roomToken: String,
        on server: String,
        using dependencies: Dependencies
    ) {
        guard let openGroup: OpenGroup = try? OpenGroup.fetchOne(db, id: OpenGroup.idFor(roomToken: roomToken, server: server)) else {
            SNLog("Couldn't handle open group messages.")
            return
        }
        
        // Sorting the messages by server ID before importing them fixes an issue where messages
        // that quote older messages can't find those older messages
        let sortedMessages: [OpenGroupAPI.Message] = messages
            .filter { $0.deleted != true }
            .sorted { lhs, rhs in lhs.id < rhs.id }
        var messageServerInfoToRemove: [(id: Int64, seqNo: Int64)] = messages
            .filter { $0.deleted == true }
            .map { ($0.id, $0.seqNo) }
        var largestValidSeqNo: Int64 = openGroup.sequenceNumber
        
        // Process the messages
        sortedMessages.forEach { message in
            if message.base64EncodedData == nil && message.reactions == nil {
                messageServerInfoToRemove.append((message.id, message.seqNo))
                return
            }
            
            // Handle messages
            if let base64EncodedString: String = message.base64EncodedData,
               let data = Data(base64Encoded: base64EncodedString)
            {
                do {
                    let processedMessage: ProcessedMessage? = try Message.processReceivedOpenGroupMessage(
                        db,
                        openGroupId: openGroup.id,
                        openGroupServerPublicKey: openGroup.publicKey,
                        message: message,
                        data: data,
                        using: dependencies
                    )
                    
                    switch processedMessage {
                        case .config, .none: break
                        case .standard(_, _, _, let messageInfo):
                            try MessageReceiver.handle(
                                db,
                                threadId: openGroup.id,
                                threadVariant: .community,
                                message: messageInfo.message,
                                serverExpirationTimestamp: messageInfo.serverExpirationTimestamp,
                                associatedWithProto: try SNProtoContent.parseData(messageInfo.serializedProtoData),
                                using: dependencies
                            )
                            largestValidSeqNo = max(largestValidSeqNo, message.seqNo)
                    }
                }
                catch {
                    switch error {
                        // Ignore duplicate & selfSend message errors (and don't bother logging
                        // them as there will be a lot since we each service node duplicates messages)
                        case DatabaseError.SQLITE_CONSTRAINT_UNIQUE,
                            MessageReceiverError.duplicateMessage,
                            MessageReceiverError.duplicateControlMessage,
                            MessageReceiverError.selfSend:
                            break
                        
                        default: SNLog("Couldn't receive open group message due to error: \(error).")
                    }
                }
            }
            
            // Handle reactions
            if message.reactions != nil {
                do {
                    let reactions: [Reaction] = Message.processRawReceivedReactions(
                        db,
                        openGroupId: openGroup.id,
                        message: message,
                        associatedPendingChanges: dependencies[cache: .openGroupManager].pendingChanges
                            .filter {
                                guard $0.server == server && $0.room == roomToken && $0.changeType == .reaction else {
                                    return false
                                }
                                
                                if case .reaction(let messageId, _, _) = $0.metadata {
                                    return messageId == message.id
                                }
                                return false
                            },
                        using: dependencies
                    )
                    
                    try MessageReceiver.handleOpenGroupReactions(
                        db,
                        threadId: openGroup.threadId,
                        openGroupMessageServerId: message.id,
                        openGroupReactions: reactions
                    )
                    largestValidSeqNo = max(largestValidSeqNo, message.seqNo)
                }
                catch {
                    SNLog("Couldn't handle open group reactions due to error: \(error).")
                }
            }
        }

        // Handle any deletions that are needed
        if !messageServerInfoToRemove.isEmpty {
            let messageServerIdsToRemove: [Int64] = messageServerInfoToRemove.map { $0.id }
            _ = try? Interaction
                .filter(Interaction.Columns.threadId == openGroup.threadId)
                .filter(messageServerIdsToRemove.contains(Interaction.Columns.openGroupServerMessageId))
                .deleteAll(db)
            
            // Update the seqNo for deletions
            largestValidSeqNo = max(largestValidSeqNo, (messageServerInfoToRemove.map({ $0.seqNo }).max() ?? 0))
        }
        
        // Now that we've finished processing all valid message changes we can update the `sequenceNumber` to
        // the `largestValidSeqNo` value
        _ = try? OpenGroup
            .filter(id: openGroup.id)
            .updateAll(db, OpenGroup.Columns.sequenceNumber.set(to: largestValidSeqNo))

        // Update pendingChange cache based on the `largestValidSeqNo` value
        dependencies.mutate(cache: .openGroupManager) {
            $0.pendingChanges = $0.pendingChanges
                .filter { $0.seqNo == nil || $0.seqNo! > largestValidSeqNo }
        }
    }
    
    internal static func handleDirectMessages(
        _ db: Database,
        messages: [OpenGroupAPI.DirectMessage],
        fromOutbox: Bool,
        on server: String,
        using dependencies: Dependencies
    ) {
        // Don't need to do anything if we have no messages (it's a valid case)
        guard !messages.isEmpty else { return }
        guard let openGroup: OpenGroup = try? OpenGroup.filter(OpenGroup.Columns.server == server.lowercased()).fetchOne(db) else {
            SNLog("Couldn't receive inbox message.")
            return
        }
        
        // Sorting the messages by server ID before importing them fixes an issue where messages
        // that quote older messages can't find those older messages
        let sortedMessages: [OpenGroupAPI.DirectMessage] = messages
            .sorted { lhs, rhs in lhs.id < rhs.id }
        let latestMessageId: Int64 = sortedMessages[sortedMessages.count - 1].id
        var lookupCache: [String: BlindedIdLookup] = [:]  // Only want this cache to exist for the current loop
        
        // Update the 'latestMessageId' value
        if fromOutbox {
            _ = try? OpenGroup
                .filter(OpenGroup.Columns.server == server.lowercased())
                .updateAll(db, OpenGroup.Columns.outboxLatestMessageId.set(to: latestMessageId))
        }
        else {
            _ = try? OpenGroup
                .filter(OpenGroup.Columns.server == server.lowercased())
                .updateAll(db, OpenGroup.Columns.inboxLatestMessageId.set(to: latestMessageId))
        }

        // Process the messages
        sortedMessages.forEach { message in
            guard let messageData = Data(base64Encoded: message.base64EncodedMessage) else {
                SNLog("Couldn't receive inbox message.")
                return
            }

            do {
                let processedMessage: ProcessedMessage? = try Message.processReceivedOpenGroupDirectMessage(
                    db,
                    openGroupServerPublicKey: openGroup.publicKey,
                    message: message,
                    data: messageData,
                    using: dependencies
                )
                
                switch processedMessage {
                    case .config, .none: break
                    case .standard(let threadId, _, let proto, let messageInfo):
                        // We want to update the BlindedIdLookup cache with the message info so we
                        // can avoid using the "expensive" lookup when possible
                        let lookup: BlindedIdLookup = try {
                            // Minor optimisation to avoid processing the same sender multiple times
                            // in the same 'handleMessages' call (since the 'mapping' call is done
                            // within a transaction we will never have a mapping come through part-way
                            // through processing these messages)
                            if let result: BlindedIdLookup = lookupCache[message.recipient] {
                                return result
                            }
                            
                            return try BlindedIdLookup.fetchOrCreate(
                                db,
                                blindedId: (fromOutbox ?
                                    message.recipient :
                                    message.sender
                                ),
                                sessionId: (fromOutbox ?
                                    nil :
                                    threadId
                                ),
                                openGroupServer: server.lowercased(),
                                openGroupPublicKey: openGroup.publicKey,
                                isCheckingForOutbox: fromOutbox,
                                using: dependencies
                            )
                        }()
                        lookupCache[message.recipient] = lookup
                        
                        // We also need to set the 'syncTarget' for outgoing messages to be consistent with
                        // standard messages
                        if fromOutbox {
                            let syncTarget: String = (lookup.sessionId ?? message.recipient)
                            
                            switch messageInfo.variant {
                                case .visibleMessage:
                                    (messageInfo.message as? VisibleMessage)?.syncTarget = syncTarget
                                    
                                case .expirationTimerUpdate:
                                    (messageInfo.message as? ExpirationTimerUpdate)?.syncTarget = syncTarget
                                    
                                default: break
                            }
                        }
                        
                        try MessageReceiver.handle(
                            db,
                            threadId: (lookup.sessionId ?? lookup.blindedId),
                            threadVariant: .contact,    // Technically not open group messages
                            message: messageInfo.message,
                            serverExpirationTimestamp: messageInfo.serverExpirationTimestamp,
                            associatedWithProto: proto,
                            using: dependencies
                        )
                }
            }
            catch {
                switch error {
                    // Ignore duplicate and self-send errors (we will always receive a duplicate message back
                    // whenever we send a message so this ends up being spam otherwise)
                    case DatabaseError.SQLITE_CONSTRAINT_UNIQUE,
                        MessageReceiverError.duplicateMessage,
                        MessageReceiverError.duplicateControlMessage,
                        MessageReceiverError.selfSend:
                        break
                        
                    default:
                        SNLog("Couldn't receive inbox message due to error: \(error).")
                }
            }
        }
    }
    
    // MARK: - Convenience
    
    public static func addPendingReaction(
        emoji: String,
        id: Int64,
        in roomToken: String,
        on server: String,
        type: OpenGroupAPI.PendingChange.ReactAction,
        using dependencies: Dependencies = Dependencies()
    ) -> OpenGroupAPI.PendingChange {
        let pendingChange = OpenGroupAPI.PendingChange(
            server: server,
            room: roomToken,
            changeType: .reaction,
            metadata: .reaction(
                messageId: id,
                emoji: emoji,
                action: type
            )
        )
        
        dependencies.mutate(cache: .openGroupManager) {
            $0.pendingChanges.append(pendingChange)
        }
        
        return pendingChange
    }
    
    public static func updatePendingChange(
        _ pendingChange: OpenGroupAPI.PendingChange,
        seqNo: Int64?,
        using dependencies: Dependencies = Dependencies()
    ) {
        dependencies.mutate(cache: .openGroupManager) {
            if let index = $0.pendingChanges.firstIndex(of: pendingChange) {
                $0.pendingChanges[index].seqNo = seqNo
            }
        }
    }
    
    public static func removePendingChange(
        _ pendingChange: OpenGroupAPI.PendingChange,
        using dependencies: Dependencies = Dependencies()
    ) {
        dependencies.mutate(cache: .openGroupManager) {
            if let index = $0.pendingChanges.firstIndex(of: pendingChange) {
                $0.pendingChanges.remove(at: index)
            }
        }
    }
    
    /// This method specifies if the given capability is supported on a specified Open Group
    public static func doesOpenGroupSupport(
        _ db: Database? = nil,
        capability: Capability.Variant,
        on server: String?,
        using dependencies: Dependencies = Dependencies()
    ) -> Bool {
        guard let server: String = server else { return false }
        guard let db: Database = db else {
            return dependencies[singleton: .storage]
                .read { db in doesOpenGroupSupport(db, capability: capability, on: server, using: dependencies) }
                .defaulting(to: false)
        }
        
        let capabilities: [Capability.Variant] = (try? Capability
            .select(.variant)
            .filter(Capability.Columns.openGroupServer == server)
            .filter(Capability.Columns.isMissing == false)
            .asRequest(of: Capability.Variant.self)
            .fetchAll(db))
            .defaulting(to: [])

        return capabilities.contains(capability)
    }
    
    /// This method specifies if the given publicKey is a moderator or an admin within a specified Open Group
    public static func isUserModeratorOrAdmin(
        _ db: Database? = nil,
        publicKey: String,
        for roomToken: String?,
        on server: String?,
        using dependencies: Dependencies = Dependencies()
    ) -> Bool {
        guard let roomToken: String = roomToken, let server: String = server else { return false }
        guard let db: Database = db else {
            return dependencies[singleton: .storage].read { db -> Bool in
                OpenGroupManager.isUserModeratorOrAdmin(db, publicKey: publicKey, for: roomToken, on: server)
            }.defaulting(to: false)
        }

        let groupId: String = OpenGroup.idFor(roomToken: roomToken, server: server)
        let targetRoles: [GroupMember.Role] = [.moderator, .admin]
        let isDirectModOrAdmin: Bool = GroupMember
            .filter(GroupMember.Columns.groupId == groupId)
            .filter(GroupMember.Columns.profileId == publicKey)
            .filter(targetRoles.contains(GroupMember.Columns.role))
            .isNotEmpty(db)
        
        // If the publicKey provided matches a mod or admin directly then just return immediately
        if isDirectModOrAdmin { return true }
        
        // Otherwise we need to check if it's a variant of the current users key and if so we want
        // to check if any of those have mod/admin entries
        guard let sessionId: SessionId = try? SessionId(from: publicKey) else { return false }
        
        // Conveniently the logic for these different cases works in order so we can fallthrough each
        // case with only minor efficiency losses
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        
        switch sessionId.prefix {
            case .standard:
                guard publicKey == userSessionId.hexString else { return false }
                fallthrough
                
            case .unblinded:
                guard let userEdKeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db) else {
                    return false
                }
                guard sessionId.prefix != .unblinded || publicKey == SessionId(.unblinded, publicKey: userEdKeyPair.publicKey).hexString else {
                    return false
                }
                fallthrough
                
            case .blinded15, .blinded25:
                guard
                    let userEdKeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db),
                    let openGroupPublicKey: String = try? OpenGroup
                        .select(.publicKey)
                        .filter(id: groupId)
                        .asRequest(of: String.self)
                        .fetchOne(db),
                    let blinded15KeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                        .blinded15KeyPair(serverPublicKey: openGroupPublicKey, ed25519SecretKey: userEdKeyPair.secretKey)
                    ),
                    let blinded25KeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                        .blinded25KeyPair(serverPublicKey: openGroupPublicKey, ed25519SecretKey: userEdKeyPair.secretKey)
                    )
                else { return false }
                guard
                    (
                        sessionId.prefix != .blinded15 &&
                        sessionId.prefix != .blinded25
                    ) ||
                    publicKey == SessionId(.blinded15, publicKey: blinded15KeyPair.publicKey).hexString ||
                    publicKey == SessionId(.blinded25, publicKey: blinded25KeyPair.publicKey).hexString
                else { return false }
                
                // If we got to here that means that the 'publicKey' value matches one of the current
                // users 'standard', 'unblinded' or 'blinded' keys and as such we should check if any
                // of them exist in the `modsAndAminKeys` Set
                let possibleKeys: Set<String> = Set([
                    userSessionId.hexString,
                    SessionId(.unblinded, publicKey: userEdKeyPair.publicKey).hexString,
                    SessionId(.blinded15, publicKey: blinded15KeyPair.publicKey).hexString,
                    SessionId(.blinded25, publicKey: blinded25KeyPair.publicKey).hexString
                ])
                
                return GroupMember
                    .filter(GroupMember.Columns.groupId == groupId)
                    .filter(possibleKeys.contains(GroupMember.Columns.profileId))
                    .filter(targetRoles.contains(GroupMember.Columns.role))
                    .isNotEmpty(db)
                
            case .group: return false
        }
    }
    
    @discardableResult public static func getDefaultRoomsIfNeeded(
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<[DefaultRoomInfo], Error> {
        // Note: If we already have a 'defaultRoomsPromise' then there is no need to get it again
        if let existingPublisher: AnyPublisher<[DefaultRoomInfo], Error> = dependencies[cache: .openGroupManager].defaultRoomsPublisher {
            return existingPublisher
        }
        
        // Try to retrieve the default rooms 8 times
        let publisher: AnyPublisher<[DefaultRoomInfo], Error> = dependencies[singleton: .storage]
            .readPublisher { db -> HTTP.PreparedRequest<OpenGroupAPI.CapabilitiesAndRoomsResponse> in
                try OpenGroupAPI.preparedCapabilitiesAndRooms(
                    db,
                    on: OpenGroupAPI.defaultServer,
                    using: dependencies
                )
            }
            .flatMap { $0.send(using: dependencies) }
            .subscribe(on: OpenGroupAPI.workQueue, using: dependencies)
            .receive(on: OpenGroupAPI.workQueue, using: dependencies)
            .retry(8, using: dependencies)
            .map { info, response -> [DefaultRoomInfo]? in
                dependencies[singleton: .storage].write(using: dependencies) { db -> [DefaultRoomInfo] in
                    // Store the capabilities first
                    OpenGroupManager.handleCapabilities(
                        db,
                        capabilities: response.capabilities.data,
                        on: OpenGroupAPI.defaultServer
                    )
                    
                    let existingImageIds: [String: String] = try OpenGroup
                        .filter(OpenGroup.Columns.server == OpenGroupAPI.defaultServer)
                        .filter(OpenGroup.Columns.imageId != nil)
                        .fetchAll(db)
                        .reduce(into: [:]) { result, next in result[next.id] = next.imageId }
                    let result: [DefaultRoomInfo] = try response.rooms.data
                        .compactMap { room -> DefaultRoomInfo? in
                            // Try to insert an inactive version of the OpenGroup (use 'insert'
                            // rather than 'save' as we want it to fail if the room already exists)
                            do {
                                return (
                                    room,
                                    try OpenGroup(
                                        server: OpenGroupAPI.defaultServer,
                                        roomToken: room.token,
                                        publicKey: OpenGroupAPI.defaultServerPublicKey,
                                        isActive: false,
                                        name: room.name,
                                        roomDescription: room.roomDescription,
                                        imageId: room.imageId,
                                        userCount: room.activeUsers,
                                        infoUpdates: room.infoUpdates
                                    )
                                    .inserted(db)
                                )
                            }
                            catch {
                                return try OpenGroup
                                    .fetchOne(
                                        db,
                                        id: OpenGroup.idFor(
                                            roomToken: room.token,
                                            server: OpenGroupAPI.defaultServer
                                        )
                                    )
                                    .map { (room, $0) }
                            }
                        }
                    
                    /// Schedule the room image download (if it doesn't match out current one)
                    result.forEach { room, _ in
                        let id: String = OpenGroup.idFor(roomToken: room.token, server: OpenGroupAPI.defaultServer)
                        
                        guard
                            let imageId: String = room.imageId,
                            imageId != existingImageIds[id]
                        else { return }
                        
                        dependencies[singleton: .jobRunner].add(
                            db,
                            job: Job(
                                variant: .displayPictureDownload,
                                shouldBeUnique: true,
                                details: DisplayPictureDownloadJob.Details(
                                    target: .community(
                                        imageId: imageId,
                                        roomToken: room.token,
                                        server: OpenGroupAPI.defaultServer
                                    ),
                                    timestamp: TimeInterval(Double(SnodeAPI.currentOffsetTimestampMs(using: dependencies)) / 1000)
                                )
                            ),
                            canStartJob: true,
                            using: dependencies
                        )
                    }
                    
                    return result
                }
            }
            .map { ($0 ?? []) }
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure:
                            dependencies.mutate(cache: .openGroupManager) { cache in
                                cache.defaultRoomsPublisher = nil
                            }
                    }
                }
            )
            .shareReplay(1)
            .eraseToAnyPublisher()
        
        dependencies.mutate(cache: .openGroupManager) { cache in
            cache.defaultRoomsPublisher = publisher
        }
        
        // Hold on to the publisher until it has completed at least once
        publisher.sinkUntilComplete()
        
        return publisher
    }
}

// MARK: - OpenGroupManager Cache

public extension OpenGroupManager {
    class Cache: OGMCacheType {
        public var defaultRoomsPublisher: AnyPublisher<[DefaultRoomInfo], Error>?
        
        public var pollers: [String: OpenGroupAPI.Poller] = [:] // One for each server
        public var isPolling: Bool = false
        
        /// Server URL to value
        public var hasPerformedInitialPoll: [String: Bool] = [:]
        public var timeSinceLastPoll: [String: TimeInterval] = [:]

        fileprivate var _timeSinceLastOpen: TimeInterval?
        public func getTimeSinceLastOpen(using dependencies: Dependencies) -> TimeInterval {
            if let storedTimeSinceLastOpen: TimeInterval = _timeSinceLastOpen {
                return storedTimeSinceLastOpen
            }
            
            guard let lastOpen: Date = dependencies[defaults: .standard, key: .lastOpen] else {
                _timeSinceLastOpen = .greatestFiniteMagnitude
                return .greatestFiniteMagnitude
            }
            
            _timeSinceLastOpen = dependencies.dateNow.timeIntervalSince(lastOpen)
            return dependencies.dateNow.timeIntervalSince(lastOpen)
        }
        
        public var pendingChanges: [OpenGroupAPI.PendingChange] = []
    }
}

public extension Cache {
    static let openGroupManager: CacheConfig<OGMCacheType, OGMImmutableCacheType> = Dependencies.create(
        identifier: "openGroupManager",
        createInstance: { _ in OpenGroupManager.Cache() },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - OGMCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol OGMImmutableCacheType: ImmutableCacheType {
    var defaultRoomsPublisher: AnyPublisher<[OpenGroupManager.DefaultRoomInfo], Error>? { get }
    
    var pollers: [String: OpenGroupAPI.Poller] { get }
    var isPolling: Bool { get }
    
    var hasPerformedInitialPoll: [String: Bool] { get }
    var timeSinceLastPoll: [String: TimeInterval] { get }
    
    var pendingChanges: [OpenGroupAPI.PendingChange] { get }
}

public protocol OGMCacheType: OGMImmutableCacheType, MutableCacheType {
    var defaultRoomsPublisher: AnyPublisher<[OpenGroupManager.DefaultRoomInfo], Error>? { get set }
    
    var pollers: [String: OpenGroupAPI.Poller] { get set }
    var isPolling: Bool { get set }
    
    var hasPerformedInitialPoll: [String: Bool] { get set }
    var timeSinceLastPoll: [String: TimeInterval] { get set }
    
    var pendingChanges: [OpenGroupAPI.PendingChange] { get set }
    
    func getTimeSinceLastOpen(using dependencies: Dependencies) -> TimeInterval
}
