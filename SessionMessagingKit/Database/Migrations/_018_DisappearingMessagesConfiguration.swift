// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _018_DisappearingMessagesConfiguration: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "DisappearingMessagesWithTypes" // stringlint:disable
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var requirements: [MigrationRequirement] = [.libSessionStateLoaded]
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = [
        Identity.self, DisappearingMessagesConfiguration.self
    ]
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = [
        DisappearingMessagesConfiguration.self, Contact.self
    ]
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        try db.alter(table: DisappearingMessagesConfiguration.self) { t in
            t.add(.type, .integer)
            t.add(.lastChangeTimestampMs, .integer)
                .defaults(to: 0)
        }
        
        try db.alter(table: Contact.self) { t in
            t.add(.lastKnownClientVersion, .integer)
        }
        
        /// Add index on interaction table for wasRead and variant
        /// 
        /// This is due to new disappearing messages will need some info messages to be able to be unread,
        /// but we only want to count the unread message number by incoming visible messages and call messages.
        try db.createIndex(
            on: Interaction.self,
            columns: [.wasRead, .variant]
        )
        
        // If there isn't already a user account then we can just finish here (there will be no
        // threads/configs to update and the configs won't be setup which would cause this to crash
        guard Identity.userExists(db) else {
            return Storage.update(progress: 1, for: self, in: target, using: dependencies)
        }
        
        // Convenience function to set the disappearing messages type per conversation
        func updateDisappearingMessageType(_ db: GRDB.Database, id: String, type: DisappearingMessagesConfiguration.DisappearingMessageType) throws {
            _ = try DisappearingMessagesConfiguration
                .filter(DisappearingMessagesConfiguration.Columns.threadId == id)
                .updateAll(
                    db,
                    DisappearingMessagesConfiguration.Columns.type.set(to: type)
                )
        }
        
        // Process any existing disappearing message settings
        var contactUpdate: [DisappearingMessagesConfiguration] = []
        var legacyGroupUpdate: [DisappearingMessagesConfiguration] = []
        
        try DisappearingMessagesConfiguration
            .filter(DisappearingMessagesConfiguration.Columns.isEnabled == true)
            .fetchAll(db)
            .forEach { config in
                guard let thread: SessionThread = try? SessionThread.fetchOne(db, id: config.threadId) else { return }
                guard !thread.isNoteToSelf(db) else {
                    try updateDisappearingMessageType(db, id: config.threadId, type: .disappearAfterSend)
                    return
                }
                
                switch thread.variant {
                    case .contact:
                        try updateDisappearingMessageType(db, id: config.threadId, type: .disappearAfterRead)
                        contactUpdate.append(config.with(type: .disappearAfterRead))
                        
                    case .legacyGroup, .group:
                        try updateDisappearingMessageType(db, id: config.threadId, type: .disappearAfterSend)
                        legacyGroupUpdate.append(config.with(type: .disappearAfterSend))
                        
                    case .community: return
                }
            }
        
        // Update the configs so the settings are synced
        _ = try LibSession.updatingDisappearingConfigsOneToOne(db, contactUpdate, using: dependencies)
        _ = try LibSession.batchUpdate(db, disappearingConfigs: legacyGroupUpdate, using: dependencies)
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}

