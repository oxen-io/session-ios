// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - Size Restrictions

public extension LibSession {
    static var libSessionMaxNameByteLength: Int { CONTACT_MAX_NAME_LENGTH }
    static var libSessionMaxNicknameByteLength: Int { CONTACT_MAX_NAME_LENGTH }
    static var libSessionMaxProfileUrlByteLength: Int { PROFILE_PIC_MAX_URL_LENGTH }
}

// MARK: - Contacts Handling

internal extension LibSession {
    static let columnsRelatedToContacts: [ColumnExpression] = [
        Contact.Columns.isApproved,
        Contact.Columns.isBlocked,
        Contact.Columns.didApproveMe,
        Profile.Columns.name,
        Profile.Columns.nickname,
        Profile.Columns.profilePictureUrl,
        Profile.Columns.profileEncryptionKey,
        DisappearingMessagesConfiguration.Columns.isEnabled,
        DisappearingMessagesConfiguration.Columns.type,
        DisappearingMessagesConfiguration.Columns.durationSeconds
    ]
    
    // MARK: - Incoming Changes
    
    static func handleContactsUpdate(
        _ db: Database,
        in conf: UnsafeMutablePointer<config_object>?,
        mergeNeedsDump: Bool,
        latestConfigSentTimestampMs: Int64
    ) throws {
        guard mergeNeedsDump else { return }
        guard conf != nil else { throw LibSessionError.nilConfigObject }
        
        // The current users contact data is handled separately so exclude it if it's present (as that's
        // actually a bug)
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let targetContactData: [String: ContactData] = try extractContacts(
            from: conf,
            latestConfigSentTimestampMs: latestConfigSentTimestampMs
        ).filter { $0.key != userPublicKey }
        
        // Since we don't sync 100% of the data stored against the contact and profile objects we
        // need to only update the data we do have to ensure we don't overwrite anything that doesn't
        // get synced
        try targetContactData
            .forEach { sessionId, data in
                // Note: We only update the contact and profile records if the data has actually changed
                // in order to avoid triggering UI updates for every thread on the home screen (the DB
                // observation system can't differ between update calls which do and don't change anything)
                let contact: Contact = Contact.fetchOrCreate(db, id: sessionId)
                let profile: Profile = Profile.fetchOrCreate(db, id: sessionId)
                let profileNameShouldBeUpdated: Bool = (
                    !data.profile.name.isEmpty &&
                    profile.name != data.profile.name &&
                    (profile.lastNameUpdate ?? 0) < (data.profile.lastNameUpdate ?? 0)
                )
                let profilePictureShouldBeUpdated: Bool = (
                    (
                        profile.profilePictureUrl != data.profile.profilePictureUrl ||
                        profile.profileEncryptionKey != data.profile.profileEncryptionKey
                    ) &&
                    (profile.lastProfilePictureUpdate ?? 0) < (data.profile.lastProfilePictureUpdate ?? 0)
                )
                
                if
                    profileNameShouldBeUpdated ||
                    profile.nickname != data.profile.nickname ||
                    profilePictureShouldBeUpdated
                {
                    try profile.save(db)
                    try Profile
                        .filter(id: sessionId)
                        .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                            db,
                            [
                                (!profileNameShouldBeUpdated ? nil :
                                    Profile.Columns.name.set(to: data.profile.name)
                                ),
                                (!profileNameShouldBeUpdated ? nil :
                                    Profile.Columns.lastNameUpdate.set(to: data.profile.lastNameUpdate)
                                ),
                                (profile.nickname == data.profile.nickname ? nil :
                                    Profile.Columns.nickname.set(to: data.profile.nickname)
                                ),
                                (profile.profilePictureUrl != data.profile.profilePictureUrl ? nil :
                                    Profile.Columns.profilePictureUrl.set(to: data.profile.profilePictureUrl)
                                ),
                                (profile.profileEncryptionKey != data.profile.profileEncryptionKey ? nil :
                                    Profile.Columns.profileEncryptionKey.set(to: data.profile.profileEncryptionKey)
                                ),
                                (!profilePictureShouldBeUpdated ? nil :
                                    Profile.Columns.lastProfilePictureUpdate.set(to: data.profile.lastProfilePictureUpdate)
                                )
                            ].compactMap { $0 }
                        )
                }
                
                /// Since message requests have no reverse, we should only handle setting `isApproved`
                /// and `didApproveMe` to `true`. This may prevent some weird edge cases where a config message
                /// swapping `isApproved` and `didApproveMe` to `false`
                if
                    (contact.isApproved != data.contact.isApproved) ||
                    (contact.isBlocked != data.contact.isBlocked) ||
                    (contact.didApproveMe != data.contact.didApproveMe)
                {
                    try contact.save(db)
                    try Contact
                        .filter(id: sessionId)
                        .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                            db,
                            [
                                (!data.contact.isApproved || contact.isApproved == data.contact.isApproved ? nil :
                                    Contact.Columns.isApproved.set(to: true)
                                ),
                                (contact.isBlocked == data.contact.isBlocked ? nil :
                                    Contact.Columns.isBlocked.set(to: data.contact.isBlocked)
                                ),
                                (!data.contact.didApproveMe || contact.didApproveMe == data.contact.didApproveMe ? nil :
                                    Contact.Columns.didApproveMe.set(to: true)
                                )
                            ].compactMap { $0 }
                        )
                }
                
                /// If the contact's `hidden` flag doesn't match the visibility of their conversation then create/delete the
                /// associated contact conversation accordingly
                let threadInfo: PriorityVisibilityInfo? = try? SessionThread
                    .filter(id: sessionId)
                    .select(.id, .variant, .pinnedPriority, .shouldBeVisible)
                    .asRequest(of: PriorityVisibilityInfo.self)
                    .fetchOne(db)
                let threadExists: Bool = (threadInfo != nil)
                let updatedShouldBeVisible: Bool = LibSession.shouldBeVisible(priority: data.priority)

                /// If we are hiding the conversation then kick the user from it if it's currently open
                if !updatedShouldBeVisible {
                    LibSession.kickFromConversationUIIfNeeded(removedThreadIds: [sessionId])
                }
                
                /// Create the thread if it doesn't exist, otherwise just update it's state
                if !threadExists {
                    try SessionThread(
                        id: sessionId,
                        variant: .contact,
                        creationDateTimestamp: data.created,
                        shouldBeVisible: updatedShouldBeVisible,
                        pinnedPriority: data.priority
                    ).save(db)
                }
                else {
                    let changes: [ConfigColumnAssignment] = [
                        (threadInfo?.shouldBeVisible == updatedShouldBeVisible ? nil :
                            SessionThread.Columns.shouldBeVisible.set(to: updatedShouldBeVisible)
                        ),
                        (threadInfo?.pinnedPriority == data.priority ? nil :
                            SessionThread.Columns.pinnedPriority.set(to: data.priority)
                        )
                    ].compactMap { $0 }
                    
                    try SessionThread
                        .filter(id: sessionId)
                        .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                            db,
                            changes
                        )
                }
                
                // Update disappearing messages configuration if needed
                let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
                    .fetchOne(db, id: sessionId)
                    .defaulting(to: DisappearingMessagesConfiguration.defaultWith(sessionId))
                
                if data.config.isValidV2Config() && data.config != localConfig {
                    try data.config
                        .saved(db)
                        .clearUnrelatedControlMessages(
                            db,
                            threadVariant: .contact
                        )
                }
            }
        
        /// Delete any contact/thread records which aren't in the config message
        let syncedContactIds: [String] = targetContactData
            .map { $0.key }
            .appending(userPublicKey)
        let contactIdsToRemove: [String] = try Contact
            .filter(!syncedContactIds.contains(Contact.Columns.id))
            .select(.id)
            .asRequest(of: String.self)
            .fetchAll(db)
        let threadIdsToRemove: [String] = try SessionThread
            .filter(!syncedContactIds.contains(SessionThread.Columns.id))
            .filter(SessionThread.Columns.variant == SessionThread.Variant.contact)
            .filter(!SessionThread.Columns.id.like("\(SessionId.Prefix.blinded15.rawValue)%"))
            .filter(!SessionThread.Columns.id.like("\(SessionId.Prefix.blinded25.rawValue)%"))
            .select(.id)
            .asRequest(of: String.self)
            .fetchAll(db)
        
        /// When the user opens a brand new conversation this creates a "draft conversation" which has a hidden thread but no
        /// contact record, when we receive a contact update this "draft conversation" would be included in the
        /// `threadIdsToRemove` which would result in the user getting kicked from the screen and the thread removed, we
        /// want to avoid this (as it's essentially a bug) so find any conversations in this state and remove them from the list that
        /// will be pruned
        let threadT: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contactT: TypedTableAlias<Contact> = TypedTableAlias()
        let draftConversationIds: [String] = try SQLRequest<String>("""
            SELECT \(threadT[.id])
            FROM \(SessionThread.self)
            LEFT JOIN \(Contact.self) ON \(contactT[.id]) = \(threadT[.id])
            WHERE (
                \(SQL("\(threadT[.id]) IN \(threadIdsToRemove)")) AND
                \(contactT[.id]) IS NULL
            )
        """).fetchAll(db)
        
        /// Consolidate the ids which should be removed
        let combinedIds: [String] = contactIdsToRemove
            .appending(contentsOf: threadIdsToRemove)
            .filter { !draftConversationIds.contains($0) }
        
        if !combinedIds.isEmpty {
            LibSession.kickFromConversationUIIfNeeded(removedThreadIds: combinedIds)
            
            try Contact
                .filter(ids: combinedIds)
                .deleteAll(db)
            
            // Also need to remove any 'nickname' values since they are associated to contact data
            try Profile
                .filter(ids: combinedIds)
                .updateAll(
                    db,
                    Profile.Columns.nickname.set(to: nil)
                )
            
            // Delete the one-to-one conversations associated to the contact
            try SessionThread
                .deleteOrLeave(
                    db,
                    type: .deleteContactConversationAndContact,
                    threadIds: combinedIds,
                    calledFromConfigHandling: true
                )
            
            try LibSession.remove(db, volatileContactIds: combinedIds)
        }
    }
    
    // MARK: - Outgoing Changes
    
    static func upsert(
        contactData: [SyncedContactInfo],
        in conf: UnsafeMutablePointer<config_object>?
    ) throws {
        guard conf != nil else { throw LibSessionError.nilConfigObject }
        
        // The current users contact data doesn't need to sync so exclude it, we also don't want to sync
        // blinded message requests so exclude those as well
        let userPublicKey: String = getUserHexEncodedPublicKey()
        let targetContacts: [SyncedContactInfo] = contactData
            .filter {
                $0.id != userPublicKey &&
                (try? SessionId(from: $0.id))?.prefix == .standard
            }
        
        // If we only updated the current user contact then no need to continue
        guard !targetContacts.isEmpty else { return }        
        
        // Update the name
        try targetContacts
            .forEach { info in
                var contact: contacts_contact = contacts_contact()
                guard
                    var sessionId: [CChar] = info.id.cString(using: .utf8),
                    contacts_get_or_construct(conf, &contact, &sessionId)
                else {
                    /// It looks like there are some situations where this object might not get created correctly (and
                    /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
                    throw LibSessionError(
                        conf,
                        fallbackError: .getOrConstructFailedUnexpectedly,
                        logMessage: "Unable to upsert contact to LibSession"
                    )
                }
                
                // Assign all properties to match the updated contact (if there is one)
                if let updatedContact: Contact = info.contact {
                    contact.approved = updatedContact.isApproved
                    contact.approved_me = updatedContact.didApproveMe
                    contact.blocked = updatedContact.isBlocked
                    
                    // If we were given a `created` timestamp then set it to the min between the current
                    // setting and the value (as long as the current setting isn't `0`)
                    if let created: Int64 = info.created.map({ Int64(floor($0)) }) {
                        contact.created = (contact.created > 0 ? min(contact.created, created) : created)
                    }
                    
                    // Store the updated contact (needs to happen before variables go out of scope)
                    contacts_set(conf, &contact)
                    try LibSessionError.throwIfNeeded(conf)
                }
                
                // Update the profile data (if there is one - users we have sent a message request to may
                // not have profile info in certain situations)
                if let updatedProfile: Profile = info.profile {
                    let oldAvatarUrl: String? = contact.get(\.profile_pic.url)
                    let oldAvatarKey: Data? = contact.get(\.profile_pic.key)
                    
                    contact.set(\.name, to: updatedProfile.name)
                    contact.set(\.nickname, to: updatedProfile.nickname)
                    contact.set(\.profile_pic.url, to: updatedProfile.profilePictureUrl)
                    contact.set(\.profile_pic.key, to: updatedProfile.profileEncryptionKey)
                    
                    // Download the profile picture if needed (this can be triggered within
                    // database reads/writes so dispatch the download to a separate queue to
                    // prevent blocking)
                    //
                    // Note: Only trigger the avatar download if we are in the main app (don't
                    // want the extensions to trigger this as it can clog up their networking)
                    if
                        Singleton.hasAppContext &&
                        Singleton.appContext.isMainApp && (
                            oldAvatarUrl != (updatedProfile.profilePictureUrl ?? "") ||
                            oldAvatarKey != (updatedProfile.profileEncryptionKey ?? Data(repeating: 0, count: ProfileManager.avatarAES256KeyByteLength))
                        )
                    {
                        DispatchQueue.global(qos: .background).async {
                            ProfileManager.downloadAvatar(for: updatedProfile)
                        }
                    }
                    
                    // Store the updated contact (needs to happen before variables go out of scope)
                    contacts_set(conf, &contact)
                    try LibSessionError.throwIfNeeded(conf)
                }
                
                // Assign all properties to match the updated disappearing messages configuration (if there is one)
                if
                    let updatedConfig: DisappearingMessagesConfiguration = info.config,
                    let exp_mode: CONVO_EXPIRATION_MODE = updatedConfig.type?.toLibSession()
                {
                    contact.exp_mode = exp_mode
                    contact.exp_seconds = Int32(updatedConfig.durationSeconds)
                }
                
                // Store the updated contact (can't be sure if we made any changes above)
                contact.priority = (info.priority ?? contact.priority)
                contacts_set(conf, &contact)
                try LibSessionError.throwIfNeeded(conf)
            }
    }
}

// MARK: - Outgoing Changes

internal extension LibSession {
    static func updatingContacts<T>(_ db: Database, _ updated: [T]) throws -> [T] {
        guard let updatedContacts: [Contact] = updated as? [Contact] else { throw StorageError.generic }
        
        // The current users contact data doesn't need to sync so exclude it, we also don't want to sync
        // blinded message requests so exclude those as well
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let targetContacts: [Contact] = updatedContacts
            .filter {
                $0.id != userPublicKey &&
                (try? SessionId(from: $0.id))?.prefix == .standard
            }
        
        // If we only updated the current user contact then no need to continue
        guard !targetContacts.isEmpty else { return updated }
        
        try LibSession.performAndPushChange(
            db,
            for: .contacts,
            publicKey: userPublicKey
        ) { conf in
            // When inserting new contacts (or contacts with invalid profile data) we want
            // to add any valid profile information we have so identify if any of the updated
            // contacts are new/invalid, and if so, fetch any profile data we have for them
            let newContactIds: [String] = targetContacts
                .compactMap { contactData -> String? in
                    var contact: contacts_contact = contacts_contact()
                    
                    guard
                        var cContactId: [CChar] = contactData.id.cString(using: .utf8),
                        contacts_get(conf, &contact, &cContactId),
                        contact.get(\.name, nullIfEmpty: true) != nil
                    else {
                        LibSessionError.clear(conf)
                        return contactData.id
                    }
                    
                    return nil
                }
            let newProfiles: [String: Profile] = try Profile
                .fetchAll(db, ids: newContactIds)
                .reduce(into: [:]) { result, next in result[next.id] = next }
            
            // Upsert the updated contact data
            try LibSession
                .upsert(
                    contactData: targetContacts
                        .map { contact in
                            SyncedContactInfo(
                                id: contact.id,
                                contact: contact,
                                profile: newProfiles[contact.id]
                            )
                        },
                    in: conf
                )
        }
        
        return updated
    }
    
    static func updatingProfiles<T>(_ db: Database, _ updated: [T]) throws -> [T] {
        guard let updatedProfiles: [Profile] = updated as? [Profile] else { throw StorageError.generic }
        
        // We should only sync profiles which are associated to contact data to avoid including profiles
        // for random people in community conversations so filter out any profiles which don't have an
        // associated contact
        let existingContactIds: [String] = (try? Contact
            .filter(ids: updatedProfiles.map { $0.id })
            .select(.id)
            .asRequest(of: String.self)
            .fetchAll(db))
            .defaulting(to: [])
        
        // If none of the profiles are associated with existing contacts then ignore the changes (no need
        // to do a config sync)
        guard !existingContactIds.isEmpty else { return updated }
        
        // Get the user public key (updating their profile is handled separately)
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let targetProfiles: [Profile] = updatedProfiles
            .filter {
                $0.id != userPublicKey &&
                (try? SessionId(from: $0.id))?.prefix == .standard &&
                existingContactIds.contains($0.id)
            }
        
        // Update the user profile first (if needed)
        if let updatedUserProfile: Profile = updatedProfiles.first(where: { $0.id == userPublicKey }) {
            try LibSession.performAndPushChange(
                db,
                for: .userProfile,
                publicKey: userPublicKey
            ) { conf in
                try LibSession.update(
                    profile: updatedUserProfile,
                    in: conf
                )
            }
        }
        
        try LibSession.performAndPushChange(
            db,
            for: .contacts,
            publicKey: userPublicKey
        ) { conf in
            try LibSession
                .upsert(
                    contactData: targetProfiles
                        .map { SyncedContactInfo(id: $0.id, profile: $0) },
                    in: conf
                )
        }
        
        return updated
    }
    
    static func updatingDisappearingConfigs<T>(_ db: Database, _ updated: [T]) throws -> [T] {
        guard let updatedDisappearingConfigs: [DisappearingMessagesConfiguration] = updated as? [DisappearingMessagesConfiguration] else { throw StorageError.generic }
        
        // We should only sync disappearing messages configs which are associated to existing contacts
        let existingContactIds: [String] = (try? Contact
            .filter(ids: updatedDisappearingConfigs.map { $0.id })
            .select(.id)
            .asRequest(of: String.self)
            .fetchAll(db))
            .defaulting(to: [])
        
        // If none of the disappearing messages configs are associated with existing contacts then ignore
        // the changes (no need to do a config sync)
        guard !existingContactIds.isEmpty else { return updated }
        
        // Get the user public key (updating note to self is handled separately)
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let targetDisappearingConfigs: [DisappearingMessagesConfiguration] = updatedDisappearingConfigs
            .filter {
                $0.id != userPublicKey &&
                (try? SessionId(from: $0.id))?.prefix == .standard &&
                existingContactIds.contains($0.id)
            }
        
        // Update the note to self disappearing messages config first (if needed)
        if let updatedUserDisappearingConfig: DisappearingMessagesConfiguration = updatedDisappearingConfigs.first(where: { $0.id == userPublicKey }) {
            try LibSession.performAndPushChange(
                db,
                for: .userProfile,
                publicKey: userPublicKey
            ) { conf in
                try LibSession.updateNoteToSelf(
                    disappearingMessagesConfig: updatedUserDisappearingConfig,
                    in: conf
                )
            }
        }
        
        try LibSession.performAndPushChange(
            db,
            for: .contacts,
            publicKey: userPublicKey
        ) { conf in
            try LibSession
                .upsert(
                    contactData: targetDisappearingConfigs
                        .map { SyncedContactInfo(id: $0.id, disappearingMessagesConfig: $0) },
                    in: conf
                )
        }
        
        return updated
    }
}

// MARK: - External Outgoing Changes

public extension LibSession {
    static func hide(_ db: Database, contactIds: [String]) throws {
        try LibSession.performAndPushChange(
            db,
            for: .contacts,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            // Mark the contacts as hidden
            try LibSession.upsert(
                contactData: contactIds
                    .map {
                        SyncedContactInfo(
                            id: $0,
                            priority: LibSession.hiddenPriority
                        )
                    },
                in: conf
            )
        }
    }
    
    static func remove(_ db: Database, contactIds: [String]) throws {
        guard !contactIds.isEmpty else { return }
        
        try LibSession.performAndPushChange(
            db,
            for: .contacts,
            publicKey: getUserHexEncodedPublicKey(db)
        ) { conf in
            contactIds.forEach { sessionId in
                guard var cSessionId: [CChar] = sessionId.cString(using: .utf8) else { return }
                
                // Don't care if the contact doesn't exist
                contacts_erase(conf, &cSessionId)
            }
        }
    }
    
    static func update(
        _ db: Database,
        sessionId: String,
        disappearingMessagesConfig: DisappearingMessagesConfiguration
    ) throws {
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        switch sessionId {
            case userPublicKey:
                try LibSession.performAndPushChange(
                    db,
                    for: .userProfile,
                    publicKey: userPublicKey
                ) { conf in
                    try LibSession.updateNoteToSelf(
                        disappearingMessagesConfig: disappearingMessagesConfig,
                        in: conf
                    )
                }
                
            default:
                try LibSession.performAndPushChange(
                    db,
                    for: .contacts,
                    publicKey: userPublicKey
                ) { conf in
                    try LibSession
                        .upsert(
                            contactData: [
                                SyncedContactInfo(
                                    id: sessionId,
                                    disappearingMessagesConfig: disappearingMessagesConfig
                                )
                            ],
                            in: conf
                        )
                }
        }
    }
}

// MARK: - SyncedContactInfo

extension LibSession {
    struct SyncedContactInfo {
        let id: String
        let contact: Contact?
        let profile: Profile?
        let config: DisappearingMessagesConfiguration?
        let priority: Int32?
        let created: TimeInterval?
        
        init(
            id: String,
            contact: Contact? = nil,
            profile: Profile? = nil,
            disappearingMessagesConfig: DisappearingMessagesConfiguration? = nil,
            priority: Int32? = nil,
            created: TimeInterval? = nil
        ) {
            self.id = id
            self.contact = contact
            self.profile = profile
            self.config = disappearingMessagesConfig
            self.priority = priority
            self.created = created
        }
    }
}

// MARK: - ContactData

private struct ContactData {
    let contact: Contact
    let profile: Profile
    let config: DisappearingMessagesConfiguration
    let priority: Int32
    let created: TimeInterval
}

// MARK: - ThreadCount

private struct ThreadCount: Codable, FetchableRecord {
    let id: String
    let interactionCount: Int
}

// MARK: - Convenience

private extension LibSession {
    static func extractContacts(
        from conf: UnsafeMutablePointer<config_object>?,
        latestConfigSentTimestampMs: Int64
    ) throws -> [String: ContactData] {
        var infiniteLoopGuard: Int = 0
        var result: [String: ContactData] = [:]
        var contact: contacts_contact = contacts_contact()
        let contactIterator: UnsafeMutablePointer<contacts_iterator> = contacts_iterator_new(conf)
        
        while !contacts_iterator_done(contactIterator, &contact) {
            try LibSession.checkLoopLimitReached(&infiniteLoopGuard, for: .contacts)
            
            let contactId: String = contact.get(\.session_id)
            let contactResult: Contact = Contact(
                id: contactId,
                isApproved: contact.approved,
                isBlocked: contact.blocked,
                didApproveMe: contact.approved_me
            )
            let profilePictureUrl: String? = contact.get(\.profile_pic.url, nullIfEmpty: true)
            let profileResult: Profile = Profile(
                id: contactId,
                name: contact.get(\.name),
                lastNameUpdate: (TimeInterval(latestConfigSentTimestampMs) / 1000),
                nickname: contact.get(\.nickname, nullIfEmpty: true),
                profilePictureUrl: profilePictureUrl,
                profileEncryptionKey: (profilePictureUrl == nil ? nil : contact.get(\.profile_pic.key)),
                lastProfilePictureUpdate: (TimeInterval(latestConfigSentTimestampMs) / 1000)
            )
            let configResult: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration(
                threadId: contactId,
                isEnabled: contact.exp_seconds > 0,
                durationSeconds: TimeInterval(contact.exp_seconds),
                type: DisappearingMessagesConfiguration.DisappearingMessageType(libSessionType: contact.exp_mode)
            )
            
            result[contactId] = ContactData(
                contact: contactResult,
                profile: profileResult,
                config: configResult,
                priority: contact.priority,
                created: TimeInterval(contact.created)
            )
            contacts_iterator_advance(contactIterator)
        }
        contacts_iterator_free(contactIterator) // Need to free the iterator
        
        return result
    }
}

// MARK: - C Conformance

extension contacts_contact: CAccessible & CMutable {}
