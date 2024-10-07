// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit.UIImage
import GRDB
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let profile: Log.Category = .create("Profile", defaultLevel: .info)
}

// MARK: - Profile Updates

public extension Profile {
    enum DisplayNameUpdate {
        case none
        case contactUpdate(String?)
        case currentUserUpdate(String?)
    }
    
    static func isTooLong(profileName: String) -> Bool {
        /// String.utf8CString will include the null terminator (Int8)0 as the end of string buffer.
        /// When the string is exactly 100 bytes String.utf8CString.count will be 101.
        /// However in LibSession, the Contact C API supports 101 characters in order to account for
        /// the null terminator - char name[101]. So it is OK to use String.utf8.count
        return (profileName.utf8CString.count > LibSession.sizeMaxNameBytes)
    }
    
    static func updateLocal(
        queue: DispatchQueue,
        displayNameUpdate: DisplayNameUpdate = .none,
        displayPictureUpdate: DisplayPictureManager.Update = .none,
        success: ((Database) throws -> ())? = nil,
        failure: ((DisplayPictureError) -> ())? = nil,
        using dependencies: Dependencies
    ) {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let isRemovingAvatar: Bool = {
            switch displayPictureUpdate {
                case .currentUserRemove: return true
                default: return false
            }
        }()
        
        switch displayPictureUpdate {
            case .contactRemove, .contactUpdateTo, .groupRemove, .groupUpdateTo, .groupUploadImageData:
                failure?(DisplayPictureError.invalidCall)
            
            case .none, .currentUserRemove, .currentUserUpdateTo:
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
                            case .some: Log.verbose(.profile, "Updating local profile on service with cleared avatar.")
                            case .none: Log.verbose(.profile, "Updating local profile on service with no avatar.")
                        }
                    }
                    
                    try Profile.updateIfNeeded(
                        db,
                        publicKey: userSessionId.hexString,
                        displayNameUpdate: displayNameUpdate,
                        displayPictureUpdate: displayPictureUpdate,
                        sentTimestamp: dependencies.dateNow.timeIntervalSince1970,
                        calledFromConfig: nil,
                        using: dependencies
                    )
                    
                    Log.info(.profile, "Successfully updated user profile.")
                    try success?(db)
                }
                
            case .currentUserUploadImageData(let data):
                DisplayPictureManager.prepareAndUploadDisplayPicture(
                    queue: queue,
                    imageData: data,
                    success: { downloadUrl, fileName, newProfileKey in
                        dependencies[singleton: .storage].writeAsync { db in
                            try Profile.updateIfNeeded(
                                db,
                                publicKey: userSessionId.hexString,
                                displayNameUpdate: displayNameUpdate,
                                displayPictureUpdate: .currentUserUpdateTo(
                                    url: downloadUrl,
                                    key: newProfileKey,
                                    fileName: fileName
                                ),
                                sentTimestamp: dependencies.dateNow.timeIntervalSince1970,
                                calledFromConfig: nil,
                                using: dependencies
                            )
                            
                            dependencies[defaults: .standard, key: .lastProfilePictureUpload] = dependencies.dateNow
                            Log.info(.profile, "Successfully updated user profile.")
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
        displayNameUpdate: DisplayNameUpdate = .none,
        displayPictureUpdate: DisplayPictureManager.Update,
        blocksCommunityMessageRequests: Bool? = nil,
        sentTimestamp: TimeInterval,
        calledFromConfig configTriggeringChange: ConfigDump.Variant?,
        using dependencies: Dependencies
    ) throws {
        let isCurrentUser = (publicKey == dependencies[cache: .general].sessionId.hexString)
        let profile: Profile = Profile.fetchOrCreate(db, id: publicKey)
        var profileChanges: [ConfigColumnAssignment] = []
        
        // Name
        // FIXME: This 'lastNameUpdate' approach is buggy - we should have a timestamp on the ConvoInfoVolatile
        switch (displayNameUpdate, isCurrentUser, (sentTimestamp > (profile.lastNameUpdate ?? 0))) {
            case (.none, _, _): break
            case (.currentUserUpdate(let name), true, _), (.contactUpdate(let name), false, true):
                guard let name: String = name, !name.isEmpty, name != profile.name else { break }
                
                profileChanges.append(Profile.Columns.name.set(to: name))
                profileChanges.append(Profile.Columns.lastNameUpdate.set(to: sentTimestamp))
            
            // Don't want profiles in messages to modify the current users profile info so ignore those cases
            default: break
        }
        
        // Blocks community message requests flag
        if let blocksCommunityMessageRequests: Bool = blocksCommunityMessageRequests, sentTimestamp > (profile.lastBlocksCommunityMessageRequests ?? 0) {
            profileChanges.append(Profile.Columns.blocksCommunityMessageRequests.set(to: blocksCommunityMessageRequests))
            profileChanges.append(Profile.Columns.lastBlocksCommunityMessageRequests.set(to: sentTimestamp))
        }
        
        // Profile picture & profile key
        switch (displayPictureUpdate, isCurrentUser) {
            case (.none, _): break
            case (.currentUserUploadImageData, _), (.groupRemove, _), (.groupUpdateTo, _):
                preconditionFailure("Invalid options for this function")
                
            case (.contactRemove, false), (.currentUserRemove, true):
                profileChanges.append(Profile.Columns.profilePictureUrl.set(to: nil))
                profileChanges.append(Profile.Columns.profileEncryptionKey.set(to: nil))
                profileChanges.append(Profile.Columns.profilePictureFileName.set(to: nil))
                profileChanges.append(Profile.Columns.lastProfilePictureUpdate.set(to: sentTimestamp))
            
            case (.contactUpdateTo(let url, let key, let fileName), false),
                (.currentUserUpdateTo(let url, let key, let fileName), true):
                var avatarNeedsDownload: Bool = false
                
                if url != profile.profilePictureUrl {
                    profileChanges.append(Profile.Columns.profilePictureUrl.set(to: url))
                    avatarNeedsDownload = true
                }
                
                if key != profile.profileEncryptionKey && key.count == DisplayPictureManager.aes256KeyByteLength {
                    profileChanges.append(Profile.Columns.profileEncryptionKey.set(to: key))
                }
                
                // Profile filename (this isn't synchronized between devices)
                if let fileName: String = fileName {
                    profileChanges.append(Profile.Columns.profilePictureFileName.set(to: fileName))
                }
                
                // If we have already downloaded the image then no need to download it again
                let maybeFilePath: String? = try? DisplayPictureManager.filepath(
                    for: fileName.defaulting(to: DisplayPictureManager.generateFilename(for: url, using: dependencies)),
                    using: dependencies
                )
                
                if avatarNeedsDownload, let filePath: String = maybeFilePath, !FileManager.default.fileExists(atPath: filePath) {
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
                        canStartJob: dependencies[singleton: .appContext].isMainApp
                    )
                }
                
                // Update the 'lastProfilePictureUpdate' timestamp for either external or local changes
                profileChanges.append(Profile.Columns.lastProfilePictureUpdate.set(to: sentTimestamp))
            
            // Don't want profiles in messages to modify the current users profile info so ignore those cases
            default: break
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
