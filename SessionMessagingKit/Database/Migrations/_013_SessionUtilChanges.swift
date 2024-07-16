// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import CryptoKit
import GRDB
import SessionUtil
import SessionUtilitiesKit

/// This migration makes the neccessary changes to support the updated user config syncing system
enum _013_SessionUtilChanges: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "SessionUtilChanges"
    static let needsConfigSync: Bool = true
    static let minExpectedRunDuration: TimeInterval = 0.4
    static var requirements: [MigrationRequirement] = [.sessionIdCached]
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = [
        Identity.self, GroupMember.self, ClosedGroupKeyPair.self, SessionThread.self
    ]
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = [
        SessionThread.self, Profile.self, GroupMember.self, ClosedGroupKeyPair.self, ConfigDump.self
    ]
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        // Add `markedAsUnread` to the thread table
        try db.alter(table: SessionThread.self) { t in
            t.add(.markedAsUnread, .boolean)
            t.add(.pinnedPriority, .integer)
        }
        
        // Add `lastNameUpdate` and `lastProfilePictureUpdate` columns to the profile table
        try db.alter(table: Profile.self) { t in
            t.add(.lastNameUpdate, .integer).defaults(to: 0)
            t.add(.lastProfilePictureUpdate, .integer).defaults(to: 0)
        }
        
        // SQLite doesn't support adding a new primary key after creation so we need to create a new table with
        // the setup we want, copy data from the old table over, drop the old table and rename the new table
        struct TmpGroupMember: Codable, TableRecord, FetchableRecord, PersistableRecord, ColumnExpressible {
            static var databaseTableName: String { "tmpGroupMember" }
            
            public typealias Columns = CodingKeys
            public enum CodingKeys: String, CodingKey, ColumnExpression {
                case groupId
                case profileId
                case role
                case isHidden
            }

            public let groupId: String
            public let profileId: String
            public let role: GroupMember.Role
            public let isHidden: Bool
        }
        
        try db.create(table: TmpGroupMember.self) { t in
            // Note: Since we don't know whether this will be stored against a 'ClosedGroup' or
            // an 'OpenGroup' we add the foreign key constraint against the thread itself (which
            // shares the same 'id' as the 'groupId') so we can cascade delete automatically
            t.column(.groupId, .text)
                .notNull()
                .references(SessionThread.self, onDelete: .cascade)   // Delete if Thread deleted
            t.column(.profileId, .text)
                .notNull()
            t.column(.role, .integer).notNull()
            t.column(.isHidden, .boolean)
                .notNull()
                .defaults(to: false)
            
            t.primaryKey([.groupId, .profileId, .role])
        }
        
        // Retrieve the non-duplicate group member entries from the old table
        let nonDuplicateGroupMembers: [TmpGroupMember] = try GroupMember
            .select(.groupId, .profileId, .role, .isHidden)
            .group(GroupMember.Columns.groupId, GroupMember.Columns.profileId, GroupMember.Columns.role)
            .asRequest(of: TmpGroupMember.self)
            .fetchAll(db)
        
        // Insert into the new table, drop the old table and rename the new table to be the old one
        try nonDuplicateGroupMembers.forEach { try $0.upsert(db) }
        try db.drop(table: GroupMember.self)
        try db.rename(table: TmpGroupMember.databaseTableName, to: GroupMember.databaseTableName)
        
        // Need to create the indexes separately from creating 'TmpGroupMember' to ensure they
        // have the correct names
        try db.createIndex(on: GroupMember.self, columns: [.groupId])
        try db.createIndex(on: GroupMember.self, columns: [.profileId])
        
        // SQLite doesn't support removing unique constraints so we need to create a new table with
        // the setup we want, copy data from the old table over, drop the old table and rename the new table
        struct TmpClosedGroupKeyPair: Codable, TableRecord, FetchableRecord, PersistableRecord, ColumnExpressible {
            static var databaseTableName: String { "tmpClosedGroupKeyPair" }
            
            public typealias Columns = CodingKeys
            public enum CodingKeys: String, CodingKey, ColumnExpression {
                case threadId
                case publicKey
                case secretKey
                case receivedTimestamp
                case threadKeyPairHash
            }
            
            public let threadId: String
            public let publicKey: Data
            public let secretKey: Data
            public let receivedTimestamp: TimeInterval
            public let threadKeyPairHash: String
        }
        
        try db.alter(table: ClosedGroupKeyPair.self) { t in
            t.add(.threadKeyPairHash, .text).defaults(to: "")
        }
        try db.create(table: TmpClosedGroupKeyPair.self) { t in
            t.column(.threadId, .text)
                .notNull()
                .references(ClosedGroup.self, onDelete: .cascade)     // Delete if ClosedGroup deleted
            t.column(.publicKey, .blob).notNull()
            t.column(.secretKey, .blob).notNull()
            t.column(.receivedTimestamp, .double)
                .notNull()
            t.column(.threadKeyPairHash, .integer)
                .notNull()
                .unique()
        }
        
        // Insert into the new table, drop the old table and rename the new table to be the old one
        try ClosedGroupKeyPair
            .fetchAll(db)
            .map { keyPair in
                ClosedGroupKeyPair(
                    threadId: keyPair.threadId,
                    publicKey: keyPair.publicKey,
                    secretKey: keyPair.secretKey,
                    receivedTimestamp: keyPair.receivedTimestamp
                )
            }
            .map { keyPair in
                TmpClosedGroupKeyPair(
                    threadId: keyPair.threadId,
                    publicKey: keyPair.publicKey,
                    secretKey: keyPair.secretKey,
                    receivedTimestamp: keyPair.receivedTimestamp,
                    threadKeyPairHash: keyPair.threadKeyPairHash
                )
            }
            .forEach { try? $0.insert(db) } // Ignore duplicate values
        try db.drop(table: ClosedGroupKeyPair.self)
        try db.rename(table: TmpClosedGroupKeyPair.databaseTableName, to: ClosedGroupKeyPair.databaseTableName)
        
        // Add an index for the 'ClosedGroupKeyPair' so we can lookup existing keys more easily
        //
        // Note: Need to create the indexes separately from creating 'TmpClosedGroupKeyPair' to ensure they
        // have the correct names
        try db.createIndex(on: ClosedGroupKeyPair.self, columns: [.threadId])
        try db.createIndex(on: ClosedGroupKeyPair.self, columns: [.receivedTimestamp])
        try db.createIndex(on: ClosedGroupKeyPair.self, columns: [.threadKeyPairHash])
        try db.createIndex(
            on: ClosedGroupKeyPair.self,
            columns: [.threadId, .threadKeyPairHash]
        )
        
        // Add an index for the 'Quote' table to speed up queries
        try db.createIndex(
            on: Quote.self,
            columns: [.timestampMs]
        )
        
        // New table for storing the latest config dump for each type
        try db.create(table: ConfigDump.self) { t in
            t.column(.variant, .text)
                .notNull()
            t.column(.publicKey, .text)
                .notNull()
                .indexed()
            t.column(.data, .blob)
                .notNull()
            t.column(.timestampMs, .integer)
                .notNull()
                .defaults(to: 0)
            
            t.primaryKey([.variant, .publicKey])
        }
        
        // Migrate the 'isPinned' value to 'pinnedPriority'
        try SessionThread
            .filter(sql: "isPinned = true")
            .updateAll(
                db,
                SessionThread.Columns.pinnedPriority.set(to: 1)
            )
        
        // If we don't have an ed25519 key then no need to create cached dump data
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        /// Remove any hidden threads to avoid syncing them (they are basically shadow threads created by starting a conversation
        /// but not sending a message so can just be cleared out)
        ///
        /// **Note:** Our settings defer foreign key checks to the end of the migration, unfortunately the `PRAGMA foreign_keys`
        /// setting is also a no-on during transactions so we can't enable it for the delete action, as a result we need to manually clean
        /// up any data associated with the threads we want to delete, at the time of this migration the following tables should cascade
        /// delete when a thread is deleted:
        /// - DisappearingMessagesConfiguration
        /// - ClosedGroup
        /// - GroupMember
        /// - Interaction
        /// - ThreadTypingIndicator
        /// - PendingReadReceipt
        let threadIdsToDelete: [String] = try SessionThread
            .filter(
                SessionThread.Columns.shouldBeVisible == false &&
                SessionThread.Columns.id != userSessionId.hexString
            )
            .select(.id)
            .asRequest(of: String.self)
            .fetchAll(db)
        try SessionThread
            .deleteAll(db, ids: threadIdsToDelete)
        try DisappearingMessagesConfiguration
            .filter(threadIdsToDelete.contains(DisappearingMessagesConfiguration.Columns.threadId))
            .deleteAll(db)
        try ClosedGroup
            .filter(threadIdsToDelete.contains(ClosedGroup.Columns.threadId))
            .deleteAll(db)
        try GroupMember
            .filter(threadIdsToDelete.contains(GroupMember.Columns.groupId))
            .deleteAll(db)
        try Interaction
            .filter(threadIdsToDelete.contains(Interaction.Columns.threadId))
            .deleteAll(db)
        try ThreadTypingIndicator
            .filter(threadIdsToDelete.contains(ThreadTypingIndicator.Columns.threadId))
            .deleteAll(db)
        try PendingReadReceipt
            .filter(threadIdsToDelete.contains(PendingReadReceipt.Columns.threadId))
            .deleteAll(db)
        
        /// There was previously a bug which allowed users to fully delete the 'Note to Self' conversation but we don't want that, so
        /// create it again if it doesn't exists
        ///
        /// **Note:** Since migrations are run when running tests creating a random SessionThread will result in unexpected thread
        /// counts so don't do this when running tests (this logic is the same as in `MainAppContext.isRunningTests`
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            if (try SessionThread.exists(db, id: userSessionId.hexString)) == false {
                try SessionThread.fetchOrCreate(
                    db,
                    id: userSessionId.hexString,
                    variant: .contact,
                    shouldBeVisible: false,
                    calledFromConfig: nil,
                    using: dependencies
                )
            }
        }
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}
