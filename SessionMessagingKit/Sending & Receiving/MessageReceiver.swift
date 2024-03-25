// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Sodium
import SessionUIKit
import SessionUtilitiesKit
import SessionSnodeKit

public enum MessageReceiver {
    private static var lastEncryptionKeyPairRequest: [String: Date] = [:]
    
    public static func parse(
        _ db: Database,
        envelope: SNProtoEnvelope,
        serverExpirationTimestamp: TimeInterval?,
        openGroupId: String?,
        openGroupMessageServerId: Int64?,
        openGroupServerPublicKey: String?,
        isOutgoing: Bool? = nil,
        otherBlindedPublicKey: String? = nil,
        using dependencies: Dependencies = Dependencies()
    ) throws -> (Message, SNProtoContent, String, SessionThread.Variant) {
        let userPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
        let isOpenGroupMessage: Bool = (openGroupId != nil)
        
        // Decrypt the contents
        guard let ciphertext = envelope.content else { throw MessageReceiverError.noData }
        
        var plaintext: Data
        var sender: String
        var groupPublicKey: String? = nil
        
        if isOpenGroupMessage {
            (plaintext, sender) = (envelope.content!, envelope.source!)
        }
        else {
            switch envelope.type {
                case .sessionMessage:
                    // Default to 'standard' as the old code didn't seem to require an `envelope.source`
                    switch (SessionId.Prefix(from: envelope.source) ?? .standard) {
                        case .standard, .unblinded:
                            guard let userX25519KeyPair: KeyPair = Identity.fetchUserKeyPair(db) else {
                                throw MessageReceiverError.noUserX25519KeyPair
                            }
                            
                            (plaintext, sender) = try decryptWithSessionProtocol(ciphertext: ciphertext, using: userX25519KeyPair)
                            
                        case .blinded15, .blinded25:
                            guard let otherBlindedPublicKey: String = otherBlindedPublicKey else {
                                throw MessageReceiverError.noData
                            }
                            guard let openGroupServerPublicKey: String = openGroupServerPublicKey else {
                                throw MessageReceiverError.invalidGroupPublicKey
                            }
                            guard let userEd25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db) else {
                                throw MessageReceiverError.noUserED25519KeyPair
                            }
                            
                            (plaintext, sender) = try decryptWithSessionBlindingProtocol(
                                data: ciphertext,
                                isOutgoing: (isOutgoing == true),
                                otherBlindedPublicKey: otherBlindedPublicKey,
                                with: openGroupServerPublicKey,
                                userEd25519KeyPair: userEd25519KeyPair,
                                using: dependencies
                            )
                            
                        case .group:
                            // TODO: Need to decide how we will handle updated group messages
                            SNLog("Ignoring message with invalid sender.")
                            throw HTTPError.parsingFailed
                    }
                    
                case .closedGroupMessage:
                    guard
                        let hexEncodedGroupPublicKey = envelope.source,
                        let closedGroup: ClosedGroup = try? ClosedGroup.fetchOne(db, id: hexEncodedGroupPublicKey)
                    else {
                        throw MessageReceiverError.invalidGroupPublicKey
                    }
                    guard
                        let encryptionKeyPairs: [ClosedGroupKeyPair] = try? closedGroup.keyPairs
                            .order(ClosedGroupKeyPair.Columns.receivedTimestamp.desc)
                            .fetchAll(db),
                        !encryptionKeyPairs.isEmpty
                    else {
                        throw MessageReceiverError.noGroupKeyPair
                    }
                    
                    // Loop through all known group key pairs in reverse order (i.e. try the latest key
                    // pair first (which'll more than likely be the one we want) but try older ones in
                    // case that didn't work)
                    func decrypt(keyPairs: [ClosedGroupKeyPair], lastError: Error? = nil) throws -> (Data, String) {
                        guard let keyPair: ClosedGroupKeyPair = keyPairs.first else {
                            throw (lastError ?? MessageReceiverError.decryptionFailed)
                        }
                        
                        do {
                            return try decryptWithSessionProtocol(
                                ciphertext: ciphertext,
                                using: KeyPair(
                                    publicKey: keyPair.publicKey.bytes,
                                    secretKey: keyPair.secretKey.bytes
                                )
                            )
                        }
                        catch {
                            return try decrypt(keyPairs: Array(keyPairs.suffix(from: 1)), lastError: error)
                        }
                    }
                    
                    groupPublicKey = hexEncodedGroupPublicKey
                    (plaintext, sender) = try decrypt(keyPairs: encryptionKeyPairs)
                
                default: throw MessageReceiverError.unknownEnvelopeType
            }
        }
        
        // Don't process the envelope any further if the sender is blocked
        guard (try? Contact.fetchOne(db, id: sender))?.isBlocked != true else {
            throw MessageReceiverError.senderBlocked
        }
        
        // Parse the proto
        let proto: SNProtoContent
        
        do {
            proto = try SNProtoContent.parseData(plaintext.removePadding())
        }
        catch {
            SNLog("Couldn't parse proto due to error: \(error).")
            throw error
        }
        
        // Parse the message
        guard let message: Message = Message.createMessageFrom(proto, sender: sender) else {
            throw MessageReceiverError.unknownMessage
        }
        
        // Ignore self sends if needed
        guard message.isSelfSendValid || sender != userPublicKey else {
            throw MessageReceiverError.selfSend
        }
        
        // Guard against control messages in open groups
        guard !isOpenGroupMessage || message is VisibleMessage else {
            throw MessageReceiverError.invalidMessage
        }
        
        // Finish parsing
        message.sender = sender
        message.recipient = userPublicKey
        message.sentTimestamp = envelope.timestamp
        message.receivedTimestamp = UInt64(SnodeAPI.currentOffsetTimestampMs())
        message.openGroupServerMessageId = openGroupMessageServerId.map { UInt64($0) }
        message.attachDisappearingMessagesConfiguration(from: proto)
        
        // Validate
        var isValid: Bool = message.isValid
        if message is VisibleMessage && !isValid && proto.dataMessage?.attachments.isEmpty == false {
            isValid = true
        }
        
        guard isValid else {
            throw MessageReceiverError.invalidMessage
        }
        
        // Extract the proper threadId for the message
        let (threadId, threadVariant): (String, SessionThread.Variant) = {
            if let groupPublicKey: String = groupPublicKey { return (groupPublicKey, .legacyGroup) }
            if let openGroupId: String = openGroupId { return (openGroupId, .community) }
            
            switch message {
                case let message as VisibleMessage: return ((message.syncTarget ?? sender), .contact)
                case let message as ExpirationTimerUpdate: return ((message.syncTarget ?? sender), .contact)
                default: return (sender, .contact)
            }
        }()
        
        return (message, proto, threadId, threadVariant)
    }
    
    // MARK: - Handling
    
    public static func handle(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: Message,
        serverExpirationTimestamp: TimeInterval?,
        associatedWithProto proto: SNProtoContent,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        // Check if the message requires an existing conversation (if it does and the conversation isn't in
        // the config then the message will be dropped)
        guard
            !Message.requiresExistingConversation(message: message, threadVariant: threadVariant) ||
            SessionUtil.conversationInConfig(db, threadId: threadId, threadVariant: threadVariant, visibleOnly: false)
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
                    serverExpirationTimestamp: serverExpirationTimestamp
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
                    message: message
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
                
            // SharedConfigMessages should be handled by the 'SharedUtil' instead of this
            case is SharedConfigMessage: throw MessageReceiverError.invalidSharedConfigMessageHandling
            case is LegacyConfigurationMessage: TopBannerController.show(warning: .outdatedUserConfig)
                
            default: fatalError()
        }
        
        // Perform any required post-handling logic
        try MessageReceiver.postHandleMessage(db, threadId: threadId, message: message)
    }
    
    public static func postHandleMessage(
        _ db: Database,
        threadId: String,
        message: Message
    ) throws {
        // When handling any message type which has related UI we want to make sure the thread becomes
        // visible (the only other spot this flag gets set is when sending messages)
        switch message {
            case is ReadReceipt: break
            case is TypingIndicator: break
            case is LegacyConfigurationMessage: break
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
                JobRunner.upsert(
                    db,
                    job: DisappearingMessagesJob.updateNextRunIfNeeded(db)
                )

                guard !isCurrentlyVisible else { return }
                
                try SessionThread
                    .filter(id: threadId)
                    .updateAllAndConfig(
                        db,
                        SessionThread.Columns.shouldBeVisible.set(to: true),
                        SessionThread.Columns.pinnedPriority.set(to: SessionUtil.visiblePriority)
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
        using dependencies: Dependencies = Dependencies()
    ) throws {
        switch message {
            case is ReadReceipt: return // No visible artifact created so better to keep for more reliable read states
            case is UnsendRequest: return // We should always process the removal of messages just in case
            default: break
        }
        
        // Determine the state of the conversation and the validity of the message
        let currentUserPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
        let conversationVisibleInConfig: Bool = SessionUtil.conversationInConfig(
            db,
            threadId: threadId,
            threadVariant: threadVariant,
            visibleOnly: true
        )
        let canPerformChange: Bool = SessionUtil.canPerformChange(
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
