// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

/// This migration goes through the current state of the database and generates config dumps for the user config types
enum _014_GenerateInitialUserConfigDumps: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "GenerateInitialUserConfigDumps" // stringlint:disable
    static let needsConfigSync: Bool = true
    static let minExpectedRunDuration: TimeInterval = 4.0
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = [
        Identity.self, SessionThread.self, Contact.self, Profile.self, ClosedGroup.self,
        OpenGroup.self, DisappearingMessagesConfiguration.self, GroupMember.self, ConfigDump.self
    ]
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = []
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        // If we have no ed25519 key then there is no need to create cached dump data
        guard let secretKey: [UInt8] = Identity.fetchUserEd25519KeyPair(db)?.secretKey else {
            Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
            return
        }
        
        // Create the initial config state
        let userPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
        let timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
        
        LibSession.loadState(db, userPublicKey: userPublicKey, ed25519SecretKey: secretKey, using: dependencies)
        
        // Retrieve all threads (we are going to base the config dump data on the active
        // threads rather than anything else in the database)
        let allThreads: [String: SessionThread] = try SessionThread
            .fetchAll(db)
            .reduce(into: [:]) { result, next in result[next.id] = next }
        
        // MARK: - UserProfile Config Dump
        
        try dependencies.caches[.libSession]
            .config(for: .userProfile, publicKey: userPublicKey)
            .mutate { conf in
                try LibSession.update(
                    profile: Profile.fetchOrCreateCurrentUser(db, using: dependencies),
                    in: conf
                )
                
                try LibSession.updateNoteToSelf(
                    priority: {
                        guard allThreads[userPublicKey]?.shouldBeVisible == true else { return LibSession.hiddenPriority }
                        
                        return Int32(allThreads[userPublicKey]?.pinnedPriority ?? 0)
                    }(),
                    in: conf
                )
                
                if config_needs_dump(conf) {
                    try LibSession
                        .createDump(
                            conf: conf,
                            for: .userProfile,
                            publicKey: userPublicKey,
                            timestampMs: timestampMs
                        )?
                        .save(db)
                }
            }
        
        // MARK: - Contact Config Dump
        
        try dependencies.caches[.libSession]
            .config(for: .contacts, publicKey: userPublicKey)
            .mutate { conf in
                // Exclude Note to Self, community, group and outgoing blinded message requests
                let validContactIds: [String] = allThreads
                    .values
                    .filter { thread in
                        thread.variant == .contact &&
                        thread.id != userPublicKey &&
                        (try? SessionId(from: thread.id))?.prefix == .standard
                    }
                    .map { $0.id }
                let contactsData: [ContactInfo] = try Contact
                    .filter(
                        Contact.Columns.isBlocked == true ||
                        validContactIds.contains(Contact.Columns.id)
                    )
                    .including(optional: Contact.profile)
                    .asRequest(of: ContactInfo.self)
                    .fetchAll(db)
                let threadIdsNeedingContacts: [String] = validContactIds
                    .filter { contactId in !contactsData.contains(where: { $0.contact.id == contactId }) }
                
                try LibSession.upsert(
                    contactData: contactsData
                        .appending(
                            contentsOf: threadIdsNeedingContacts
                                .map { contactId in
                                    ContactInfo(
                                        contact: Contact.fetchOrCreate(db, id: contactId),
                                        profile: nil
                                    )
                                }
                        )
                        .map { data in
                            LibSession.SyncedContactInfo(
                                id: data.contact.id,
                                contact: data.contact,
                                profile: data.profile,
                                priority: {
                                    guard allThreads[data.contact.id]?.shouldBeVisible == true else {
                                        return LibSession.hiddenPriority
                                    }
                                    
                                    return Int32(allThreads[data.contact.id]?.pinnedPriority ?? 0)
                                }(),
                                created: allThreads[data.contact.id]?.creationDateTimestamp
                            )
                        },
                    in: conf
                )
                
                if config_needs_dump(conf) {
                    try LibSession
                        .createDump(
                            conf: conf,
                            for: .contacts,
                            publicKey: userPublicKey,
                            timestampMs: timestampMs
                        )?
                        .save(db)
                }
            }
        
        // MARK: - ConvoInfoVolatile Config Dump
        
        try dependencies.caches[.libSession]
            .config(for: .convoInfoVolatile, publicKey: userPublicKey)
            .mutate { conf in
                let volatileThreadInfo: [LibSession.VolatileThreadInfo] = LibSession.VolatileThreadInfo
                    .fetchAll(db, ids: Array(allThreads.keys))
                
                try LibSession.upsert(
                    convoInfoVolatileChanges: volatileThreadInfo,
                    in: conf
                )
                
                if config_needs_dump(conf) {
                    try LibSession
                        .createDump(
                            conf: conf,
                            for: .convoInfoVolatile,
                            publicKey: userPublicKey,
                            timestampMs: timestampMs
                        )?
                        .save(db)
                }
            }
        
        // MARK: - UserGroups Config Dump
        
        try dependencies.caches[.libSession]
            .config(for: .userGroups, publicKey: userPublicKey)
            .mutate { conf in
                let legacyGroupData: [LibSession.LegacyGroupInfo] = try LibSession.LegacyGroupInfo.fetchAll(db)
                let communityData: [LibSession.OpenGroupUrlInfo] = try LibSession.OpenGroupUrlInfo
                    .fetchAll(db, ids: Array(allThreads.keys))
                
                try LibSession.upsert(
                    legacyGroups: legacyGroupData,
                    in: conf
                )
                try LibSession.upsert(
                    communities: communityData
                        .map { urlInfo in
                            LibSession.CommunityInfo(
                                urlInfo: urlInfo,
                                priority: Int32(allThreads[urlInfo.threadId]?.pinnedPriority ?? 0)
                            )
                        },
                    in: conf
                )
                
                if config_needs_dump(conf) {
                    try LibSession
                        .createDump(
                            conf: conf,
                            for: .userGroups,
                            publicKey: userPublicKey,
                            timestampMs: timestampMs
                        )?
                        .save(db)
                }
        }
                
        // MARK: - Threads
        
        try LibSession.updatingThreads(db, Array(allThreads.values))
        
        // MARK: - Syncing
        
        // Enqueue a config sync job to ensure the generated configs get synced
        db.afterNextTransactionNestedOnce(dedupeId: LibSession.syncDedupeId(userPublicKey)) { db in
            ConfigurationSyncJob.enqueue(db, publicKey: userPublicKey)
        }
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
    
    struct ContactInfo: FetchableRecord, Decodable, ColumnExpressible {
        typealias Columns = CodingKeys
        enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case contact
            case profile
        }
        
        let contact: Contact
        let profile: Profile?
    }
}
