// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit.UIImage
import GRDB
import SessionUtilitiesKit

// MARK: - Current User Profile

public extension Profile {
    static func isTooLong(profileName: String) -> Bool {
        return (profileName.utf8CString.count > LibSession.sizeMaxNameBytes)
    }
    
    static func updateLocal(
        queue: DispatchQueue,
        profileName: String,
        displayPictureUpdate: DisplayPictureManager.Update = .none,
        success: ((Database) throws -> ())? = nil,
        failure: ((DisplayPictureError) -> ())? = nil,
        using dependencies: Dependencies
    ) {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let isRemovingAvatar: Bool = {
            switch displayPictureUpdate {
                case .remove: return true
                default: return false
            }
        }()
        
        switch displayPictureUpdate {
            case .none, .remove, .updateTo:
                dependencies[singleton: .storage].writeAsync { db in
                    if isRemovingAvatar {
                        let existingProfileUrl: String? = try Profile
                            .filter(id: userSessionId.hexString)
                            .select(.profilePictureUrl)
                            .asRequest(of: String.self)
                            .fetchOne(db)
                        let existingProfileFileName: String? = try Profile
                            .filter(id: userSessionId.hexString)
                            .select(.profilePictureFileName)
                            .asRequest(of: String.self)
                            .fetchOne(db)
                        
                        // Remove any cached avatar image value
                        if let fileName: String = existingProfileFileName {
                            dependencies.mutate(cache: .displayPicture) { $0.imageData[fileName] = nil }
                        }
                        
                        switch existingProfileUrl {
                            case .some: Log.verbose("Updating local profile on service with cleared avatar.")
                            case .none: Log.verbose("Updating local profile on service with no avatar.")
                        }
                    }
                    
                    try Profile.updateIfNeeded(
                        db,
                        publicKey: userSessionId.hexString,
                        name: profileName,
                        displayPictureUpdate: displayPictureUpdate,
                        sentTimestamp: dependencies.dateNow.timeIntervalSince1970,
                        calledFromConfig: nil,
                        using: dependencies
                    )
                    
                    Log.info("Successfully updated service with profile.")
                    try success?(db)
                }
                
            case .uploadImageData(let data):
                DisplayPictureManager.prepareAndUploadDisplayPicture(
                    queue: queue,
                    imageData: data,
                    success: { downloadUrl, fileName, newProfileKey in
                        dependencies[singleton: .storage].writeAsync { db in
                            try Profile.updateIfNeeded(
                                db,
                                publicKey: userSessionId.hexString,
                                name: profileName,
                                displayPictureUpdate: .updateTo(url: downloadUrl, key: newProfileKey, fileName: fileName),
                                sentTimestamp: dependencies.dateNow.timeIntervalSince1970,
                                calledFromConfig: nil,
                                using: dependencies
                            )
                            
                            dependencies[defaults: .standard, key: .lastProfilePictureUpload] = dependencies.dateNow
                            Log.info("Successfully updated service with profile.")
                            try success?(db)
                        }
                    },
                    failure: failure,
                    using: dependencies
                )
        }
    }    
    
    static func updateIfNeeded(
        _ db: Database,
        publicKey: String,
        name: String?,
        blocksCommunityMessageRequests: Bool? = nil,
        displayPictureUpdate: DisplayPictureManager.Update,
        sentTimestamp: TimeInterval,
        calledFromConfig configTriggeringChange: ConfigDump.Variant?,
        using dependencies: Dependencies
    ) throws {
        let isCurrentUser = (publicKey == dependencies[cache: .general].sessionId.hexString)
        let profile: Profile = Profile.fetchOrCreate(db, id: publicKey)
        var profileChanges: [ConfigColumnAssignment] = []
        
        // Name
        if let name: String = name, !name.isEmpty, name != profile.name {
            if sentTimestamp > (profile.lastNameUpdate ?? 0) || (isCurrentUser && configTriggeringChange == .userProfile) {
                profileChanges.append(Profile.Columns.name.set(to: name))
                profileChanges.append(Profile.Columns.lastNameUpdate.set(to: sentTimestamp))
            }
        }
        
        // Blocks community message requests flag
        if let blocksCommunityMessageRequests: Bool = blocksCommunityMessageRequests, sentTimestamp > (profile.lastBlocksCommunityMessageRequests ?? 0) {
            profileChanges.append(Profile.Columns.blocksCommunityMessageRequests.set(to: blocksCommunityMessageRequests))
            profileChanges.append(Profile.Columns.lastBlocksCommunityMessageRequests.set(to: sentTimestamp))
        }
        
        // Profile picture & profile key
        if sentTimestamp > (profile.lastProfilePictureUpdate ?? 0) || (isCurrentUser && configTriggeringChange == .userProfile) {
            switch displayPictureUpdate {
                case .none: break
                case .uploadImageData: preconditionFailure("Invalid options for this function")
                    
                case .remove:
                    profileChanges.append(Profile.Columns.profilePictureUrl.set(to: nil))
                    profileChanges.append(Profile.Columns.profileEncryptionKey.set(to: nil))
                    profileChanges.append(Profile.Columns.profilePictureFileName.set(to: nil))
                    profileChanges.append(Profile.Columns.lastProfilePictureUpdate.set(to: sentTimestamp))
                    
                case .updateTo(let url, let key, .some(let fileName)) where FileManager.default.fileExists(atPath: DisplayPictureManager.filepath(for: fileName, using: dependencies)):
                    // Update the 'lastProfilePictureUpdate' timestamp for either external or local changes
                    profileChanges.append(Profile.Columns.profilePictureFileName.set(to: fileName))
                    profileChanges.append(Profile.Columns.lastProfilePictureUpdate.set(to: sentTimestamp))
                    
                    if url != profile.profilePictureUrl {
                        profileChanges.append(Profile.Columns.profilePictureUrl.set(to: url))
                    }
                    
                    if key != profile.profileEncryptionKey && key.count == DisplayPictureManager.aes256KeyByteLength {
                        profileChanges.append(Profile.Columns.profileEncryptionKey.set(to: key))
                    }
                    
                case .updateTo(let url, let key, _):
                    dependencies[singleton: .jobRunner].add(
                        db,
                        job: Job(
                            variant: .displayPictureDownload,
                            shouldBeUnique: true,
                            details: DisplayPictureDownloadJob.Details(
                                target: .profile(id: profile.id, url: url, encryptionKey: key),
                                timestamp: sentTimestamp
                            )
                        ),
                        canStartJob: true
                    )
            }
        }
        
        // Persist any changes
        if !profileChanges.isEmpty {
            try profile.upsert(db)
            
            try Profile
                .filter(id: publicKey)
                .updateAllAndConfig(
                    db,
                    profileChanges,
                    calledFromConfig: configTriggeringChange,
                    using: dependencies
                )
        }
    }
}
