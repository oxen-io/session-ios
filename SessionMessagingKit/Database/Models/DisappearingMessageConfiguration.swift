// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUIKit
import SessionUtil
import SessionUtilitiesKit
import SessionSnodeKit

public struct DisappearingMessagesConfiguration: Codable, Identifiable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "disappearingMessagesConfiguration" }
    internal static let threadForeignKey = ForeignKey([Columns.threadId], to: [SessionThread.Columns.id])
    private static let thread = belongsTo(SessionThread.self, using: threadForeignKey)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case threadId
        case isEnabled
        case durationSeconds
        case type
    }
    
    public enum DefaultDuration {
        case off
        case unknown
        case legacy
        case disappearAfterRead
        case disappearAfterSend
        
        public var seconds: TimeInterval {
            switch self {
                case .off, .unknown:      return 0
                case .legacy:             return (24 * 60 * 60)
                case .disappearAfterRead: return (12 * 60 * 60)
                case .disappearAfterSend: return (24 * 60 * 60)
            }
        }
    }
    
    public enum DisappearingMessageType: Int, Codable, Hashable, DatabaseValueConvertible {
        case unknown
        case disappearAfterRead
        case disappearAfterSend
        
        public var localizedName: String {
            switch self {
                case .unknown:
                    return ""
                case .disappearAfterRead:
                    return "disappearingMessagesTypeRead".localized()
                case .disappearAfterSend:
                    return "disappearingMessagesTypeSent".localized()
            }
        }

        init(protoType: SNProtoContent.SNProtoContentExpirationType) {
            switch protoType {
                case .unknown:         self = .unknown
                case .deleteAfterRead: self = .disappearAfterRead
                case .deleteAfterSend: self = .disappearAfterSend
            }
        }
        
        init(libSessionType: CONVO_EXPIRATION_MODE) {
            switch libSessionType {
                case CONVO_EXPIRATION_AFTER_READ: self = .disappearAfterRead
                case CONVO_EXPIRATION_AFTER_SEND: self = .disappearAfterSend
                default:                          self = .unknown
            }
        }
        
        func toProto() -> SNProtoContent.SNProtoContentExpirationType {
            switch self {
                case .unknown:            return .unknown
                case .disappearAfterRead: return .deleteAfterRead
                case .disappearAfterSend: return .deleteAfterSend
            }
        }
        
        func toLibSession() -> CONVO_EXPIRATION_MODE {
            switch self {
                case .unknown:            return CONVO_EXPIRATION_NONE
                case .disappearAfterRead: return CONVO_EXPIRATION_AFTER_READ
                case .disappearAfterSend: return CONVO_EXPIRATION_AFTER_SEND
            }
        }
        
        public func localizedState(durationString: String) -> String {
            switch self {
                case .unknown:
                    return ""
                case .disappearAfterRead:
                    return "disappearingMessagesDisappearAfterReadState"
                        .put(key: "time", value: durationString)
                        .localized()
                case .disappearAfterSend:
                    return "disappearingMessagesDisappearAfterSendState"
                        .put(key: "time", value: durationString)
                        .localized()
            }
        }
    }
    
    public var id: String { threadId }  // Identifiable

    public let threadId: String
    public let isEnabled: Bool
    public let durationSeconds: TimeInterval
    public var type: DisappearingMessageType?
    
    // MARK: - Relationships
    
    public var thread: QueryInterfaceRequest<SessionThread> {
        request(for: DisappearingMessagesConfiguration.thread)
    }
}

// MARK: - Mutation

public extension DisappearingMessagesConfiguration {
    static func defaultWith(_ threadId: String) -> DisappearingMessagesConfiguration {
        return DisappearingMessagesConfiguration(
            threadId: threadId,
            isEnabled: false,
            durationSeconds: 0,
            type: .unknown
        )
    }
    
    func with(
        isEnabled: Bool? = nil,
        durationSeconds: TimeInterval? = nil,
        type: DisappearingMessageType? = nil
    ) -> DisappearingMessagesConfiguration {
        return DisappearingMessagesConfiguration(
            threadId: threadId,
            isEnabled: (isEnabled ?? self.isEnabled),
            durationSeconds: (durationSeconds ?? self.durationSeconds),
            type: (isEnabled == false) ? .unknown : (type ?? self.type)
        )
    }
    
    func forcedWithDisappearAfterReadIfNeeded() -> DisappearingMessagesConfiguration {
        if self.isEnabled {
            return self.with(type: .disappearAfterRead)
        }
        
        return self
    }
}

// MARK: - Convenience

public extension DisappearingMessagesConfiguration {
    struct MessageInfo: Codable {
        public let threadVariant: SessionThread.Variant?
        public let senderName: String?
        public let isEnabled: Bool
        public let durationSeconds: TimeInterval
        public let type: DisappearingMessageType?
        
        var previewText: String {
            guard let senderName: String = senderName else {
                guard isEnabled, durationSeconds > 0 else {
                    switch threadVariant {
                        case .legacyGroup, .group: return "disappearingMessagesTurnedOffYouGroup".localized()
                        default: return "disappearingMessagesTurnedOffYou".localized()
                    }
                }
                
                return "disappearingMessagesSetYou"
                    .put(key: "time", value: floor(durationSeconds).formatted(format: .long))
                    .put(key: "disappearing_messages_type", value: (type ?? .unknown).localizedName)
                    .localized()
            }
            
            guard isEnabled, durationSeconds > 0 else {
                switch threadVariant {
                    case .legacyGroup, .group:
                        return "disappearingMessagesTurnedOffGroup"
                            .put(key: "name", value: senderName)
                            .localized()
                    default:
                        return "disappearingMessagesTurnedOff"
                            .put(key: "name", value: senderName)
                            .localized()
                }
            }
            
            return "disappearingMessagesSet"
                .put(key: "name", value: senderName)
                .put(key: "time", value: floor(durationSeconds).formatted(format: .long))
                .put(key: "disappearing_messages_type", value: (type ?? .unknown).localizedName)
                .localized()
        }
    }
    
    var durationString: String {
        floor(durationSeconds).formatted(format: .long)
    }
    
    func messageInfoString(
        threadVariant: SessionThread.Variant?,
        senderName: String?,
        using dependencies: Dependencies
    ) -> String? {
        let messageInfo: MessageInfo = DisappearingMessagesConfiguration.MessageInfo(
            threadVariant: threadVariant,
            senderName: senderName,
            isEnabled: isEnabled,
            durationSeconds: durationSeconds,
            type: type
        )
        
        guard let messageInfoData: Data = try? JSONEncoder(using: dependencies).encode(messageInfo) else {
            return nil
        }
        
        return String(data: messageInfoData, encoding: .utf8)
    }
    
    func isValidV2Config() -> Bool {
        guard self.type != nil else { return (self.durationSeconds == 0) }
        
        return !(self.durationSeconds > 0 && self.type == .unknown)
    }
}

// MARK: - Control Message

public extension DisappearingMessagesConfiguration {
    func clearUnrelatedControlMessages(
        _ db: Database,
        threadVariant: SessionThread.Variant,
        using dependencies: Dependencies
    ) throws {
        guard threadVariant == .contact else {
            try Interaction
                .filter(Interaction.Columns.threadId == self.threadId)
                .filter(Interaction.Columns.variant == Interaction.Variant.infoDisappearingMessagesUpdate)
                .filter(Interaction.Columns.expiresInSeconds != self.durationSeconds)
                .deleteAll(db)
            return
        }
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        switch (self.isEnabled, self.type) {
            case (false, _):
                try Interaction
                    .filter(Interaction.Columns.threadId == self.threadId)
                    .filter(Interaction.Columns.variant == Interaction.Variant.infoDisappearingMessagesUpdate)
                    .filter(Interaction.Columns.authorId == userSessionId.hexString)
                    .filter(Interaction.Columns.expiresInSeconds != 0)
                    .deleteAll(db)
                
            case (true, .disappearAfterRead):
                try Interaction
                    .filter(Interaction.Columns.threadId == self.threadId)
                    .filter(Interaction.Columns.variant == Interaction.Variant.infoDisappearingMessagesUpdate)
                    .filter(Interaction.Columns.authorId == userSessionId.hexString)
                    .filter(!(Interaction.Columns.expiresInSeconds == self.durationSeconds && Interaction.Columns.expiresStartedAtMs != Interaction.Columns.timestampMs))
                    .deleteAll(db)
            
            case (true, .disappearAfterSend):
                try Interaction
                    .filter(Interaction.Columns.threadId == self.threadId)
                    .filter(Interaction.Columns.variant == Interaction.Variant.infoDisappearingMessagesUpdate)
                    .filter(Interaction.Columns.authorId == userSessionId.hexString)
                    .filter(!(Interaction.Columns.expiresInSeconds == self.durationSeconds && Interaction.Columns.expiresStartedAtMs == Interaction.Columns.timestampMs))
                    .deleteAll(db)
                
            default: break
        }
    }
    
    func insertControlMessage(
        _ db: Database,
        threadVariant: SessionThread.Variant,
        authorId: String,
        timestampMs: Int64,
        serverHash: String?,
        serverExpirationTimestamp: TimeInterval?,
        using dependencies: Dependencies
    ) throws -> Int64? {
        switch threadVariant {
            case .contact:
                _ = try Interaction
                    .filter(Interaction.Columns.threadId == threadId)
                    .filter(Interaction.Columns.variant == Interaction.Variant.infoDisappearingMessagesUpdate)
                    .filter(Interaction.Columns.authorId == authorId)
                    .deleteAll(db)
            case .legacyGroup, .group:
                _ = try Interaction
                    .filter(Interaction.Columns.threadId == threadId)
                    .filter(Interaction.Columns.variant == Interaction.Variant.infoDisappearingMessagesUpdate)
                    .deleteAll(db)
            case .community: break
        }
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let wasRead: Bool = (
            authorId == userSessionId.hexString ||
            dependencies.mutate(cache: .libSession) { cache in
                cache.timestampAlreadyRead(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    timestampMs: timestampMs,
                    userSessionId: userSessionId,
                    openGroup: nil
                )
            }
        )
        let messageExpirationInfo: Message.MessageExpirationInfo = Message.getMessageExpirationInfo(
            threadVariant: threadVariant,
            wasRead: wasRead,
            serverExpirationTimestamp: serverExpirationTimestamp,
            expiresInSeconds: self.durationSeconds,
            expiresStartedAtMs: (self.type == .disappearAfterSend) ? Double(timestampMs) : nil,
            using: dependencies
        )
        let interaction = try Interaction(
            serverHash: serverHash,
            threadId: threadId,
            threadVariant: threadVariant,
            authorId: authorId,
            variant: .infoDisappearingMessagesUpdate,
            body: self.messageInfoString(
                threadVariant: threadVariant,
                senderName: (authorId != userSessionId.hexString ?
                    Profile.displayName(db, id: authorId, using: dependencies) :
                    nil
                ),
                using: dependencies
            ),
            timestampMs: timestampMs,
            wasRead: wasRead,
            expiresInSeconds: (threadVariant == .legacyGroup ? nil : messageExpirationInfo.expiresInSeconds), // Do not expire this control message in legacy groups
            expiresStartedAtMs: (threadVariant == .legacyGroup ? nil : messageExpirationInfo.expiresStartedAtMs),
            using: dependencies
        ).inserted(db)
        
        if messageExpirationInfo.shouldUpdateExpiry {
            Message.updateExpiryForDisappearAfterReadMessages(
                db,
                threadId: threadId,
                threadVariant: threadVariant,
                serverHash: serverHash,
                expiresInSeconds: messageExpirationInfo.expiresInSeconds,
                expiresStartedAtMs: messageExpirationInfo.expiresStartedAtMs,
                using: dependencies
            )
        }
        
        return interaction.id
    }
}

// MARK: - UI Constraints

extension DisappearingMessagesConfiguration {
    public static func validDurationsSeconds(
        _ type: DisappearingMessageType,
        using dependencies: Dependencies
    ) -> [TimeInterval] {
        switch type {
            case .disappearAfterRead:
                return [
                    (dependencies[feature: .debugDisappearingMessageDurations] ? 10 : nil),
                    (dependencies[feature: .debugDisappearingMessageDurations] ? 30 : nil),
                    (dependencies[feature: .debugDisappearingMessageDurations] ? 60 : nil),
                    (5 * 60),
                    (1 * 60 * 60),
                    (12 * 60 * 60),
                    (24 * 60 * 60),
                    (7 * 24 * 60 * 60),
                    (2 * 7 * 24 * 60 * 60)
                ]
                .compactMap { duration in duration.map { TimeInterval($0) } }

            case .disappearAfterSend:
                return [
                    (dependencies[feature: .debugDisappearingMessageDurations] ? 10 : nil),
                    (dependencies[feature: .debugDisappearingMessageDurations] ? 30 : nil),
                    (dependencies[feature: .debugDisappearingMessageDurations] ? 60 : nil),
                    (12 * 60 * 60),
                    (24 * 60 * 60),
                    (7 * 24 * 60 * 60),
                    (2 * 7 * 24 * 60 * 60)
                ]
                .compactMap { duration in duration.map { TimeInterval($0) } }
                
            default: return []
        }
    }
}
