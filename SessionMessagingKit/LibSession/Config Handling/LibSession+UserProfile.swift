// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

internal extension LibSession {
    static let columnsRelatedToUserProfile: [Profile.Columns] = [
        Profile.Columns.name,
        Profile.Columns.profilePictureUrl,
        Profile.Columns.profileEncryptionKey
    ]
    
    static let syncedSettings: [String] = [
        Setting.BoolKey.checkForCommunityMessageRequests.rawValue
    ]
    
    // MARK: - Incoming Changes
    
    static func handleUserProfileUpdate(
        _ db: Database,
        in conf: UnsafeMutablePointer<config_object>?,
        mergeNeedsDump: Bool,
        latestConfigSentTimestampMs: Int64,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        typealias ProfileData = (profileName: String, profilePictureUrl: String?, profilePictureKey: Data?)
        
        guard mergeNeedsDump else { return }
        guard conf != nil else { throw LibSessionError.nilConfigObject }
        
        // A profile must have a name so if this is null then it's invalid and can be ignored
        guard let profileNamePtr: UnsafePointer<CChar> = user_profile_get_name(conf) else { return }
        
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let profileName: String = String(cString: profileNamePtr)
        let profilePic: user_profile_pic = user_profile_get_pic(conf)
        let profilePictureUrl: String? = profilePic.get(\.url, nullIfEmpty: true)
        
        // Handle user profile changes
        try ProfileManager.updateProfileIfNeeded(
            db,
            publicKey: userPublicKey,
            displayNameUpdate: .currentUserUpdate(profileName),
            displayPictureUpdate: {
                guard let profilePictureUrl: String = profilePictureUrl else { return .currentUserRemove }
                
                return .currentUserUpdateTo(
                    url: profilePictureUrl,
                    key: profilePic.get(\.key),
                    fileName: nil
                )
            }(),
            sentTimestamp: (TimeInterval(latestConfigSentTimestampMs) / 1000),
            calledFromConfigHandling: true,
            using: dependencies
        )
        
        // Update the 'Note to Self' visibility and priority
        let threadInfo: PriorityVisibilityInfo? = try? SessionThread
            .filter(id: userPublicKey)
            .select(.id, .variant, .pinnedPriority, .shouldBeVisible)
            .asRequest(of: PriorityVisibilityInfo.self)
            .fetchOne(db)
        let targetPriority: Int32 = user_profile_get_nts_priority(conf)
        
        // Create the 'Note to Self' thread if it doesn't exist
        if let threadInfo: PriorityVisibilityInfo = threadInfo {
            let threadChanges: [ConfigColumnAssignment] = [
                ((threadInfo.shouldBeVisible == LibSession.shouldBeVisible(priority: targetPriority)) ? nil :
                    SessionThread.Columns.shouldBeVisible.set(to: LibSession.shouldBeVisible(priority: targetPriority))
                ),
                (threadInfo.pinnedPriority == targetPriority ? nil :
                    SessionThread.Columns.pinnedPriority.set(to: targetPriority)
                )
            ].compactMap { $0 }
            
            if !threadChanges.isEmpty {
                try SessionThread
                    .filter(id: userPublicKey)
                    .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                        db,
                        threadChanges
                    )
            }
        }
        else {
            try SessionThread
                .fetchOrCreate(
                    db,
                    id: userPublicKey,
                    variant: .contact,
                    shouldBeVisible: LibSession.shouldBeVisible(priority: targetPriority)
                )
            
            try SessionThread
                .filter(id: userPublicKey)
                .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                    db,
                    SessionThread.Columns.pinnedPriority.set(to: targetPriority)
                )
            
            // If the 'Note to Self' conversation is hidden then we should trigger the proper
            // `deleteOrLeave` behaviour (for 'Note to Self' this will leave the conversation
            // but remove the associated interactions)
            if !LibSession.shouldBeVisible(priority: targetPriority) {
                try SessionThread.deleteOrLeave(
                    db,
                    type: .hideContactConversationAndDeleteContent,
                    threadId: userPublicKey,
                    calledFromConfigHandling: true
                )
            }
        }
        
        // Update the 'Note to Self' disappearing messages configuration
        let targetExpiry: Int32 = user_profile_get_nts_expiry(conf)
        let targetIsEnable: Bool = targetExpiry > 0
        let targetConfig: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration(
            threadId: userPublicKey,
            isEnabled: targetIsEnable,
            durationSeconds: TimeInterval(targetExpiry),
            type: targetIsEnable ? .disappearAfterSend : .unknown
        )
        let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
            .fetchOne(db, id: userPublicKey)
            .defaulting(to: DisappearingMessagesConfiguration.defaultWith(userPublicKey))
        
        if targetConfig != localConfig {
            try targetConfig
                .saved(db)
                .clearUnrelatedControlMessages(
                    db,
                    threadVariant: .contact
                )
        }

        // Update settings if needed
        let updatedAllowBlindedMessageRequests: Int32 = user_profile_get_blinded_msgreqs(conf)
        let updatedAllowBlindedMessageRequestsBoolValue: Bool = (updatedAllowBlindedMessageRequests >= 1)
        
        if
            updatedAllowBlindedMessageRequests >= 0 &&
            updatedAllowBlindedMessageRequestsBoolValue != db[.checkForCommunityMessageRequests]
        {
            db[.checkForCommunityMessageRequests] = updatedAllowBlindedMessageRequestsBoolValue
        }
        
        // Create a contact for the current user if needed (also force-approve the current user
        // in case the account got into a weird state or restored directly from a migration)
        let userContact: Contact = Contact.fetchOrCreate(db, id: userPublicKey)
        
        if !userContact.isTrusted || !userContact.isApproved || !userContact.didApproveMe {
            try userContact.save(db)
            try Contact
                .filter(id: userPublicKey)
                .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                    db,
                    Contact.Columns.isTrusted.set(to: true),    // Always trust the current user
                    Contact.Columns.isApproved.set(to: true),
                    Contact.Columns.didApproveMe.set(to: true)
                )
        }
    }
    
    // MARK: - Outgoing Changes
    
    static func update(
        profile: Profile,
        in conf: UnsafeMutablePointer<config_object>?
    ) throws {
        guard conf != nil else { throw LibSessionError.nilConfigObject }
        
        // Update the name
        var updatedName: [CChar] = try profile.name.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
        user_profile_set_name(conf, &updatedName)
        try LibSessionError.throwIfNeeded(conf)
        
        // Either assign the updated profile pic, or sent a blank profile pic (to remove the current one)
        var profilePic: user_profile_pic = user_profile_pic()
        profilePic.set(\.url, to: profile.profilePictureUrl)
        profilePic.set(\.key, to: profile.profileEncryptionKey)
        user_profile_set_pic(conf, profilePic)
        try LibSessionError.throwIfNeeded(conf)
    }
    
    static func updateNoteToSelf(
        priority: Int32? = nil,
        disappearingMessagesConfig: DisappearingMessagesConfiguration? = nil,
        in conf: UnsafeMutablePointer<config_object>?
    ) throws {
        guard conf != nil else { throw LibSessionError.nilConfigObject }
        
        if let priority: Int32 = priority {
            user_profile_set_nts_priority(conf, priority)
        }
        
        if let config: DisappearingMessagesConfiguration = disappearingMessagesConfig {
            user_profile_set_nts_expiry(conf, Int32(config.durationSeconds))
        }
    }
    
    static func updateSettings(
        checkForCommunityMessageRequests: Bool? = nil,
        in conf: UnsafeMutablePointer<config_object>?
    ) throws {
        guard conf != nil else { throw LibSessionError.nilConfigObject }
        
        if let blindedMessageRequests: Bool = checkForCommunityMessageRequests {
            user_profile_set_blinded_msgreqs(conf, (blindedMessageRequests ? 1 : 0))
        }
    }
}

// MARK: - Direct Values

extension LibSession {
    static func rawBlindedMessageRequestValue(in conf: UnsafeMutablePointer<config_object>?) throws -> Int32 {
        guard conf != nil else { throw LibSessionError.nilConfigObject }
    
        return user_profile_get_blinded_msgreqs(conf)
    }
}

// MARK: - C Conformance

extension user_profile_pic: CAccessible & CMutable {}
