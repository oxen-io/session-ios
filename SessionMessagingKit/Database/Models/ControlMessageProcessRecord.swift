// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

/// We can rely on the unique constraints within the `Interaction` table to prevent duplicate `VisibleMessage`
/// values from being processed, but some control messages don’t have an associated interaction - this table provides
/// a de-duping mechanism for those messages
///
/// **Note:** It’s entirely possible for there to be a false-positive with this record where multiple users sent the same
/// type of control message at the same time - this is very unlikely to occur though since unique to the millisecond level
public struct ControlMessageProcessRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "controlMessageProcessRecord" }
    
    /// For notifications and migrated timestamps default to '15' days (which is the timeout for messages on the
    /// server at the time of writing)
    public static let defaultExpirationSeconds: TimeInterval = (15 * 24 * 60 * 60)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case threadId
        case timestampMs
        case variant
        case serverExpirationTimestamp
    }
    
    public enum Variant: Int, Codable, DatabaseValueConvertible {
        @available(*, deprecated, message: "Removed along with legacy db migration") case legacyEntry = 0
        
        case readReceipt = 1
        case typingIndicator = 2
        case legacyGroupControlMessage = 3
        case dataExtractionNotification = 4
        case expirationTimerUpdate = 5
        @available(*, deprecated) case configurationMessage = 6
        case unsendRequest = 7
        case messageRequestResponse = 8
        case call = 9
        
        /// Since we retrieve messages from all snodes in a swarm there is a fun issue where a user can delete a
        /// one-to-one conversation (which removes all associated interactions) and then the poller checks a
        /// different service node, if a previously processed message hadn't been processed yet for that specific
        /// service node it results in the conversation re-appearing
        ///
        /// This `Variant` allows us to create a record which survives thread deletion to prevent a duplicate
        /// message from being reprocessed
        case visibleMessageDedupe = 10
        
        case groupUpdateInvite = 11
        case groupUpdatePromote = 12
        case groupUpdateInfoChange = 13
        case groupUpdateMemberChange = 14
        case groupUpdateMemberLeft = 15
        case groupUpdateMemberLeftNotification = 16
        case groupUpdateInviteResponse = 17
        case groupUpdateDeleteMemberContent = 18
        
        internal static let variantsToBeReprocessedAfterLeavingAndRejoiningConversation: Set<Variant> = [
            .legacyGroupControlMessage, .dataExtractionNotification, .expirationTimerUpdate, .unsendRequest,
            .messageRequestResponse, .call, .visibleMessageDedupe, .groupUpdateInfoChange, .groupUpdateMemberChange,
            .groupUpdateMemberLeftNotification, .groupUpdateDeleteMemberContent
        ]
    }
    
    /// The id for the thread the control message is associated to
    ///
    /// **Note:** For user-specific control message (eg. `ConfigurationMessage`) this value will be the
    /// users public key
    public let threadId: String
    
    /// The type of control message
    ///
    /// **Note:** It would be nice to include this in the unique constraint to reduce the likelihood of false positives
    /// but this can result in control messages getting re-handled because the variant is unknown in the migration
    public let variant: Variant
    
    /// The timestamp of the control message
    public let timestampMs: Int64
    
    /// The timestamp for when this message will expire on the server (will be used for garbage collection)
    public let serverExpirationTimestamp: TimeInterval?
    
    // MARK: - Initialization
    
    public init?(
        threadId: String,
        message: Message,
        serverExpirationTimestamp: TimeInterval?
    ) {
        // Allow duplicates for UnsendRequest messages, if a user received an UnsendRequest
        // as a push notification the it wouldn't include a serverHash and, as a result,
        // wouldn't get deleted from the server - since the logic only runs if we find a
        // matching message the safest option is to allow duplicate handling to avoid an
        // edge-case where a message doesn't get deleted
        if message is UnsendRequest { return nil }
        
        // Allow duplicates for all call messages, the double checking will be done on
        // message handling to make sure the messages are for the same ongoing call
        if message is CallMessage { return nil }
        
        // Allow '.new' and 'encryptionKeyPair' closed group control message duplicates to avoid
        // the following situation:
        // • The app performed a background poll or received a push notification
        // • This method was invoked and the received message timestamps table was updated
        // • Processing wasn't finished
        // • The user doesn't see the new closed group
        if case .new = (message as? ClosedGroupControlMessage)?.kind { return nil }
        if case .encryptionKeyPair = (message as? ClosedGroupControlMessage)?.kind { return nil }
        
        // The `LibSessionMessage` doesn't have enough metadata to be able to dedupe via
        // the `ControlMessageProcessRecord` so just always process it
        if message is LibSessionMessage { return nil }
        
        /// For all other cases we want to prevent duplicate handling of the message (this can happen in a number of situations, primarily
        /// with sync messages though hence why we don't include the 'serverHash' as part of this record
        ///
        /// **Note:** We should make sure to have a unique `variant` for any message type which could have the same timestamp
        /// as another message type as otherwise they might incorrectly be deduped
        self.threadId = threadId
        self.variant = {
            switch message {
                case is ReadReceipt: return .readReceipt
                case is TypingIndicator: return .typingIndicator
                case is ClosedGroupControlMessage: return .legacyGroupControlMessage
                case is DataExtractionNotification: return .dataExtractionNotification
                case is ExpirationTimerUpdate: return .expirationTimerUpdate
                case is UnsendRequest: return .unsendRequest
                case is MessageRequestResponse: return .messageRequestResponse
                case is CallMessage: return .call
                case is VisibleMessage: return .visibleMessageDedupe
                    
                case is GroupUpdateInviteMessage: return .groupUpdateInvite
                case is GroupUpdatePromoteMessage: return .groupUpdatePromote
                case is GroupUpdateInfoChangeMessage: return .groupUpdateInfoChange
                case is GroupUpdateMemberChangeMessage: return .groupUpdateMemberChange
                case is GroupUpdateMemberLeftMessage: return .groupUpdateMemberLeft
                case is GroupUpdateMemberLeftNotificationMessage: return .groupUpdateMemberLeftNotification
                case is GroupUpdateInviteResponseMessage: return .groupUpdateInviteResponse
                case is GroupUpdateDeleteMemberContentMessage: return .groupUpdateDeleteMemberContent
                    
                default: preconditionFailure("[ControlMessageProcessRecord] Unsupported message type")
            }
        }()
        self.timestampMs = Int64(message.sentTimestampMs ?? 0)   // Default to `0` if not set
        self.serverExpirationTimestamp = serverExpirationTimestamp
    }
}

// MARK: - Migration Extensions

internal extension ControlMessageProcessRecord {
    init?(
        threadId: String,
        variant: Interaction.Variant,
        timestampMs: Int64,
        using dependencies: Dependencies
    ) {
        switch variant {
            case .standardOutgoing, .standardIncoming, .standardIncomingDeleted, .standardIncomingDeletedLocally,
                .standardOutgoingDeleted, .standardOutgoingDeletedLocally, .infoLegacyGroupCreated:
                return nil
                
            case .infoLegacyGroupUpdated, .infoLegacyGroupCurrentUserLeft: self.variant = .legacyGroupControlMessage
            case .infoDisappearingMessagesUpdate: self.variant = .expirationTimerUpdate
            case .infoScreenshotNotification, .infoMediaSavedNotification: self.variant = .dataExtractionNotification
            case .infoMessageRequestAccepted: self.variant = .messageRequestResponse
            case .infoCall: self.variant = .call
            case .infoGroupInfoUpdated: self.variant = .groupUpdateInfoChange
            case .infoGroupInfoInvited, .infoGroupMembersUpdated: self.variant = .groupUpdateMemberChange
                
            case .infoGroupCurrentUserLeaving, .infoGroupCurrentUserErrorLeaving:
                // If the `threadId` is for an updated group then it's a `groupControlMessage`, otherwise
                // assume it's a `legacyGroupControlMessage`
                self.variant = ((try? SessionId(from: threadId))?.prefix == .group ?
                    .groupUpdateMemberLeft :
                    .legacyGroupControlMessage
                )
        }
        
        self.threadId = threadId
        self.timestampMs = timestampMs
        self.serverExpirationTimestamp = (
            TimeInterval(dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000) +
            ControlMessageProcessRecord.defaultExpirationSeconds
        )
    }
    
    /// This method should only be called from either the `generateLegacyProcessRecords` method above or
    /// within the 'insert' method to maintain the unique constraint
    fileprivate init(
        threadId: String,
        variant: Variant,
        timestampMs: Int64,
        serverExpirationTimestamp: TimeInterval
    ) {
        self.threadId = threadId
        self.variant = variant
        self.timestampMs = timestampMs
        self.serverExpirationTimestamp = serverExpirationTimestamp
    }
}
