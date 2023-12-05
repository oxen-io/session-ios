// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
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
        case lastChangeTimestampMs
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

        init(protoType: SNProtoContent.SNProtoContentExpirationType) {
            switch protoType {
                case .unknown:         self = .unknown
                case .deleteAfterRead: self = .disappearAfterRead
                case .deleteAfterSend: self = .disappearAfterSend
            }
        }
        
        init(sessionUtilType: CONVO_EXPIRATION_MODE) {
            switch sessionUtilType {
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
    }
    
    public var id: String { threadId }  // Identifiable

    public let threadId: String
    public let isEnabled: Bool
    public let durationSeconds: TimeInterval
    public var type: DisappearingMessageType?
    public let lastChangeTimestampMs: Int64?
    
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
            type: .unknown,
            lastChangeTimestampMs: 0
        )
    }
    
    func with(
        isEnabled: Bool? = nil,
        durationSeconds: TimeInterval? = nil,
        type: DisappearingMessageType? = nil,
        lastChangeTimestampMs: Int64? = nil
    ) -> DisappearingMessagesConfiguration {
        return DisappearingMessagesConfiguration(
            threadId: threadId,
            isEnabled: (isEnabled ?? self.isEnabled),
            durationSeconds: (durationSeconds ?? self.durationSeconds),
            type: (isEnabled == false) ? .unknown : (type ?? self.type),
            lastChangeTimestampMs: (lastChangeTimestampMs ?? self.lastChangeTimestampMs)
        )
    }
}

// MARK: - Convenience

public extension DisappearingMessagesConfiguration {
    struct MessageInfo: Codable {
        public let senderName: String?
        public let isEnabled: Bool
        public let durationSeconds: TimeInterval
        public let type: DisappearingMessageType?
        public let isPreviousOff: Bool?
        
        var previewText: String {
            guard Features.useNewDisappearingMessagesConfig else { return legacyPreviewText }
            guard let senderName: String = senderName else {
                guard isEnabled, durationSeconds > 0 else {
                    return "YOU_DISAPPEARING_MESSAGES_INFO_DISABLE".localized()
                }
                
                return String(
                    format: "YOU_DISAPPEARING_MESSAGES_INFO_ENABLE".localized(),
                    floor(durationSeconds).formatted(format: .long),
                    (type == .disappearAfterRead ? "DISAPPEARING_MESSAGE_STATE_READ".localized() : "DISAPPEARING_MESSAGE_STATE_SENT".localized())
                )
            }
            
            guard isEnabled, durationSeconds > 0 else {
                return String(format: "DISAPPERING_MESSAGES_INFO_DISABLE".localized(), senderName)
            }
            
            return String(
                format: "DISAPPERING_MESSAGES_INFO_ENABLE".localized(),
                senderName,
                floor(durationSeconds).formatted(format: .long),
                (type == .disappearAfterRead ? "DISAPPEARING_MESSAGE_STATE_READ".localized() : "DISAPPEARING_MESSAGE_STATE_SENT".localized())
            )
        }
        
        var previewTextLegacyGroup: String {
            guard Features.useNewDisappearingMessagesConfig else { return legacyPreviewText }
            
            guard let senderName: String = senderName else {
                // Changed by this device or via synced transcript
                guard isEnabled, durationSeconds > 0 else {
                    return "YOU_DISAPPEARING_MESSAGES_INFO_DISABLE_LEGACY".localized()
                }
                
                guard isPreviousOff == true else {
                    return String(
                        format: "YOU_DISAPPEARING_MESSAGES_INFO_UPDATE_LEGACY".localized(),
                        floor(durationSeconds).formatted(format: .long),
                        (type == .disappearAfterRead ? "DISAPPEARING_MESSAGE_STATE_READ".localized() : "DISAPPEARING_MESSAGE_STATE_SENT".localized())
                    )
                }
                
                return String(
                    format: "YOU_DISAPPEARING_MESSAGES_INFO_ENABLE_LEGACY".localized(),
                    floor(durationSeconds).formatted(format: .long),
                    (type == .disappearAfterRead ? "DISAPPEARING_MESSAGE_STATE_READ".localized() : "DISAPPEARING_MESSAGE_STATE_SENT".localized())
                )
            }
            
            guard isEnabled, durationSeconds > 0 else {
                return String(format: "DISAPPERING_MESSAGES_INFO_DISABLE_LEGACY".localized(), senderName)
            }
            
            guard isPreviousOff == true else {
                return String(
                    format: "DISAPPERING_MESSAGES_INFO_UPDATE_LEGACY".localized(),
                    senderName,
                    floor(durationSeconds).formatted(format: .long),
                    (type == .disappearAfterRead ? "DISAPPEARING_MESSAGE_STATE_READ".localized() : "DISAPPEARING_MESSAGE_STATE_SENT".localized())
                )
            }
            
            return String(
                format: "DISAPPERING_MESSAGES_INFO_ENABLE_LEGACY".localized(),
                senderName,
                floor(durationSeconds).formatted(format: .long),
                (type == .disappearAfterRead ? "DISAPPEARING_MESSAGE_STATE_READ".localized() : "DISAPPEARING_MESSAGE_STATE_SENT".localized())
            )
        }
        
        private var legacyPreviewText: String {
            guard let senderName: String = senderName else {
                // Changed by this device or via synced transcript
                guard isEnabled, durationSeconds > 0 else { return "YOU_DISABLED_DISAPPEARING_MESSAGES_CONFIGURATION".localized() }
                
                return String(
                    format: "YOU_UPDATED_DISAPPEARING_MESSAGES_CONFIGURATION".localized(),
                    floor(durationSeconds).formatted(format: .long)
                )
            }
            
            guard isEnabled, durationSeconds > 0 else {
                return String(format: "OTHER_DISABLED_DISAPPEARING_MESSAGES_CONFIGURATION".localized(), senderName)
            }
            
            return String(
                format: "OTHER_UPDATED_DISAPPEARING_MESSAGES_CONFIGURATION".localized(),
                senderName,
                floor(durationSeconds).formatted(format: .long)
            )
        }
    }
    
    var durationString: String {
        floor(durationSeconds).formatted(format: .long)
    }
    
    func messageInfoString(with senderName: String?, isPreviousOff: Bool) -> String? {
        let messageInfo: MessageInfo = DisappearingMessagesConfiguration.MessageInfo(
            senderName: senderName,
            isEnabled: isEnabled,
            durationSeconds: durationSeconds,
            type: type,
            isPreviousOff: isPreviousOff
        )
        
        guard let messageInfoData: Data = try? JSONEncoder().encode(messageInfo) else { return nil }
        
        return String(data: messageInfoData, encoding: .utf8)
    }
}

// MARK: - UI Constraints

extension DisappearingMessagesConfiguration {
    // TODO: Remove this when disappearing messages V2 is up and running
    public static var validDurationsSeconds: [TimeInterval] {
        return [
            5,
            10,
            30,
            (1 * 60),
            (5 * 60),
            (30 * 60),
            (1 * 60 * 60),
            (6 * 60 * 60),
            (12 * 60 * 60),
            (24 * 60 * 60),
            (7 * 24 * 60 * 60)
        ]
    }
    
    public static var maxDurationSeconds: TimeInterval = {
        return (validDurationsSeconds.max() ?? 0)
    }()
    
    public static func validDurationsSeconds(_ type: DisappearingMessageType) -> [TimeInterval] {
        
        switch type {
            case .disappearAfterRead:
                var result =  [
                    (5 * 60),
                    (1 * 60 * 60),
                    (12 * 60 * 60),
                    (24 * 60 * 60),
                    (7 * 24 * 60 * 60),
                    (2 * 7 * 24 * 60 * 60)
                ]
                .map { TimeInterval($0)  }
                #if targetEnvironment(simulator)
                    result.insert(
                        TimeInterval(60),
                        at: 0
                    )
                    result.insert(
                        TimeInterval(10),
                        at: 0
                    )
                #endif
                return result
            case .disappearAfterSend:
                var result =  [
                    (12 * 60 * 60),
                    (24 * 60 * 60),
                    (7 * 24 * 60 * 60),
                    (2 * 7 * 24 * 60 * 60)
                ]
                .map { TimeInterval($0)  }
                #if targetEnvironment(simulator)
                    result.insert(
                        TimeInterval(10),
                        at: 0
                    )
                #endif
                return result
            default:
                return []
            }
    }
}
