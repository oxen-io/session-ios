// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let messageSender: Log.Category = .create("MessageSender", defaultLevel: .info)
}

// MARK: - MessageSender

public final class MessageSender {
    // MARK: - Message Preparation
    
    public static func preparedSend(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        namespace: SnodeAPI.Namespace?,
        interactionId: Int64?,
        fileIds: [String],
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Void> {
        // Common logic for all destinations
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let messageSendTimestampMs: Int64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        let updatedMessage: Message = message
        
        // Set the message 'sentTimestamp' (Visible messages will already have their sent timestamp set)
        updatedMessage.sentTimestampMs = (
            updatedMessage.sentTimestampMs ??
            UInt64(messageSendTimestampMs)
        )
        
        do {
            switch destination {
                case .contact, .syncMessage, .closedGroup:
                    return try preparedSendToSnodeDestination(
                        db,
                        message: updatedMessage,
                        to: destination,
                        namespace: namespace,
                        interactionId: interactionId,
                        fileIds: fileIds,
                        userSessionId: userSessionId,
                        messageSendTimestampMs: messageSendTimestampMs,
                        using: dependencies
                    )
                    .map { _, _ in () }
                    
                case .openGroup:
                    return try preparedSendToOpenGroupDestination(
                        db,
                        message: updatedMessage,
                        to: destination,
                        interactionId: interactionId,
                        fileIds: fileIds,
                        messageSendTimestampMs: messageSendTimestampMs,
                        using: dependencies
                    )
                    
                case .openGroupInbox:
                    return try preparedSendToOpenGroupInboxDestination(
                        db,
                        message: message,
                        to: destination,
                        interactionId: interactionId,
                        fileIds: fileIds,
                        userSessionId: userSessionId,
                        messageSendTimestampMs: messageSendTimestampMs,
                        using: dependencies
                    )
            }
        }
        catch let error as MessageSenderError {
            throw MessageSender.handleFailedMessageSend(
                db,
                message: message,
                destination: destination,
                error: error,
                interactionId: interactionId,
                using: dependencies
            )
        }
    }
    
    internal static func preparedSendToSnodeDestination(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        namespace: SnodeAPI.Namespace?,
        interactionId: Int64?,
        fileIds: [String],
        userSessionId: SessionId,
        messageSendTimestampMs: Int64,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<SendMessagesResponse> {
        guard let namespace: SnodeAPI.Namespace = namespace else { throw MessageSenderError.invalidMessage }
        
        /// Set the sender/recipient info (needed to be valid)
        ///
        /// **Note:** The `sentTimestamp` will differ from the `messageSendTimestampMs` as it's the time the user originally
        /// sent the message whereas the `messageSendTimestamp` is the time it will be uploaded to the swarm
        let sentTimestampMs: UInt64 = (message.sentTimestampMs ?? UInt64(messageSendTimestampMs))
        message.sender = userSessionId.hexString
        message.sentTimestampMs = sentTimestampMs
        
        // Ensure the message is valid
        try MessageSender.ensureValidMessage(message, destination: destination, fileIds: fileIds, using: dependencies)
        
        // Attach the user's profile if needed (no need to do so for 'Note to Self' or sync
        // messages as they will be managed by the user config handling
        switch (destination, message as? MessageWithProfile) {
            case (.syncMessage, _), (_, .none): break
            case (.contact(let publicKey), _) where publicKey == userSessionId.hexString: break
            case (_, .some(var messageWithProfile)):
                let profile: Profile = Profile.fetchOrCreateCurrentUser(db, using: dependencies)
                
                if let profileKey: Data = profile.profileEncryptionKey, let profilePictureUrl: String = profile.profilePictureUrl {
                    messageWithProfile.profile = VisibleMessage.VMProfile(
                        displayName: profile.name,
                        profileKey: profileKey,
                        profilePictureUrl: profilePictureUrl
                    )
                }
                else {
                    messageWithProfile.profile = VisibleMessage.VMProfile(displayName: profile.name)
                }
        }
        
        // Perform any pre-send actions
        handleMessageWillSend(db, message: message, destination: destination, interactionId: interactionId)
        
        // Convert and prepare the data for sending
        let threadId: String = Message.threadId(forMessage: message, destination: destination)
        let plaintext: Data = try {
            switch namespace {
                case .revokedRetrievableGroupMessages:
                    return try BencodeEncoder(using: dependencies).encode(message)
                    
                default:
                    guard let proto = message.toProto(db, threadId: threadId) else {
                        throw MessageSenderError.protoConversionFailed
                    }
                    
                    return try Result(proto.serializedData())
                        .map { serialisedData -> Data in
                            switch destination {
                                case .closedGroup(let groupId) where (try? SessionId.Prefix(from: groupId)) == .group:
                                    return serialisedData
                                    
                                default: return serialisedData.paddedMessageBody()
                            }
                        }
                        .mapError { MessageSenderError.other(nil, "Couldn't serialize proto", $0) }
                        .successOrThrow()
            }
        }()
        let base64EncodedData: String = try {
            switch (destination, namespace) {
                // Updated group messages should be wrapped _before_ encrypting
                case (.closedGroup(let groupId), .groupMessages) where (try? SessionId.Prefix(from: groupId)) == .group:
                    let messageData: Data = try Result(
                        MessageWrapper.wrap(
                            type: .closedGroupMessage,
                            timestampMs: sentTimestampMs,
                            base64EncodedContent: plaintext.base64EncodedString(),
                            wrapInWebSocketMessage: false
                        )
                    )
                    .mapError { MessageSenderError.other(nil, "Couldn't wrap message", $0) }
                    .successOrThrow()
                    
                    let ciphertext: Data = try dependencies[singleton: .crypto].tryGenerate(
                        .ciphertextForGroupMessage(
                            groupSessionId: SessionId(.group, hex: groupId),
                            message: Array(messageData)
                        )
                    )
                    return ciphertext.base64EncodedString()
                    
                // revokedRetrievableGroupMessages should be sent in plaintext (their content has custom encryption)
                case (.closedGroup(let groupId), .revokedRetrievableGroupMessages) where (try? SessionId.Prefix(from: groupId)) == .group:
                    return plaintext.base64EncodedString()
                    
                // Config messages should be sent directly rather than via this method
                case (.closedGroup(let groupId), _) where (try? SessionId.Prefix(from: groupId)) == .group:
                    throw MessageSenderError.invalidConfigMessageHandling
                    
                // Standard one-to-one messages and legacy groups (which used a `05` prefix)
                case (.contact(let publicKey), .default), (.syncMessage(let publicKey), _), (.closedGroup(let publicKey), _):
                    let ciphertext: Data = try dependencies[singleton: .crypto].tryGenerate(
                        .ciphertextWithSessionProtocol(
                            db,
                            plaintext: plaintext,
                            destination: destination,
                            using: dependencies
                        )
                    )
                    
                    return try Result(
                        try MessageWrapper.wrap(
                            type: try {
                                switch destination {
                                    case .contact, .syncMessage: return .sessionMessage
                                    case .closedGroup: return .closedGroupMessage
                                    default: throw MessageSenderError.invalidMessage
                                }
                            }(),
                            timestampMs: sentTimestampMs,
                            senderPublicKey: {
                                switch destination {
                                    case .closedGroup: return publicKey // Needed for Android
                                    default: return ""                  // Empty for all other cases
                                }
                            }(),
                            base64EncodedContent: ciphertext.base64EncodedString()
                        )
                    )
                    .mapError { MessageSenderError.other(nil, "Couldn't wrap message", $0) }
                    .successOrThrow()
                    .base64EncodedString()
                    
                // Config messages should be sent directly rather than via this method
                case (.contact, _): throw MessageSenderError.invalidConfigMessageHandling
                case (.openGroup, _), (.openGroupInbox, _): preconditionFailure()
            }
        }()
        
        // Send the result
        let snodeMessage = SnodeMessage(
            recipient: {
                switch destination {
                    case .contact(let publicKey): return publicKey
                    case .syncMessage: return userSessionId.hexString
                    case .closedGroup(let groupPublicKey): return groupPublicKey
                    case .openGroup, .openGroupInbox: preconditionFailure()
                }
            }(),
            data: base64EncodedData,
            ttl: Message.getSpecifiedTTL(message: message, destination: destination, using: dependencies),
            timestampMs: UInt64(messageSendTimestampMs)
        )
        
        return try SnodeAPI
            .preparedSendMessage(
                message: snodeMessage,
                in: namespace,
                authMethod: try Authentication.with(db, swarmPublicKey: threadId, using: dependencies),
                using: dependencies
            )
            .handleEvents(
                receiveOutput: { _, response in
                    let updatedMessage: Message = message
                    updatedMessage.serverHash = response.hash
                    
                    // Only legacy groups need to manually trigger push notifications now so only create the job
                    // if the destination is a legacy group (ie. a group destination with a standard pubkey prefix)
                    let notifyPushServerJob: Job? = {
                        guard
                            case .closedGroup(let groupPublicKey) = destination,
                            let groupId: SessionId = try? SessionId(from: groupPublicKey),
                            groupId.prefix == .standard
                        else { return nil }
                                    
                        return Job(
                            variant: .notifyPushServer,
                            behaviour: .runOnce,
                            details: NotifyPushServerJob.Details(message: snodeMessage)
                        )
                    }()
                    
                    // Save the updated message info and send a PN if needed
                    dependencies[singleton: .storage].write { db in
                        try MessageSender.handleSuccessfulMessageSend(
                            db,
                            message: updatedMessage,
                            to: destination,
                            interactionId: interactionId,
                            using: dependencies
                        )
                        
                        guard notifyPushServerJob != nil else { return }

                        dependencies[singleton: .jobRunner].add(
                            db,
                            job: notifyPushServerJob,
                            canStartJob: true
                        )
                    }
                    
                    // If we should send a push notification and are sending from the background then
                    // we want to send it on this thread
                    guard
                        let job: Job = notifyPushServerJob,
                        !dependencies[defaults: .appGroup, key: .isMainAppActive]
                    else { return }
                    
                    // Want to block the main thread here as it's likely we just went to the background
                    // and have sent a message in a background task before shutting down the app so want
                    // the notification to go out
                    NotifyPushServerJob.run(
                        job,
                        queue: .main,
                        success: { _, _ in },
                        failure: { _, _, _ in },
                        deferred: { _ in },
                        using: dependencies
                    )
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            dependencies[singleton: .storage].read { db in
                                MessageSender.handleFailedMessageSend(
                                    db,
                                    message: message,
                                    destination: destination,
                                    error: .other(nil, "Couldn't send message", error),
                                    interactionId: interactionId,
                                    using: dependencies
                                )
                            }
                    }
                }
            )
    }
    
    private static func preparedSendToOpenGroupDestination(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        fileIds: [String],
        messageSendTimestampMs: Int64,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Void> {
        // Note: It's possible to send a message and then delete the open group you sent the message to
        // which would go into this case, so rather than handling it as an invalid state we just want to
        // error in a non-retryable way
        guard
            let message: VisibleMessage = message as? VisibleMessage,
            case .openGroup(let roomToken, let server, let whisperTo, let whisperMods) = destination,
            let openGroup: OpenGroup = try? OpenGroup.fetchOne(
                db,
                id: OpenGroup.idFor(roomToken: roomToken, server: server)
            ),
            let userEdKeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db)
        else { throw MessageSenderError.invalidMessage }
        
        // Set the sender/recipient info (needed to be valid)
        let threadId: String = OpenGroup.idFor(roomToken: roomToken, server: server)
        message.sender = try {
            let capabilities: [Capability.Variant] = (try? Capability
                .select(.variant)
                .filter(Capability.Columns.openGroupServer == server)
                .filter(Capability.Columns.isMissing == false)
                .asRequest(of: Capability.Variant.self)
                .fetchAll(db))
                .defaulting(to: [])
            
            // If the server doesn't support blinding then go with an unblinded id
            guard capabilities.isEmpty || capabilities.contains(.blind) else {
                return SessionId(.unblinded, publicKey: userEdKeyPair.publicKey).hexString
            }
            guard
                let blinded15KeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                    .blinded15KeyPair(serverPublicKey: openGroup.publicKey, ed25519SecretKey: userEdKeyPair.secretKey)
                )
            else { throw MessageSenderError.signingFailed }
            
            return SessionId(.blinded15, publicKey: blinded15KeyPair.publicKey).hexString
        }()
        
        // Ensure the message is valid
        try MessageSender.ensureValidMessage(message, destination: destination, fileIds: fileIds, using: dependencies)
        
        // Attach the user's profile
        message.profile = VisibleMessage.VMProfile(
            profile: Profile.fetchOrCreateCurrentUser(db, using: dependencies),
            blocksCommunityMessageRequests: !db[.checkForCommunityMessageRequests]
        )

        guard !(message.profile?.displayName ?? "").isEmpty else { throw MessageSenderError.noUsername }
        
        // Perform any pre-send actions
        handleMessageWillSend(db, message: message, destination: destination, interactionId: interactionId)
        
        // Convert it to protobuf
        guard let proto = message.toProto(db, threadId: threadId) else {
            throw MessageSenderError.protoConversionFailed
        }
        
        // Serialize the protobuf
        let plaintext: Data = try Result(proto.serializedData().paddedMessageBody())
            .mapError { MessageSenderError.other(nil, "Couldn't serialize proto", $0) }
            .successOrThrow()
        
        return try OpenGroupAPI
            .preparedSend(
                db,
                plaintext: plaintext,
                to: roomToken,
                on: server,
                whisperTo: whisperTo,
                whisperMods: whisperMods,
                fileIds: fileIds,
                using: dependencies
            )
            .handleEvents(
                receiveOutput: { _, response in
                    let serverTimestampMs: UInt64? = response.posted.map { UInt64(floor($0 * 1000)) }
                    let updatedMessage: Message = message
                    updatedMessage.openGroupServerMessageId = UInt64(response.id)
                    
                    dependencies[singleton: .storage].write { db in
                        // The `posted` value is in seconds but we sent it in ms so need that for de-duping
                        try MessageSender.handleSuccessfulMessageSend(
                            db,
                            message: updatedMessage,
                            to: destination,
                            interactionId: interactionId,
                            serverTimestampMs: serverTimestampMs,
                            using: dependencies
                        )
                    }
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            dependencies[singleton: .storage].read { db in
                                MessageSender.handleFailedMessageSend(
                                    db,
                                    message: message,
                                    destination: destination,
                                    error: .other(nil, "Couldn't send message", error),
                                    interactionId: interactionId,
                                    using: dependencies
                                )
                            }
                    }
                }
            )
            .map { _, _ in () }
    }
    
    private static func preparedSendToOpenGroupInboxDestination(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        fileIds: [String],
        userSessionId: SessionId,
        messageSendTimestampMs: Int64,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Void> {
        // The `openGroupInbox` destination does not support attachments
        guard
            fileIds.isEmpty,
            case .openGroupInbox(let server, let openGroupPublicKey, let recipientBlindedPublicKey) = destination
        else { throw MessageSenderError.invalidMessage }
        
        message.sender = userSessionId.hexString
        
        // Attach the user's profile if needed
        if let message: VisibleMessage = message as? VisibleMessage {
            let profile: Profile = Profile.fetchOrCreateCurrentUser(db, using: dependencies)
            
            if let profileKey: Data = profile.profileEncryptionKey, let profilePictureUrl: String = profile.profilePictureUrl {
                message.profile = VisibleMessage.VMProfile(
                    displayName: profile.name,
                    profileKey: profileKey,
                    profilePictureUrl: profilePictureUrl
                )
            }
            else {
                message.profile = VisibleMessage.VMProfile(displayName: profile.name)
            }
        }
        
        // Perform any pre-send actions
        handleMessageWillSend(db, message: message, destination: destination, interactionId: interactionId)
        
        // Convert it to protobuf
        guard let proto = message.toProto(db, threadId: recipientBlindedPublicKey) else {
            throw MessageSenderError.protoConversionFailed
        }
        
        // Serialize the protobuf
        let plaintext: Data = try Result(proto.serializedData().paddedMessageBody())
            .mapError { MessageSenderError.other(nil, "Couldn't serialize proto", $0) }
            .successOrThrow()
        
        // Encrypt the serialized protobuf
        let ciphertext: Data = try dependencies[singleton: .crypto].generateResult(
            .ciphertextWithSessionBlindingProtocol(
                db,
                plaintext: plaintext,
                recipientBlindedId: recipientBlindedPublicKey,
                serverPublicKey: openGroupPublicKey,
                using: dependencies
            )
        )
        .mapError { MessageSenderError.other(nil, "Couldn't encrypt message for destination: \(destination)", $0) }
        .successOrThrow()
        
        return try OpenGroupAPI
            .preparedSend(
                db,
                ciphertext: ciphertext,
                toInboxFor: recipientBlindedPublicKey,
                on: server,
                using: dependencies
            )
            .handleEvents(
                receiveOutput: { _, response in
                    let updatedMessage: Message = message
                    updatedMessage.openGroupServerMessageId = UInt64(response.id)
                    
                    dependencies[singleton: .storage].write { db in
                        // The `posted` value is in seconds but we sent it in ms so need that for de-duping
                        try MessageSender.handleSuccessfulMessageSend(
                            db,
                            message: updatedMessage,
                            to: destination,
                            interactionId: interactionId,
                            serverTimestampMs: UInt64(floor(response.posted * 1000)),
                            using: dependencies
                        )
                    }
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            dependencies[singleton: .storage].read { db in
                                MessageSender.handleFailedMessageSend(
                                    db,
                                    message: message,
                                    destination: destination,
                                    error: .other(nil, "Couldn't send message", error),
                                    interactionId: interactionId,
                                    using: dependencies
                                )
                            }
                    }
                }
            )
            .map { _, _ in () }
    }

    // MARK: - Success & Failure Handling
    
    private static func ensureValidMessage(
        _ message: Message,
        destination: Message.Destination,
        fileIds: [String],
        using dependencies: Dependencies
    ) throws {
        /// Check the message itself is valid
        guard message.isValid(using: dependencies) else { throw MessageSenderError.invalidMessage }
        
        /// We now allow the creation of message data without validating it's attachments have finished uploading first, this is here to
        /// ensure we don't send a message which should have uploaded files
        ///
        /// If you see this error then you need to upload the associated attachments prior to sending the message
        if let visibleMessage: VisibleMessage = message as? VisibleMessage {
            let expectedAttachmentUploadCount: Int = (
                visibleMessage.attachmentIds.count +
                (visibleMessage.linkPreview?.attachmentId != nil ? 1 : 0) +
                (visibleMessage.quote?.attachmentId != nil ? 1 : 0)
            )
            
            guard expectedAttachmentUploadCount == fileIds.count else {
                throw MessageSenderError.attachmentsNotUploaded
            }
        }
    }
    
    public static func handleMessageWillSend(
        _ db: Database,
        message: Message,
        destination: Message.Destination,
        interactionId: Int64?
    ) {
        // If the message was a reaction then we don't want to do anything to the original
        // interaction (which the 'interactionId' is pointing to
        guard (message as? VisibleMessage)?.reaction == nil else { return }
        
        // Mark messages as "sending"/"syncing" if needed (this is for retries)
        switch destination {
            case .syncMessage:
                _ = try? Interaction
                    .filter(id: interactionId)
                    .filter(Interaction.Columns.state == Interaction.State.failedToSync)
                    .updateAll(db, Interaction.Columns.state.set(to: Interaction.State.syncing))
                
            default:
                _ = try? Interaction
                    .filter(id: interactionId)
                    .filter(Interaction.Columns.state == Interaction.State.failed)
                    .updateAll(db, Interaction.Columns.state.set(to: Interaction.State.sending))
        }
    }
    
    private static func handleSuccessfulMessageSend(
        _ db: Database,
        message: Message,
        to destination: Message.Destination,
        interactionId: Int64?,
        serverTimestampMs: UInt64? = nil,
        using dependencies: Dependencies
    ) throws {
        // If the message was a reaction then we want to update the reaction instead of the original
        // interaction (which the 'interactionId' is pointing to
        if let visibleMessage: VisibleMessage = message as? VisibleMessage, let reaction: VisibleMessage.VMReaction = visibleMessage.reaction {
            try Reaction
                .filter(Reaction.Columns.interactionId == interactionId)
                .filter(Reaction.Columns.authorId == reaction.publicKey)
                .filter(Reaction.Columns.emoji == reaction.emoji)
                .updateAll(db, Reaction.Columns.serverHash.set(to: message.serverHash))
        }
        else {
            // Otherwise we do want to try and update the referenced interaction
            let interaction: Interaction? = try interaction(db, for: message, interactionId: interactionId)
            
            // Get the visible message if possible
            if let interaction: Interaction = interaction {
                // Only store the server hash of a sync message if the message is self send valid
                switch (message.isSelfSendValid, destination) {
                    case (false, .syncMessage):
                        try interaction.with(state: .sent).update(db)
                    
                    case (true, .syncMessage), (_, .contact), (_, .closedGroup), (_, .openGroup), (_, .openGroupInbox):
                        try interaction.with(
                            serverHash: message.serverHash,
                            // Track the open group server message ID and update server timestamp (use server
                            // timestamp for open group messages otherwise the quote messages may not be able
                            // to be found by the timestamp on other devices
                            timestampMs: (message.openGroupServerMessageId == nil ?
                                nil :
                                serverTimestampMs.map { Int64($0) }
                            ),
                            openGroupServerMessageId: message.openGroupServerMessageId.map { Int64($0) },
                            state: .sent
                        ).update(db)
                        
                        if interaction.isExpiringMessage {
                            // Start disappearing messages job after a message is successfully sent.
                            // For DAR and DAS outgoing messages, the expiration start time are the
                            // same as message sentTimestamp. So do this once, DAR and DAS messages
                            // should all be covered.
                            dependencies[singleton: .jobRunner].upsert(
                                db,
                                job: DisappearingMessagesJob.updateNextRunIfNeeded(
                                    db,
                                    interaction: interaction,
                                    startedAtMs: Double(interaction.timestampMs),
                                    using: dependencies
                                ),
                                canStartJob: true
                            )
                        
                            if
                                case .syncMessage = destination,
                                let startedAtMs: Double = interaction.expiresStartedAtMs,
                                let expiresInSeconds: TimeInterval = interaction.expiresInSeconds,
                                let serverHash: String = message.serverHash
                            {
                                let expirationTimestampMs: Int64 = Int64(startedAtMs + expiresInSeconds * 1000)
                                dependencies[singleton: .jobRunner].add(
                                    db,
                                    job: Job(
                                        variant: .expirationUpdate,
                                        behaviour: .runOnce,
                                        threadId: interaction.threadId,
                                        details: ExpirationUpdateJob.Details(
                                            serverHashes: [serverHash],
                                            expirationTimestampMs: expirationTimestampMs
                                        )
                                    ),
                                    canStartJob: true
                                )
                            }
                        }
                    }
            }
        }
        
        // Extract the threadId from the message
        let threadId: String = Message.threadId(forMessage: message, destination: destination)
        
        // Prevent ControlMessages from being handled multiple times if not supported
        try? ControlMessageProcessRecord(
            threadId: threadId,
            message: message,
            serverExpirationTimestamp: (
                TimeInterval(dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000) +
                ControlMessageProcessRecord.defaultExpirationSeconds
            )
        )?.insert(db)

        // Sync the message if needed
        scheduleSyncMessageIfNeeded(
            db,
            message: message,
            destination: destination,
            threadId: threadId,
            interactionId: interactionId,
            using: dependencies
        )
    }

    @discardableResult internal static func handleFailedMessageSend(
        _ db: Database,
        message: Message,
        destination: Message.Destination?,
        error: MessageSenderError,
        interactionId: Int64?,
        using dependencies: Dependencies
    ) -> Error {
        // Log a message for any 'other' errors
        switch error {
            case .other(let cat, let description, let error):
                Log.error([.messageSender, cat].compactMap { $0 }, "\(description) due to error: \(error).")
            default: break
        }
        
        // Only 'VisibleMessage' messages can show a status so don't bother updating
        // the other cases (if the VisibleMessage was a reaction then we also don't
        // want to do anything as the `interactionId` points to the original message
        // which has it's own status)
        switch message {
            case let message as VisibleMessage where message.reaction != nil: return error
            case is VisibleMessage: break
            default: return error
        }
        
        // Check if we need to mark any "sending" recipients as "failed"
        //
        // Note: The 'db' could be either read-only or writeable so we determine
        // if a change is required, and if so dispatch to a separate queue for the
        // actual write
        let rowIds: [Int64] = (try? {
            switch destination {
                case .syncMessage:
                    return Interaction
                        .select(Column.rowID)
                        .filter(id: interactionId)
                        .filter(
                            Interaction.Columns.state == Interaction.State.syncing ||
                            Interaction.Columns.state == Interaction.State.sent
                        )
                    
                default:
                    return Interaction
                        .select(Column.rowID)
                        .filter(id: interactionId)
                        .filter(Interaction.Columns.state == Interaction.State.sending)
            }
        }()
        .asRequest(of: Int64.self)
        .fetchAll(db))
        .defaulting(to: [])
        
        guard !rowIds.isEmpty else { return error }
        
        // Need to dispatch to a different thread as this function is most commonly called within a read
        // thread and we want to write to the db and don't want to run into a re-entrancy error
        DispatchQueue.global(qos: .background).async(using: dependencies) {
            dependencies[singleton: .storage].write { db in
                switch destination {
                    case .syncMessage:
                        try Interaction
                            .filter(rowIds.contains(Column.rowID))
                            .updateAll(
                                db,
                                Interaction.Columns.state.set(to: Interaction.State.failedToSync),
                                Interaction.Columns.mostRecentFailureText.set(to: "\(error)")
                            )
                        
                    default:
                        try Interaction
                            .filter(rowIds.contains(Column.rowID))
                            .updateAll(
                                db,
                                Interaction.Columns.state.set(to: Interaction.State.failed),
                                Interaction.Columns.mostRecentFailureText.set(to: "\(error)")
                            )
                }
            }
        }
        
        return error
    }
    
    // MARK: - Convenience
    
    private static func interaction(_ db: Database, for message: Message, interactionId: Int64?) throws -> Interaction? {
        if let interactionId: Int64 = interactionId {
            return try Interaction.fetchOne(db, id: interactionId)
        }
        
        if let sentTimestampMs: Double = message.sentTimestampMs.map({ Double($0) }) {
            return try Interaction
                .filter(Interaction.Columns.timestampMs == sentTimestampMs)
                .fetchOne(db)
        }
        
        return nil
    }
    
    public static func scheduleSyncMessageIfNeeded(
        _ db: Database,
        message: Message,
        destination: Message.Destination,
        threadId: String?,
        interactionId: Int64?,
        using dependencies: Dependencies
    ) {
        // Sync the message if it's not a sync message, wasn't already sent to the current user and
        // it's a message type which should be synced
        let userSessionId = dependencies[cache: .general].sessionId
        
        if
            case .contact(let publicKey) = destination,
            publicKey != userSessionId.hexString,
            Message.shouldSync(message: message)
        {
            if let message = message as? VisibleMessage { message.syncTarget = publicKey }
            if let message = message as? ExpirationTimerUpdate { message.syncTarget = publicKey }
            
            dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .messageSend,
                    threadId: threadId,
                    interactionId: interactionId,
                    details: MessageSendJob.Details(
                        destination: .syncMessage(originalRecipientPublicKey: publicKey),
                        message: message
                    )
                ),
                canStartJob: true
            )
        }
    }
}
