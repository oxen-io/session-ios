// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - LibSession

internal extension LibSession {
    static let columnsRelatedToUserProfile: [Profile.Columns] = [
        Profile.Columns.name,
        Profile.Columns.profilePictureUrl,
        Profile.Columns.profileEncryptionKey
    ]
    
    static let syncedSettings: [String] = [
        Setting.BoolKey.checkForCommunityMessageRequests.rawValue
    ]
}

// MARK: - LibSessionCacheType

public extension LibSessionCacheType {
    var userProfileDisplayName: String {
        guard
            case .object(let conf) = config(for: .userProfile, sessionId: userSessionId),
            let profileNamePtr: UnsafePointer<CChar> = user_profile_get_name(conf)
        else { return "" }
        
        return String(cString: profileNamePtr)
    }
}

// MARK: - Incoming Changes

internal extension LibSessionCacheType {
    func handleUserProfileUpdate(
        _ db: Database,
        in config: LibSession.Config?,
        serverTimestampMs: Int64
    ) throws {
        guard configNeedsDump(config) else { return }
        guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
        
        // A profile must have a name so if this is null then it's invalid and can be ignored
        guard let profileNamePtr: UnsafePointer<CChar> = user_profile_get_name(conf) else { return }
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let profileName: String = String(cString: profileNamePtr)
        let profilePic: user_profile_pic = user_profile_get_pic(conf)
        let profilePictureUrl: String? = profilePic.get(\.url, nullIfEmpty: true)
        
        // Handle user profile changes
        try Profile.updateIfNeeded(
            db,
            publicKey: userSessionId.hexString,
            displayNameUpdate: .currentUserUpdate(profileName),
            displayPictureUpdate: {
                guard let profilePictureUrl: String = profilePictureUrl else { return .currentUserRemove }
                
                return .currentUserUpdateTo(
                    url: profilePictureUrl,
                    key: profilePic.get(\.key),
                    fileName: nil
                )
            }(),
            sentTimestamp: TimeInterval(Double(serverTimestampMs) / 1000),
            calledFromConfig: .userProfile,
            using: dependencies
        )
        
        // Update the 'Note to Self' visibility and priority
        let threadInfo: LibSession.PriorityVisibilityInfo? = try? SessionThread
            .filter(id: userSessionId.hexString)
            .select(.id, .variant, .pinnedPriority, .shouldBeVisible)
            .asRequest(of: LibSession.PriorityVisibilityInfo.self)
            .fetchOne(db)
        let targetPriority: Int32 = user_profile_get_nts_priority(conf)
        
        // Create the 'Note to Self' thread if it doesn't exist
        if let threadInfo: LibSession.PriorityVisibilityInfo = threadInfo {
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
                    .filter(id: userSessionId.hexString)
                    .updateAllAndConfig(
                        db,
                        threadChanges,
                        calledFromConfig: .userProfile,
                        using: dependencies
                    )
            }
        }
        else {
            try SessionThread
                .fetchOrCreate(
                    db,
                    id: userSessionId.hexString,
                    variant: .contact,
                    creationDateTimestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000),
                    shouldBeVisible: LibSession.shouldBeVisible(priority: targetPriority),
                    calledFromConfig: .userProfile,
                    using: dependencies
                )
            
            try SessionThread
                .filter(id: userSessionId.hexString)
                .updateAllAndConfig(
                    db,
                    SessionThread.Columns.pinnedPriority.set(to: targetPriority),
                    calledFromConfig: .userProfile,
                    using: dependencies
                )
            
            // If the 'Note to Self' conversation is hidden then we should trigger the proper
            // `deleteOrLeave` behaviour (for 'Note to Self' this will leave the conversation
            // but remove the associated interactions)
            if !LibSession.shouldBeVisible(priority: targetPriority) {
                try SessionThread.deleteOrLeave(
                    db,
                    type: .hideContactConversationAndDeleteContent,
                    threadId: userSessionId.hexString,
                    threadVariant: .contact,
                    calledFromConfig: .userProfile,
                    using: dependencies
                )
            }
        }
        
        // Update the 'Note to Self' disappearing messages configuration
        let targetExpiry: Int32 = user_profile_get_nts_expiry(conf)
        let targetIsEnable: Bool = targetExpiry > 0
        let targetConfig: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration(
            threadId: userSessionId.hexString,
            isEnabled: targetIsEnable,
            durationSeconds: TimeInterval(targetExpiry),
            type: targetIsEnable ? .disappearAfterSend : .unknown
        )
        let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
            .fetchOne(db, id: userSessionId.hexString)
            .defaulting(to: DisappearingMessagesConfiguration.defaultWith(userSessionId.hexString))
        
        if targetConfig != localConfig {
            try targetConfig
                .saved(db)
                .clearUnrelatedControlMessages(
                    db,
                    threadVariant: .contact,
                    using: dependencies
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
        let userContact: Contact = Contact.fetchOrCreate(db, id: userSessionId.hexString, using: dependencies)
        
        if !userContact.isTrusted || !userContact.isApproved || !userContact.didApproveMe {
            try userContact.upsert(db)
            try Contact
                .filter(id: userSessionId.hexString)
                .updateAllAndConfig(
                    db,
                    Contact.Columns.isTrusted.set(to: true),    // Always trust the current user
                    Contact.Columns.isApproved.set(to: true),
                    Contact.Columns.didApproveMe.set(to: true),
                    calledFromConfig: .userProfile,
                    using: dependencies
                )
        }
    }
}

// MARK: - Outgoing Changes

internal extension LibSession {
    static func update(
        profile: Profile,
        in config: Config?
    ) throws {
        guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
        
        // Update the name
        var cUpdatedName: [CChar] = try profile.name.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
        user_profile_set_name(conf, &cUpdatedName)
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
        in config: Config?
    ) throws {
        guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
        
        if let priority: Int32 = priority {
            user_profile_set_nts_priority(conf, priority)
        }
        
        if let config: DisappearingMessagesConfiguration = disappearingMessagesConfig {
            user_profile_set_nts_expiry(conf, Int32(config.durationSeconds))
        }
    }
    
    static func updateSettings(
        checkForCommunityMessageRequests: Bool? = nil,
        in config: Config?
    ) throws {
        guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
        
        if let blindedMessageRequests: Bool = checkForCommunityMessageRequests {
            user_profile_set_blinded_msgreqs(conf, (blindedMessageRequests ? 1 : 0))
        }
    }
}

// MARK: - Direct Values

extension LibSession {
    static func rawBlindedMessageRequestValue(in config: Config?) throws -> Int32 {
        guard case .object(let conf) = config else { throw LibSessionError.invalidConfigObject }
    
        return user_profile_get_blinded_msgreqs(conf)
    }
}

// MARK: - C Conformance

extension user_profile_pic: CAccessible & CMutable {}
