// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

/// This migration goes through the current state of the database and generates config dumps for the user config types
enum _014_GenerateInitialUserConfigDumps: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "GenerateInitialUserConfigDumps"
    static let needsConfigSync: Bool = true
    static let minExpectedRunDuration: TimeInterval = 4.0
    static var requirements: [MigrationRequirement] = [.sessionIdCached]
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = [
        Identity.self, SessionThread.self, Contact.self, Profile.self, ClosedGroup.self,
        OpenGroup.self, DisappearingMessagesConfiguration.self, GroupMember.self, ConfigDump.self
    ]
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = []
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        // If we have no ed25519 key then there is no need to create cached dump data
        guard Identity.fetchUserEd25519KeyPair(db) != nil else {
            Storage.update(progress: 1, for: self, in: target, using: dependencies)
            return
        }
        
        // Create the initial config state        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let timestampMs: Int64 = Int64(dependencies.dateNow.timeIntervalSince1970 * TimeInterval(1000))
        let cache: LibSession.Cache = LibSession.Cache(userSessionId: userSessionId, using: dependencies)
        
        // Setup the initial state
        cache.loadState(db)
        
        // Retrieve all threads (we are going to base the config dump data on the active
        // threads rather than anything else in the database)
        let allThreads: [String: SessionThread] = try SessionThread
            .fetchAll(db)
            .reduce(into: [:]) { result, next in result[next.id] = next }
        
        // MARK: - UserProfile Config Dump
        
        let userProfileConfig: LibSession.Config? = cache.config(for: .userProfile, sessionId: userSessionId)
        
        try LibSession.update(
            profile: Profile.fetchOrCreateCurrentUser(db, using: dependencies),
            in: userProfileConfig
        )
        
        try LibSession.updateNoteToSelf(
            priority: {
                guard allThreads[userSessionId.hexString]?.shouldBeVisible == true else { return LibSession.hiddenPriority }
                
                return Int32(allThreads[userSessionId.hexString]?.pinnedPriority ?? 0)
            }(),
            in: userProfileConfig
        )
        
        if cache.configNeedsDump(userProfileConfig) {
            try cache.createDump(
                config: userProfileConfig,
                for: .userProfile,
                sessionId: userSessionId,
                timestampMs: timestampMs
            )?.upsert(db)
        }
        
        // MARK: - Contact Config Dump
        
        // Exclude Note to Self, community, group and outgoing blinded message requests
        let contactsConfig: LibSession.Config? = cache.config(for: .contacts, sessionId: userSessionId)
        let validContactIds: [String] = allThreads
            .values
            .filter { thread in
                thread.variant == .contact &&
                thread.id != userSessionId.hexString &&
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
                                contact: Contact.fetchOrCreate(db, id: contactId, using: dependencies),
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
            in: contactsConfig,
            using: dependencies
        )
        
        if cache.configNeedsDump(contactsConfig) {
            try cache.createDump(
                config: contactsConfig,
                for: .contacts,
                sessionId: userSessionId,
                timestampMs: timestampMs
            )?.upsert(db)
        }
        
        // MARK: - ConvoInfoVolatile Config Dump
        
        let convoInfoVolatileConfig: LibSession.Config? = cache.config(for: .convoInfoVolatile, sessionId: userSessionId)
        let volatileThreadInfo: [LibSession.VolatileThreadInfo] = LibSession.VolatileThreadInfo
            .fetchAll(db, ids: Array(allThreads.keys))
        
        try LibSession.upsert(
            convoInfoVolatileChanges: volatileThreadInfo,
            in: convoInfoVolatileConfig
        )
        
        if cache.configNeedsDump(convoInfoVolatileConfig) {
            try cache.createDump(
                config: convoInfoVolatileConfig,
                for: .convoInfoVolatile,
                sessionId: userSessionId,
                timestampMs: timestampMs
            )?.upsert(db)
        }
        
        // MARK: - UserGroups Config Dump
        
        let userGroupsConfig: LibSession.Config? = cache.config(for: .userGroups, sessionId: userSessionId)
        let legacyGroupData: [LibSession.LegacyGroupInfo] = try LibSession.LegacyGroupInfo.fetchAll(db)
        let communityData: [LibSession.OpenGroupUrlInfo] = try LibSession.OpenGroupUrlInfo
            .fetchAll(db, ids: Array(allThreads.keys))
        
        try LibSession.upsert(
            legacyGroups: legacyGroupData,
            in: userGroupsConfig
        )
        try LibSession.upsert(
            communities: communityData.map { urlInfo in
                LibSession.CommunityInfo(
                    urlInfo: urlInfo,
                    priority: Int32(allThreads[urlInfo.threadId]?.pinnedPriority ?? 0)
                )
            },
            in: userGroupsConfig
        )
        
        if cache.configNeedsDump(userGroupsConfig) {
            try cache.createDump(
                config: userGroupsConfig,
                for: .userGroups,
                sessionId: userSessionId,
                timestampMs: timestampMs
            )?.upsert(db)
        }
        
        // MARK: - Store cache in dependencies
        
        dependencies.set(cache: .libSession, to: cache)
                
        // MARK: - Threads
        
        // This needs to happen after we have stored the cache in dependencies
        try LibSession.updatingThreads(db, Array(allThreads.values), using: dependencies)
        
        // MARK: - Syncing
        
        // Enqueue a config sync job to ensure the generated configs get synced
        db.afterNextTransactionNestedOnce(dedupeId: LibSession.syncDedupeId(userSessionId.hexString), using: dependencies) { db in
            ConfigurationSyncJob.enqueue(db, swarmPublicKey: userSessionId.hexString, using: dependencies)
        }
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
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
