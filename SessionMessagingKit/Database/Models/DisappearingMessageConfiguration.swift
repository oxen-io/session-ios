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
        
        func attributedPreviewText(using dependencies: Dependencies) -> NSAttributedString {
            guard dependencies[feature: .updatedDisappearingMessages] else {
                return NSAttributedString(string: legacyPreviewText)
            }
            
            guard let senderName: String = senderName else {
                // Changed by this device or via synced transcript
                guard isEnabled, durationSeconds > 0 else {
                    return NSAttributedString(string: "YOU_DISAPPEARING_MESSAGES_INFO_DISABLE".localized())
                }
                
                guard isPreviousOff == true else {
                    return NSAttributedString(
                        string: String(
                            format: "YOU_DISAPPEARING_MESSAGES_INFO_UPDATE".localized(),
                            floor(durationSeconds).formatted(format: .long),
                            (type == .disappearAfterRead ? "DISAPPEARING_MESSAGE_STATE_READ".localized() : "DISAPPEARING_MESSAGE_STATE_SENT".localized())
                        )
                    )
                }
                
                return NSAttributedString(
                    string: String(
                        format: "YOU_DISAPPEARING_MESSAGES_INFO_ENABLE".localized(),
                        floor(durationSeconds).formatted(format: .long),
                        (type == .disappearAfterRead ? "DISAPPEARING_MESSAGE_STATE_READ".localized() : "DISAPPEARING_MESSAGE_STATE_SENT".localized())
                    )
                )
            }
            
            guard isEnabled, durationSeconds > 0 else {
                return NSAttributedString(
                    format: "DISAPPERING_MESSAGES_INFO_DISABLE".localized(),
                    .font(senderName, .boldSystemFont(ofSize: Values.verySmallFontSize))
                )
            }
            
            guard isPreviousOff == true else {
                return NSAttributedString(
                    format: "DISAPPERING_MESSAGES_INFO_UPDATE".localized(),
                    .font(senderName, .boldSystemFont(ofSize: Values.verySmallFontSize)),
                    .font(
                        floor(durationSeconds).formatted(format: .long),
                        .boldSystemFont(ofSize: Values.verySmallFontSize)
                    ),
                    .font(
                        (type == .disappearAfterRead ?
                            "DISAPPEARING_MESSAGE_STATE_READ".localized() :
                            "DISAPPEARING_MESSAGE_STATE_SENT".localized()
                        ),
                        .boldSystemFont(ofSize: Values.verySmallFontSize)
                    )
                )
            }
            
            return NSAttributedString(
                format: "DISAPPERING_MESSAGES_INFO_ENABLE".localized(),
                .font(senderName, .boldSystemFont(ofSize: Values.verySmallFontSize)),
                .font(
                    floor(durationSeconds).formatted(format: .long),
                    .boldSystemFont(ofSize: Values.verySmallFontSize)
                ),
                .font(
                    (type == .disappearAfterRead ?
                        "DISAPPEARING_MESSAGE_STATE_READ".localized() :
                        "DISAPPEARING_MESSAGE_STATE_SENT".localized()
                    ),
                    .boldSystemFont(ofSize: Values.verySmallFontSize)
                )
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
    
    func messageInfoString(with senderName: String?, isPreviousOff: Bool, using dependencies: Dependencies) -> String? {
        let messageInfo: MessageInfo = DisappearingMessagesConfiguration.MessageInfo(
            senderName: senderName,
            isEnabled: isEnabled,
            durationSeconds: durationSeconds,
            type: type,
            isPreviousOff: isPreviousOff
        )
        
        guard let messageInfoData: Data = try? JSONEncoder(using: dependencies).encode(messageInfo) else {
            return nil
        }
        
        return String(data: messageInfoData, encoding: .utf8)
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
