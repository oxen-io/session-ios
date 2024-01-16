// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

/// Abstract base class for `VisibleMessage` and `ControlMessage`.
public class Message: Codable {
    public var id: String?
    public var sentTimestamp: UInt64?
    public var receivedTimestamp: UInt64?
    public var recipient: String?
    public var sender: String?
    public var openGroupServerMessageId: UInt64?
    public var serverHash: String?
    public var ttl: UInt64 { 14 * 24 * 60 * 60 * 1000 }
    public var isSelfSendValid: Bool { false }
    
    public var shouldBeRetryable: Bool { false }
    public var processWithBlockedSender: Bool { false }
    
    // MARK: - Disappearing Messages
    public var expiresInSeconds: TimeInterval?
    public var expiresStartedAtMs: Double?

    // MARK: - Validation
    
    public func isValid(using dependencies: Dependencies) -> Bool {
        if let sentTimestamp = sentTimestamp { guard sentTimestamp > 0 else { return false } }
        if let receivedTimestamp = receivedTimestamp { guard receivedTimestamp > 0 else { return false } }
        return sender != nil && recipient != nil
    }
    
    // MARK: - Initialization
    
    public init(
        id: String? = nil,
        sentTimestamp: UInt64? = nil,
        receivedTimestamp: UInt64? = nil,
        recipient: String? = nil,
        sender: String? = nil,
        groupPublicKey: String? = nil,
        openGroupServerMessageId: UInt64? = nil,
        serverHash: String? = nil,
        expiresInSeconds: TimeInterval? = nil,
        expiresStartedAtMs: Double? = nil
    ) {
        self.id = id
        self.sentTimestamp = sentTimestamp
        self.receivedTimestamp = receivedTimestamp
        self.recipient = recipient
        self.sender = sender
        self.openGroupServerMessageId = openGroupServerMessageId
        self.serverHash = serverHash
        self.expiresInSeconds = expiresInSeconds
        self.expiresStartedAtMs = expiresStartedAtMs
    }

    // MARK: - Proto Conversion
    
    public class func fromProto(_ proto: SNProtoContent, sender: String) -> Self? {
        preconditionFailure("fromProto(_:sender:) is abstract and must be overridden.")
    }

    public func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        preconditionFailure("toProto(_:) is abstract and must be overridden.")
    }
    
    public func setDisappearingMessagesConfigurationIfNeeded(_ db: Database, on proto: SNProtoContent.SNProtoContentBuilder, threadId: String) {
        guard let disappearingMessagesConfiguration = try? DisappearingMessagesConfiguration.fetchOne(db, id: threadId) else {
            proto.setExpirationTimer(0)
            return
        }
        
        let expireTimer: UInt32 = disappearingMessagesConfiguration.isEnabled ? UInt32(disappearingMessagesConfiguration.durationSeconds) : 0
        proto.setExpirationTimer(expireTimer)
        proto.setLastDisappearingMessageChangeTimestamp(UInt64(disappearingMessagesConfiguration.lastChangeTimestampMs ?? 0))
        
        if disappearingMessagesConfiguration.isEnabled, let type = disappearingMessagesConfiguration.type {
            proto.setExpirationType(type.toProto())
        }
    }
    
    public func attachDisappearingMessagesConfiguration(from proto: SNProtoContent) {
        let expiresInSeconds: TimeInterval? = proto.hasExpirationTimer ? TimeInterval(proto.expirationTimer) : nil
        let expiresStartedAtMs: Double? = {
            if proto.expirationType == .deleteAfterSend, let timestamp = self.sentTimestamp {
                return Double(timestamp)
            }
            return nil
        }()
        
        self.expiresInSeconds = expiresInSeconds
        self.expiresStartedAtMs = expiresStartedAtMs
    }
}

// MARK: - Message Parsing/Processing

public protocol NotProtoConvertible {}

public enum ProcessedMessage {
    case standard(
        threadId: String,
        threadVariant: SessionThread.Variant,
        proto: SNProtoContent,
        messageInfo: MessageReceiveJob.Details.MessageInfo
    )
    case config(
        publicKey: String,
        namespace: SnodeAPI.Namespace,
        serverHash: String,
        serverTimestampMs: Int64,
        data: Data
    )
    
    var threadId: String {
        switch self {
            case .standard(let threadId, _, _, _): return threadId
            case .config(let publicKey, _, _, _, _): return publicKey
        }
    }
    
    var namespace: SnodeAPI.Namespace {
        switch self {
            case .standard(_, let threadVariant, _, _):
                switch threadVariant {
                    case .group: return .groupMessages
                    case .legacyGroup: return .legacyClosedGroup
                    case .contact, .community: return .default
                }
                
            case .config(_, let namespace, _, _, _): return namespace
        }
    }
    
    var isConfigMessage: Bool {
        switch self {
            case .standard: return false
            case .config: return true
        }
    }
}

public extension Message {
    enum Variant: String, Codable, CaseIterable {
        case readReceipt
        case typingIndicator
        case closedGroupControlMessage
        case dataExtractionNotification
        case expirationTimerUpdate
        case unsendRequest
        case messageRequestResponse
        case visibleMessage
        case callMessage
        case groupUpdateInvite
        case groupUpdatePromote
        case groupUpdateInfoChange
        case groupUpdateMemberChange
        case groupUpdateMemberLeft
        case groupUpdateInviteResponse
        case groupUpdateDeleteMemberContent
        case libSessionMessage
        
        init?(from type: Message) {
            switch type {
                case is ReadReceipt: self = .readReceipt
                case is TypingIndicator: self = .typingIndicator
                case is ClosedGroupControlMessage: self = .closedGroupControlMessage
                case is DataExtractionNotification: self = .dataExtractionNotification
                case is ExpirationTimerUpdate: self = .expirationTimerUpdate
                case is UnsendRequest: self = .unsendRequest
                case is MessageRequestResponse: self = .messageRequestResponse
                case is VisibleMessage: self = .visibleMessage
                case is CallMessage: self = .callMessage
                case is GroupUpdateInviteMessage: self = .groupUpdateInvite
                case is GroupUpdatePromoteMessage: self = .groupUpdatePromote
                case is GroupUpdateInfoChangeMessage: self = .groupUpdateInfoChange
                case is GroupUpdateMemberChangeMessage: self = .groupUpdateMemberChange
                case is GroupUpdateMemberLeftMessage: self = .groupUpdateMemberLeft
                case is GroupUpdateInviteResponseMessage: self = .groupUpdateInviteResponse
                case is GroupUpdateDeleteMemberContentMessage: self = .groupUpdateDeleteMemberContent
                case is LibSessionMessage: self = .libSessionMessage
                default: return nil
            }
        }
        
        var messageType: Message.Type {
            switch self {
                case .readReceipt: return ReadReceipt.self
                case .typingIndicator: return TypingIndicator.self
                case .closedGroupControlMessage: return ClosedGroupControlMessage.self
                case .dataExtractionNotification: return DataExtractionNotification.self
                case .expirationTimerUpdate: return ExpirationTimerUpdate.self
                case .unsendRequest: return UnsendRequest.self
                case .messageRequestResponse: return MessageRequestResponse.self
                case .visibleMessage: return VisibleMessage.self
                case .callMessage: return CallMessage.self
                case .groupUpdateInvite: return GroupUpdateInviteMessage.self
                case .groupUpdatePromote: return GroupUpdatePromoteMessage.self
                case .groupUpdateInfoChange: return GroupUpdateInfoChangeMessage.self
                case .groupUpdateMemberChange: return GroupUpdateMemberChangeMessage.self
                case .groupUpdateMemberLeft: return GroupUpdateMemberLeftMessage.self
                case .groupUpdateInviteResponse: return GroupUpdateInviteResponseMessage.self
                case .groupUpdateDeleteMemberContent: return GroupUpdateDeleteMemberContentMessage.self
                case .libSessionMessage: return LibSessionMessage.self
            }
        }
        
        /// This value ensures the variants can be ordered to ensure the correct types are processed and aren't parsed as the wrong type
        /// due to the structures being close enough matches
        var protoPriority: Int {
            switch self {
                case .readReceipt: return 0
                case .typingIndicator: return 1
                case .closedGroupControlMessage: return 2
                case .dataExtractionNotification: return 10
                case .expirationTimerUpdate: return 11
                case .unsendRequest: return 12
                case .messageRequestResponse: return 13
                case .visibleMessage: return 14
                case .callMessage: return 15
                case .groupUpdateInvite: return 3
                case .groupUpdatePromote: return 4
                case .groupUpdateInfoChange: return 5
                case .groupUpdateMemberChange: return 6
                case .groupUpdateMemberLeft: return 7
                case .groupUpdateInviteResponse: return 8
                case .groupUpdateDeleteMemberContent: return 9
                case .libSessionMessage: return 16
            }
        }
        
        var isProtoConvetible: Bool {
            return !(self.messageType is NotProtoConvertible.Type)
        }

        func decode<CodingKeys: CodingKey>(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Message {
            switch self {
                case .readReceipt: return try container.decode(ReadReceipt.self, forKey: key)
                case .typingIndicator: return try container.decode(TypingIndicator.self, forKey: key)
                
                case .closedGroupControlMessage:
                    return try container.decode(ClosedGroupControlMessage.self, forKey: key)
                    
                case .dataExtractionNotification:
                    return try container.decode(DataExtractionNotification.self, forKey: key)
                    
                case .expirationTimerUpdate: return try container.decode(ExpirationTimerUpdate.self, forKey: key)
                
                case .unsendRequest: return try container.decode(UnsendRequest.self, forKey: key)
                case .messageRequestResponse: return try container.decode(MessageRequestResponse.self, forKey: key)
                case .visibleMessage: return try container.decode(VisibleMessage.self, forKey: key)
                case .callMessage: return try container.decode(CallMessage.self, forKey: key)
                    
                case .groupUpdateInvite: return try container.decode(GroupUpdateInviteMessage.self, forKey: key)
                case .groupUpdatePromote: return try container.decode(GroupUpdatePromoteMessage.self, forKey: key)
                
                case .groupUpdateInfoChange:
                    return try container.decode(GroupUpdateInfoChangeMessage.self, forKey: key)
                                                                                
                case .groupUpdateMemberChange:
                    return try container.decode(GroupUpdateMemberChangeMessage.self, forKey: key)
                
                case .groupUpdateMemberLeft:
                    return try container.decode(GroupUpdateMemberLeftMessage.self, forKey: key)
                
                case .groupUpdateInviteResponse:
                    return try container.decode(GroupUpdateInviteResponseMessage.self, forKey: key)
                
                case .groupUpdateDeleteMemberContent:
                    return try container.decode(GroupUpdateDeleteMemberContentMessage.self, forKey: key)
                    
                case .libSessionMessage: return try container.decode(LibSessionMessage.self, forKey: key)
            }
        }
    }
    
    static func createMessageFrom(_ proto: SNProtoContent, sender: String) throws -> Message {
        let decodedMessage: Message? = Variant
            .allCases
            .sorted { lhs, rhs -> Bool in lhs.protoPriority < rhs.protoPriority }
            .filter { variant -> Bool in variant.isProtoConvetible }
            .reduce(nil) { prev, variant in
                guard prev == nil else { return prev }
                
                return variant.messageType.fromProto(proto, sender: sender)
            }
        
        return try decodedMessage ?? { throw MessageReceiverError.unknownMessage }()
    }
    
    static func requiresExistingConversation(message: Message, threadVariant: SessionThread.Variant) -> Bool {
        switch threadVariant {
            /// Process every message sent to these conversation types (the `MessageReceiver` will determine whether a message should
            /// result in a conversation appearing if it's not already visible after processing the message - this just controls whether the messages
            /// should be processed)
            case .contact, .group, .community: return false
                
            case .legacyGroup:
                switch message {
                    case let controlMessage as ClosedGroupControlMessage:
                        switch controlMessage.kind {
                            case .new: return false
                            default: return true
                        }
                        
                    default: return true
                }
        }
    }
    
    static func shouldSync(message: Message) -> Bool {
        switch message {
            case is VisibleMessage: return true
            case is ExpirationTimerUpdate: return true
            case is UnsendRequest: return true
            
            case let controlMessage as ClosedGroupControlMessage:
                switch controlMessage.kind {
                    case .new: return true
                    default: return false
                }
                
            case let callMessage as CallMessage:
                switch callMessage.kind {
                    case .answer, .endCall: return true
                    default: return false
                }
            
            default: return false
        }
    }
    
    static func threadId(forMessage message: Message, destination: Message.Destination) -> String {
        switch destination {
            case .contact(let publicKey):
                // Extract the 'syncTarget' value if there is one
                let maybeSyncTarget: String?
                
                switch message {
                    case let message as VisibleMessage: maybeSyncTarget = message.syncTarget
                    case let message as ExpirationTimerUpdate: maybeSyncTarget = message.syncTarget
                    default: maybeSyncTarget = nil
                }
                
                return (maybeSyncTarget ?? publicKey)
                
            case .closedGroup(let groupPublicKey): return groupPublicKey
            case .openGroup(let roomToken, let server, _, _):
                return OpenGroup.idFor(roomToken: roomToken, server: server)
            
            case .openGroupInbox(_, _, let blindedPublicKey): return blindedPublicKey
        }
    }
    
    static func processRawReceivedMessage(
        _ db: Database,
        rawMessage: SnodeReceivedMessage,
        publicKey: String,
        using dependencies: Dependencies
    ) throws -> ProcessedMessage {
        do {
            let processedMessage: ProcessedMessage = try processRawReceivedMessage(
                db,
                data: rawMessage.data,
                from: .swarm(
                    publicKey: publicKey,
                    namespace: rawMessage.namespace,
                    serverHash: rawMessage.info.hash,
                    serverTimestampMs: rawMessage.timestampMs,
                    serverExpirationTimestamp: TimeInterval(Double(rawMessage.info.expirationDateMs) / 1000)
                ),
                using: dependencies
            )
            
            // Ensure we actually want to de-dupe messages for this namespace, otherwise just
            // succeed early
            guard rawMessage.namespace.shouldDedupeMessages else {
                // If we want to track the last hash then upsert the raw message info (don't
                // want to fail if it already exsits because we don't want to dedupe messages
                // in this namespace)
                if rawMessage.namespace.shouldFetchSinceLastHash {
                    try rawMessage.info.upserted(db)
                }
                
                return processedMessage
            }
            
            // Retrieve the number of entries we have for the hash of this message
            let numExistingHashes: Int = (try? SnodeReceivedMessageInfo
                .filter(SnodeReceivedMessageInfo.Columns.hash == rawMessage.info.hash)
                .fetchCount(db))
                .defaulting(to: 0)
            
            // Try to insert the raw message info into the database (used for both request paging and
            // de-duping purposes)
            _ = try rawMessage.info.inserted(db)
            
            // If the above insertion worked then we hadn't processed this message for this specific
            // service node, but may have done so for another node - if the hash already existed in
            // the database before we inserted it for this node then we can ignore this message as a
            // duplicate
            guard numExistingHashes == 0 else { throw MessageReceiverError.duplicateMessageNewSnode }
            
            return processedMessage
        }
        catch {
            // For some error cases we want to update the last hash so do so
            if (error as? MessageReceiverError)?.shouldUpdateLastHash == true {
                _ = try? rawMessage.info.inserted(db)
            }
            
            throw error
        }
    }
    
    /// This method behaves slightly differently from the other `processRawReceivedMessage` methods as it doesn't
    /// insert the "message info" for deduping (we want the poller to re-process the message) and also avoids handling any
    /// closed group key update messages (the `NotificationServiceExtension` does this itself)
    static func processRawReceivedMessageAsNotification(
        _ db: Database,
        data: Data,
        metadata: PushNotificationAPI.NotificationMetadata,
        using dependencies: Dependencies
    ) throws -> ProcessedMessage? {
        let processedMessage: ProcessedMessage? = try processRawReceivedMessage(
            db,
            data: data,
            from: .swarm(
                publicKey: metadata.accountId,
                namespace: metadata.namespace,
                serverHash: metadata.hash,
                serverTimestampMs: metadata.createdTimestampMs,
                serverExpirationTimestamp: (
                    TimeInterval(Double(SnodeAPI.currentOffsetTimestampMs(using: dependencies)) / 1000) +
                    ControlMessageProcessRecord.defaultExpirationSeconds
                )
            ),
            using: dependencies
        )
        
        return processedMessage
    }
    
    static func processReceivedOpenGroupMessage(
        _ db: Database,
        openGroupId: String,
        openGroupServerPublicKey: String,
        message: OpenGroupAPI.Message,
        data: Data,
        using dependencies: Dependencies = Dependencies()
    ) throws -> ProcessedMessage? {
        // Need a sender in order to process the message
        guard let sender: String = message.sender, let timestamp = message.posted else { return nil }
        
        return try processRawReceivedMessage(
            db,
            data: data,
            from: .community(
                openGroupId: openGroupId,
                sender: sender,
                timestamp: timestamp,
                messageServerId: message.id
            ),
            using: dependencies
        )
    }
    
    static func processReceivedOpenGroupDirectMessage(
        _ db: Database,
        openGroupServerPublicKey: String,
        message: OpenGroupAPI.DirectMessage,
        data: Data,
        using dependencies: Dependencies
    ) throws -> ProcessedMessage? {
        return try processRawReceivedMessage(
            db,
            data: data,
            from: .openGroupInbox(
                timestamp: message.posted,
                messageServerId: message.id,
                serverPublicKey: openGroupServerPublicKey,
                senderId: message.sender,
                recipientId: message.recipient
            ),
            using: dependencies
        )
    }
    
    static func processRawReceivedReactions(
        _ db: Database,
        openGroupId: String,
        message: OpenGroupAPI.Message,
        associatedPendingChanges: [OpenGroupAPI.PendingChange],
        using dependencies: Dependencies
    ) -> [Reaction] {
        guard let reactions: [String: OpenGroupAPI.Message.Reaction] = message.reactions else { return [] }
        
        let currentUserSessionId: SessionId = getUserSessionId(db, using: dependencies)
        let blinded15SessionId: SessionId? = SessionThread
            .getCurrentUserBlindedSessionId(
                db,
                threadId: openGroupId,
                threadVariant: .community,
                blindingPrefix: .blinded15,
                using: dependencies
            )
        let blinded25SessionId: SessionId? = SessionThread
            .getCurrentUserBlindedSessionId(
                db,
                threadId: openGroupId,
                threadVariant: .community,
                blindingPrefix: .blinded25,
                using: dependencies
            )
        
        return reactions
            .reduce(into: []) { result, next in
                guard
                    let decodedEmoji: String = next.key.removingPercentEncoding,
                    next.value.count > 0,
                    let reactors: [String] = next.value.reactors
                else { return }
                
                // Decide whether we need to ignore all reactions
                let pendingChangeRemoveAllReaction: Bool = associatedPendingChanges
                    .contains { pendingChange in
                        if case .reaction(_, let emoji, let action) = pendingChange.metadata {
                            return emoji == decodedEmoji && action == .removeAll
                        }
                        
                        return false
                    }
                
                // Decide whether we need to add an extra reaction from current user
                let pendingChangeSelfReaction: Bool? = {
                    // Find the newest 'PendingChange' entry with a matching emoji, if one exists, and
                    // set the "self reaction" value based on it's action
                    let maybePendingChange: OpenGroupAPI.PendingChange? = associatedPendingChanges
                        .sorted(by: { lhs, rhs -> Bool in (lhs.seqNo ?? Int64.max) >= (rhs.seqNo ?? Int64.max) })
                        .first { pendingChange in
                            if case .reaction(_, let emoji, _) = pendingChange.metadata {
                                return emoji == decodedEmoji
                            }
                            
                            return false
                        }
                    
                    // If there is no pending change for this reaction then return nil
                    guard
                        let pendingChange: OpenGroupAPI.PendingChange = maybePendingChange,
                        case .reaction(_, _, let action) = pendingChange.metadata
                    else { return nil }

                    // Otherwise add/remove accordingly
                    return action == .add
                }()
                let shouldAddSelfReaction: Bool = (
                    pendingChangeSelfReaction ?? (
                        (next.value.you || reactors.contains(currentUserSessionId.hexString)) &&
                        !pendingChangeRemoveAllReaction
                    )
                )
                
                let count: Int64 = (next.value.you ? next.value.count - 1 : next.value.count)
                let timestampMs: Int64 = SnodeAPI.currentOffsetTimestampMs()
                let maxLength: Int = shouldAddSelfReaction ? 4 : 5
                let desiredReactorIds: [String] = reactors
                    .filter { id -> Bool in
                        id != blinded15SessionId?.hexString &&
                        id != blinded25SessionId?.hexString &&
                        id != currentUserSessionId.hexString
                    } // Remove current user for now, will add back if needed
                    .prefix(maxLength)
                    .map { $0 }
                
                // Add the first reaction (with the count)
                if !pendingChangeRemoveAllReaction, let firstReactor: String = desiredReactorIds.first {
                    result.append(
                        Reaction(
                            interactionId: message.id,
                            serverHash: nil,
                            timestampMs: timestampMs,
                            authorId: firstReactor,
                            emoji: decodedEmoji,
                            count: count,
                            sortId: next.value.index
                        )
                    )
                }
                
                // Add all other reactions
                if desiredReactorIds.count > 1 && !pendingChangeRemoveAllReaction {
                    result.append(
                        contentsOf: desiredReactorIds
                            .suffix(from: 1)
                            .map { reactor in
                                Reaction(
                                    interactionId: message.id,
                                    serverHash: nil,
                                    timestampMs: timestampMs,
                                    authorId: reactor,
                                    emoji: decodedEmoji,
                                    count: 0,   // Only want this on the first reaction
                                    sortId: next.value.index
                                )
                            }
                    )
                }
                
                // Add the current user reaction (if applicable and not already included)
                if shouldAddSelfReaction {
                    result.append(
                        Reaction(
                            interactionId: message.id,
                            serverHash: nil,
                            timestampMs: timestampMs,
                            authorId: currentUserSessionId.hexString,
                            emoji: decodedEmoji,
                            count: 1,
                            sortId: next.value.index
                        )
                    )
                }
            }
    }
    
    private static func processRawReceivedMessage(
        _ db: Database,
        data: Data,
        from origin: Message.Origin,
        using dependencies: Dependencies
    ) throws -> ProcessedMessage {
        let processedMessage: ProcessedMessage = try MessageReceiver.parse(
            db,
            data: data,
            origin: origin,
            using: dependencies
        )
        
        switch processedMessage {
            case .standard(let threadId, let threadVariant, _, let messageInfo):
                /// **Note:** We want to immediately handle any `ClosedGroupControlMessage` with the kind `encryptionKeyPair` as
                /// we need the keyPair in storage in order to be able to parse and messages which were signed with the new key (also no need to add
                /// these as jobs as they will be fully handled in here)
                if
                    let controlMessage = messageInfo.message as? ClosedGroupControlMessage,
                    case .encryptionKeyPair = controlMessage.kind
                {
                    try MessageReceiver.handleLegacyClosedGroupControlMessage(
                        db,
                        threadId: threadId,
                        threadVariant: threadVariant,
                        message: controlMessage,
                        using: dependencies
                    )
                }
                
                // Prevent ControlMessages from being handled multiple times if not supported
                do {
                    try ControlMessageProcessRecord(
                        threadId: threadId,
                        message: messageInfo.message,
                        serverExpirationTimestamp: origin.serverExpirationTimestamp
                    )?.insert(db)
                }
                catch {
                    // We want to custom handle this
                    if case DatabaseError.SQLITE_CONSTRAINT_UNIQUE = error {
                        throw MessageReceiverError.duplicateControlMessage
                    }
                    
                    throw error
                }
                
            default: break
        }
        
        return processedMessage
    }
}

// MARK: - Mutation

internal extension Message {
    func with(sentTimestamp: UInt64) -> Message {
        self.sentTimestamp = sentTimestamp
        return self
    }
}
