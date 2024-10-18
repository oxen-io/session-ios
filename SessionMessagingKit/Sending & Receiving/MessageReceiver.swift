// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUIKit
import SessionUtilitiesKit
import SessionSnodeKit

public enum MessageReceiver {
    private static var lastEncryptionKeyPairRequest: [String: Date] = [:]
    
    public static func parse(
        _ db: Database,
        data: Data,
        origin: Message.Origin,
        using dependencies: Dependencies
    ) throws -> ProcessedMessage {
        let userSessionId: String = getUserHexEncodedPublicKey(db, using: dependencies)
        var plaintext: Data
        var customProto: SNProtoContent? = nil
        var customMessage: Message? = nil
        let sender: String
        let sentTimestamp: UInt64
        let serverHash: String?
        let openGroupServerMessageId: UInt64?
        let openGroupWhisper: Bool
        let openGroupWhisperMods: Bool
        let openGroupWhisperTo: String?
        let threadVariant: SessionThread.Variant
        let threadIdGenerator: (Message) throws -> String
        
        switch (origin.isConfigNamespace, origin) {
            // Config messages are custom-handled via 'libSession' so just return the data directly
            case (true, .swarm(let publicKey, let namespace, let serverHash, let serverTimestampMs, _)):
                return .config(
                    publicKey: publicKey,
                    namespace: namespace,
                    serverHash: serverHash,
                    serverTimestampMs: serverTimestampMs,
                    data: data
                )
                
            case (_, .community(let openGroupId, let messageSender, let timestamp, let messageServerId, let messageWhisper, let messageWhisperMods, let messageWhisperTo)):
                plaintext = data.removePadding()   // Remove the padding
                sender = messageSender
                sentTimestamp = UInt64(floor(timestamp * 1000)) // Convert to ms for database consistency
                serverHash = nil
                openGroupServerMessageId = UInt64(messageServerId)
                openGroupWhisper = messageWhisper
                openGroupWhisperMods = messageWhisperMods
                openGroupWhisperTo = messageWhisperTo
                threadVariant = .community
                threadIdGenerator = { message in
                    // Guard against control messages in open groups
                    guard message is VisibleMessage else { throw MessageReceiverError.invalidMessage }
                    
                    return openGroupId
                }
                
            case (_, .openGroupInbox(let timestamp, let messageServerId, let serverPublicKey, let senderId, let recipientId)):
                (plaintext, sender) = try dependencies.crypto.tryGenerate(
                    .plaintextWithSessionBlindingProtocol(
                        db,
                        ciphertext: data,
                        senderId: senderId,
                        recipientId: recipientId,
                        serverPublicKey: serverPublicKey,
                        using: dependencies
                    )
                )
                
                plaintext = plaintext.removePadding()   // Remove the padding
                sentTimestamp = UInt64(floor(timestamp * 1000)) // Convert to ms for database consistency
                serverHash = nil
                openGroupServerMessageId = UInt64(messageServerId)
                openGroupWhisper = false
                openGroupWhisperMods = false
                openGroupWhisperTo = nil
                threadVariant = .contact
                threadIdGenerator = { _ in sender }
                
            case (_, .swarm(let publicKey, let namespace, let swarmServerHash, _, _)):
                switch namespace {
                    case .default:
                        guard
                            let envelope: SNProtoEnvelope = try? MessageWrapper.unwrap(data: data),
                            let ciphertext: Data = envelope.content
                        else {
                            SNLog("Failed to unwrap data for message from 'default' namespace.")
                            throw MessageReceiverError.invalidMessage
                        }
                        
                        (plaintext, sender) = try dependencies.crypto.tryGenerate(
                            .plaintextWithSessionProtocol(
                                db,
                                ciphertext: ciphertext,
                                using: dependencies
                            )
                        )
                        plaintext = plaintext.removePadding()   // Remove the padding
                        sentTimestamp = envelope.timestamp
                        serverHash = swarmServerHash
                        openGroupServerMessageId = nil
                        openGroupWhisper = false
                        openGroupWhisperMods = false
                        openGroupWhisperTo = nil
                        threadVariant = .contact
                        threadIdGenerator = { message in
                            switch message {
                                case let message as VisibleMessage: return (message.syncTarget ?? sender)
                                default: return sender
                            }
                        }
                        
                    case .legacyClosedGroup:
                        guard
                            let envelope: SNProtoEnvelope = try? MessageWrapper.unwrap(data: data),
                            let ciphertext: Data = envelope.content,
                            let closedGroup: ClosedGroup = try? ClosedGroup.fetchOne(db, id: publicKey)
                        else {
                            SNLog("Failed to unwrap data for message from 'legacyClosedGroup' namespace.")
                            throw MessageReceiverError.invalidMessage
                        }
                        
                        guard
                            let encryptionKeyPairs: [ClosedGroupKeyPair] = try? closedGroup.keyPairs
                                .order(ClosedGroupKeyPair.Columns.receivedTimestamp.desc)
                                .fetchAll(db),
                            !encryptionKeyPairs.isEmpty
                        else { throw MessageReceiverError.noGroupKeyPair }
                        
                        // Loop through all known group key pairs in reverse order (i.e. try the latest key
                        // pair first (which'll more than likely be the one we want) but try older ones in
                        // case that didn't work)
                        func decrypt(keyPairs: [ClosedGroupKeyPair], lastError: Error? = nil) throws -> (Data, String) {
                            guard let keyPair: ClosedGroupKeyPair = keyPairs.first else {
                                throw (lastError ?? MessageReceiverError.decryptionFailed)
                            }
                            
                            do {
                                return try dependencies.crypto.tryGenerate(
                                    .plaintextWithSessionProtocolLegacyGroup(
                                        ciphertext: ciphertext,
                                        keyPair: KeyPair(
                                            publicKey: keyPair.publicKey.bytes,
                                            secretKey: keyPair.secretKey.bytes
                                        ),
                                        using: dependencies
                                    )
                                )
                            }
                            catch {
                                return try decrypt(keyPairs: Array(keyPairs.suffix(from: 1)), lastError: error)
                            }
                        }
                        
                        (plaintext, sender) = try decrypt(keyPairs: encryptionKeyPairs)
                        plaintext = plaintext.removePadding()   // Remove the padding
                        sentTimestamp = envelope.timestamp
                        
                        /// If we weren't given a `serverHash` then compute one locally using the same logic the swarm would
                        switch swarmServerHash.isEmpty {
                            case false: serverHash = swarmServerHash
                            case true:
                                serverHash = dependencies.crypto.generate(
                                    .messageServerHash(swarmPubkey: publicKey, namespace: namespace, data: data)
                                ).defaulting(to: "")
                        }
                        
                        openGroupServerMessageId = nil
                        openGroupWhisper = false
                        openGroupWhisperMods = false
                        openGroupWhisperTo = nil
                        threadVariant = .legacyGroup
                        threadIdGenerator = { _ in publicKey }
                        
                    case .configUserProfile, .configContacts, .configConvoInfoVolatile, .configUserGroups:
                        throw MessageReceiverError.invalidConfigMessageHandling
                        
                    case .configClosedGroupInfo:
                        throw MessageReceiverError.invalidConfigMessageHandling
                        
                    case .all, .unknown:
                        SNLog("Couldn't process message due to invalid namespace.")
                        throw MessageReceiverError.unknownMessage
                }
        }
        
        let proto: SNProtoContent = try (customProto ?? Result(catching: { try SNProtoContent.parseData(plaintext) })
           .onFailure { SNLog("Couldn't parse proto due to error: \($0).") }
           .successOrThrow())
        let message: Message = try (customMessage ?? Message.createMessageFrom(proto, sender: sender))
        message.sender = sender
        message.serverHash = serverHash
        message.sentTimestamp = sentTimestamp
        message.receivedTimestamp = UInt64(SnodeAPI.currentOffsetTimestampMs())
        message.openGroupServerMessageId = openGroupServerMessageId
        message.openGroupWhisper = openGroupWhisper
        message.openGroupWhisperMods = openGroupWhisperMods
        message.openGroupWhisperTo = openGroupWhisperTo
        
        // Ignore disappearing message settings in communities (in case of modified clients)
        if threadVariant != .community {
            message.attachDisappearingMessagesConfiguration(from: proto)
        }
        
        // Don't process the envelope any further if the sender is blocked
        guard (try? Contact.fetchOne(db, id: sender))?.isBlocked != true || message.processWithBlockedSender else {
            throw MessageReceiverError.senderBlocked
        }
        
        // Ignore self sends if needed
        guard message.isSelfSendValid || sender != userSessionId else {
            throw MessageReceiverError.selfSend
        }
        
        // Guard against control messages in open groups
        guard !origin.isCommunity || message is VisibleMessage else {
            throw MessageReceiverError.invalidMessage
        }
        
        // Validate
        guard
            message.isValid ||
            (message as? VisibleMessage)?.isValidWithDataMessageAttachments() == true
        else {
            throw MessageReceiverError.invalidMessage
        }
        
        return .standard(
            threadId: try threadIdGenerator(message),
            threadVariant: threadVariant,
            proto: proto,
            messageInfo: try MessageReceiveJob.Details.MessageInfo(
                message: message,
                variant: try Message.Variant(from: message) ?? { throw MessageReceiverError.invalidMessage }(),
                threadVariant: threadVariant,
                serverExpirationTimestamp: origin.serverExpirationTimestamp,
                proto: proto
            )
        )
    }
    
    // MARK: - Handling
    
    public static func handle(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: Message,
        serverExpirationTimestamp: TimeInterval?,
        associatedWithProto proto: SNProtoContent,
        using dependencies: Dependencies
    ) throws {
        // Check if the message requires an existing conversation (if it does and the conversation isn't in
        // the config then the message will be dropped)
        guard
            !Message.requiresExistingConversation(message: message, threadVariant: threadVariant) ||
            LibSession.conversationInConfig(
                db,
                threadId: threadId,
                threadVariant: threadVariant,
                visibleOnly: false,
                using: dependencies
            )
        else { throw MessageReceiverError.requiredThreadNotInConfig }
        
        // Throw if the message is outdated and shouldn't be processed
        try throwIfMessageOutdated(
            db,
            message: message,
            threadId: threadId,
            threadVariant: threadVariant,
            using: dependencies
        )
        
        MessageReceiver.updateContactDisappearingMessagesVersionIfNeeded(
            db,
            messageVariant: .init(from: message),
            contactId: message.sender,
            version: ((!proto.hasExpirationType && !proto.hasExpirationTimer) ?
                .legacyDisappearingMessages :
                .newDisappearingMessages
            )
        )
        
        switch message {
            case let message as ReadReceipt:
                try MessageReceiver.handleReadReceipt(
                    db,
                    message: message,
                    serverExpirationTimestamp: serverExpirationTimestamp
                )
                
            case let message as TypingIndicator:
                try MessageReceiver.handleTypingIndicator(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message
                )
                
            case let message as ClosedGroupControlMessage:
                try MessageReceiver.handleClosedGroupControlMessage(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    using: dependencies
                )
                
            case let message as DataExtractionNotification:
                try MessageReceiver.handleDataExtractionNotification(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    serverExpirationTimestamp: serverExpirationTimestamp,
                    using: dependencies
                )
                
            case let message as ExpirationTimerUpdate:
                try MessageReceiver.handleExpirationTimerUpdate(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    serverExpirationTimestamp: serverExpirationTimestamp,
                    proto: proto
                )
                
            case let message as UnsendRequest:
                try MessageReceiver.handleUnsendRequest(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message
                )
                
            case let message as CallMessage:
                try MessageReceiver.handleCallMessage(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    using: dependencies
                )
                
            case let message as MessageRequestResponse:
                try MessageReceiver.handleMessageRequestResponse(
                    db,
                    message: message,
                    using: dependencies
                )
                
            case let message as VisibleMessage:
                try MessageReceiver.handleVisibleMessage(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message, 
                    serverExpirationTimestamp: serverExpirationTimestamp,
                    associatedWithProto: proto
                )
            
            default: throw MessageReceiverError.unknownMessage
        }
        
        // Perform any required post-handling logic
        try MessageReceiver.postHandleMessage(db, threadId: threadId, threadVariant: threadVariant, message: message)
    }
    
    public static func postHandleMessage(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: Message
    ) throws {
        // When handling any message type which has related UI we want to make sure the thread becomes
        // visible (the only other spot this flag gets set is when sending messages)
        switch message {
            case is ReadReceipt: break
            case is TypingIndicator: break
            case is UnsendRequest: break
                
            case let message as ClosedGroupControlMessage:
                // Only re-show a legacy group conversation if we are going to add a control text message
                switch message.kind {
                    case .new, .encryptionKeyPair, .encryptionKeyPairRequest: return
                    default: break
                }
                
                fallthrough
                
            default:
                // Only update the `shouldBeVisible` flag if the thread is currently not visible
                // as we don't want to trigger a config update if not needed
                let isCurrentlyVisible: Bool = try SessionThread
                    .filter(id: threadId)
                    .select(.shouldBeVisible)
                    .asRequest(of: Bool.self)
                    .fetchOne(db)
                    .defaulting(to: false)
                
                // Start the disappearing messages timer if needed
                // For disappear after send, this is necessary so the message will disappear even if it is not read
                if threadVariant != .community {
                    db.afterNextTransactionNestedOnce(
                        dedupeId: "PostInsertDisappearingMessagesJob",  // stringlint:ignore
                        onCommit: { db in
                            JobRunner.upsert(
                                db,
                                job: DisappearingMessagesJob.updateNextRunIfNeeded(db)
                            )
                        }
                    )
                }

                guard !isCurrentlyVisible else { return }
                
                try SessionThread
                    .filter(id: threadId)
                    .updateAllAndConfig(
                        db,
                        SessionThread.Columns.shouldBeVisible.set(to: true),
                        SessionThread.Columns.pinnedPriority.set(to: LibSession.visiblePriority)
                    )
        }
    }
    
    public static func handleOpenGroupReactions(
        _ db: Database,
        threadId: String,
        openGroupMessageServerId: Int64,
        openGroupReactions: [Reaction]
    ) throws {
        guard let interactionId: Int64 = try? Interaction
            .select(.id)
            .filter(Interaction.Columns.threadId == threadId)
            .filter(Interaction.Columns.openGroupServerMessageId == openGroupMessageServerId)
            .asRequest(of: Int64.self)
            .fetchOne(db)
        else {
            throw MessageReceiverError.invalidMessage
        }
        
        _ = try Reaction
            .filter(Reaction.Columns.interactionId == interactionId)
            .deleteAll(db)
        
        for reaction in openGroupReactions {
            try reaction.with(interactionId: interactionId).insert(db)
        }
    }
    
    public static func throwIfMessageOutdated(
        _ db: Database,
        message: Message,
        threadId: String,
        threadVariant: SessionThread.Variant,
        using dependencies: Dependencies
    ) throws {
        switch message {
            case is ReadReceipt: return // No visible artifact created so better to keep for more reliable read states
            case is UnsendRequest: return // We should always process the removal of messages just in case
            default: break
        }
        
        // Determine the state of the conversation and the validity of the message
        let currentUserPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
        let conversationVisibleInConfig: Bool = LibSession.conversationInConfig(
            db,
            threadId: threadId,
            threadVariant: threadVariant,
            visibleOnly: true,
            using: dependencies
        )
        let canPerformChange: Bool = LibSession.canPerformChange(
            db,
            threadId: threadId,
            targetConfig: {
                switch threadVariant {
                    case .contact: return (threadId == currentUserPublicKey ? .userProfile : .contacts)
                    default: return .userGroups
                }
            }(),
            changeTimestampMs: (message.sentTimestamp.map { Int64($0) } ?? SnodeAPI.currentOffsetTimestampMs())
        )
        
        // If the thread is visible or the message was sent more recently than the last config message (minus
        // buffer period) then we should process the message, if not then throw as the message is outdated
        guard !conversationVisibleInConfig && !canPerformChange else { return }
        
        throw MessageReceiverError.outdatedMessage
    }
}
