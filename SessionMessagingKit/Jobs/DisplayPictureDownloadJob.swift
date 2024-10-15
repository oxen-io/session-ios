// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("DisplayPictureDownloadJob", defaultLevel: .info)
}

// MARK: - DisplayPictureDownloadJob

public enum DisplayPictureDownloadJob: JobExecutor {
    public static var maxFailureCount: Int = 1
    public static var requiresThreadId: Bool = false
    public static var requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData),
            let preparedDownload: Network.PreparedRequest<Data> = try? {
                switch details.target {
                    case .profile(_, let url, _), .group(_, let url, _):
                        guard
                            let fileId: String = Attachment.fileId(for: url),
                            let downloadUrl: URL = URL(string: Network.FileServer.downloadUrlString(for: url, fileId: fileId))
                        else { throw NetworkError.invalidURL }
                        
                        return try Network.preparedDownload(
                            url: downloadUrl,
                            using: dependencies
                        )
                        
                    case .community(let fileId, let roomToken, let server):
                        return dependencies[singleton: .storage].read { db in
                            try OpenGroupAPI.preparedDownload(
                                db,
                                fileId: fileId,
                                from: roomToken,
                                on: server,
                                using: dependencies
                            )
                        }
                }
            }()
        else { return failure(job, JobRunnerError.missingRequiredDetails, true) }
            
        let fileName: String = DisplayPictureManager.generateFilename(
            for: (preparedDownload.destination.url?.absoluteString)
                .defaulting(to: preparedDownload.destination.urlPathAndParamsString),
            using: dependencies
        )
        
        guard let filePath: String = try? DisplayPictureManager.filepath(for: fileName, using: dependencies) else {
            Log.error(.cat, "Failed to generate display picture file path for \(details.target)")
            failure(job, DisplayPictureError.invalidFilename, true)
            return
        }
        
        preparedDownload
            .send(using: dependencies)
            .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
            .receive(on: DispatchQueue.global(qos: .background), using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: success(job, false)
                        case .failure(let error): failure(job, error, true)
                    }
                },
                receiveValue: { _, data in
                    // Check to make sure this download is still a valid update
                    guard dependencies[singleton: .storage].read({ db in details.isValidUpdate(db) }) == true else {
                        return
                    }
                    
                    guard
                        let decryptedData: Data = {
                            switch details.target {
                                case .community: return data    // Community data is unencrypted
                                case .profile(_, _, let encryptionKey), .group(_, _, let encryptionKey):
                                    return dependencies[singleton: .crypto].generate(
                                        .decryptedDataDisplayPicture(data: data, key: encryptionKey, using: dependencies)
                                    )
                            }
                        }()
                    else {
                        Log.error(.cat, "Failed to decrypt display picture for \(details.target)")
                        failure(job, DisplayPictureError.writeFailed, true)
                        return
                    }
                    
                    // Ensure the data is actually image data and then save it to disk
                    guard
                        UIImage(data: decryptedData) != nil,
                        dependencies[singleton: .fileManager].createFile(
                            atPath: filePath,
                            contents: decryptedData
                        )
                    else {
                        Log.error(.cat, "Failed to load display picture for \(details.target)")
                        failure(job, DisplayPictureError.writeFailed, true)
                        return
                    }
                    
                    // Update the cache first (in case the DBWrite thread is blocked, this way other threads
                    // can retrieve from the cache and avoid triggering a download)
                    dependencies.mutate(cache: .displayPicture) { cache in
                        cache.imageData[fileName] = decryptedData
                    }
                    
                    // Store the updated information in the database
                    dependencies[singleton: .storage].write { db in
                        switch details.target {
                            case .profile(let id, let url, let encryptionKey):
                                _ = try? Profile
                                    .filter(id: id)
                                    .updateAllAndConfig(
                                        db,
                                        Profile.Columns.profilePictureUrl.set(to: url),
                                        Profile.Columns.profileEncryptionKey.set(to: encryptionKey),
                                        Profile.Columns.profilePictureFileName.set(to: fileName),
                                        Profile.Columns.lastProfilePictureUpdate.set(to: details.timestamp),
                                        calledFromConfig: nil,
                                        using: dependencies
                                    )
                                
                            case .group(let id, let url, let encryptionKey):
                                _ = try? ClosedGroup
                                    .filter(id: id)
                                    .updateAllAndConfig(
                                        db,
                                        ClosedGroup.Columns.displayPictureUrl.set(to: url),
                                        ClosedGroup.Columns.displayPictureEncryptionKey.set(to: encryptionKey),
                                        ClosedGroup.Columns.displayPictureFilename.set(to: fileName),
                                        ClosedGroup.Columns.lastDisplayPictureUpdate.set(to: details.timestamp),
                                        calledFromConfig: nil,
                                        using: dependencies
                                    )
                                
                            case .community(_, let roomToken, let server):
                                _ = try? OpenGroup
                                    .filter(id: OpenGroup.idFor(roomToken: roomToken, server: server))
                                    .updateAllAndConfig(
                                        db,
                                        OpenGroup.Columns.displayPictureFilename.set(to: fileName),
                                        OpenGroup.Columns.lastDisplayPictureUpdate.set(to: details.timestamp),
                                        calledFromConfig: nil,
                                        using: dependencies
                                    )
                        }
                    }
                }
            )
    }
}

// MARK: - DisplayPictureDownloadJob.Details

extension DisplayPictureDownloadJob {
    public enum Target: Codable, Hashable, CustomStringConvertible {
        case profile(id: String, url: String, encryptionKey: Data)
        case group(id: String, url: String, encryptionKey: Data)
        case community(imageId: String, roomToken: String, server: String)
        
        var isValid: Bool {
            switch self {
                case .profile(_, let url, let encryptionKey), .group(_, let url, let encryptionKey):
                    return (
                        !url.isEmpty &&
                        Attachment.fileId(for: url) != nil &&
                        encryptionKey.count == DisplayPictureManager.aes256KeyByteLength
                    )
                    
                case .community(let imageId, _, _): return !imageId.isEmpty
            }
        }
        
        // MARK: - CustomStringConvertible
        
        public var description: String {
            switch self {
                case .profile(let id, _, _): return "profile: \(id)"
                case .group(let id, _, _): return "group: \(id)"
                case .community(_, let roomToken, let server): return "room: \(roomToken) on server: \(server)"
            }
        }
    }
    
    public struct Details: Codable, Hashable {
        public let target: Target
        public let timestamp: TimeInterval
        
        // MARK: - Hashable
        
        public func hash(into hasher: inout Hasher) {
            /// We intentionally leave `timestamp` out of the hash value because when we insert the job we want
            /// it to prevent duplicate jobs from being added with the same `target` information and including
            /// the `timestamp` could likely result in multiple jobs downloading the same `target`
            target.hash(into: &hasher)
        }
        
        // MARK: - Initialization
        
        public init?(target: Target, timestamp: TimeInterval) {
            guard target.isValid else { return nil }
            
            self.target = {
                switch target {
                    case .community(let imageId, let roomToken, let server):
                        return .community(
                            imageId: imageId,
                            roomToken: roomToken,
                            server: server.lowercased()   // Always in lowercase on `OpenGroup`
                        )
                        
                    default: return target
                }
            }()
            self.timestamp = timestamp
        }
        
        public init?(owner: DisplayPictureManager.Owner) {
            switch owner {
                case .user(let profile):
                    guard
                        let url: String = profile.profilePictureUrl,
                        let key: Data = profile.profileEncryptionKey,
                        let details: Details = Details(
                            target: .profile(id: profile.id, url: url, encryptionKey: key),
                            timestamp: (profile.lastProfilePictureUpdate ?? 0)
                        )
                    else { return nil }
                    
                    self = details
                    
                case .group(let group):
                    guard
                        let url: String = group.displayPictureUrl,
                        let key: Data = group.displayPictureEncryptionKey,
                        let details: Details = Details(
                            target: .group(id: group.id, url: url, encryptionKey: key),
                            timestamp: (group.lastDisplayPictureUpdate ?? 0)
                        )
                    else { return nil }
                    
                    self = details
                    
                case .community(let openGroup):
                    guard
                        let imageId: String = openGroup.imageId,
                        let details: Details = Details(
                            target: .community(
                                imageId: imageId,
                                roomToken: openGroup.roomToken,
                                server: openGroup.server
                            ),
                            timestamp: (openGroup.lastDisplayPictureUpdate ?? 0)
                        )
                    else { return nil }
                    
                    self = details
                    
                case .file: return nil
            }
        }
        
        // MARK: - Functions
        
        fileprivate func isValidUpdate(_ db: Database) -> Bool {
            switch self.target {
                case .profile(let id, let url, let encryptionKey):
                    guard let latestProfile: Profile = try? Profile.fetchOne(db, id: id) else { return false }
                    
                    return (
                        timestamp >= (latestProfile.lastProfilePictureUpdate ?? 0) || (
                            encryptionKey == latestProfile.profileEncryptionKey &&
                            url == latestProfile.profilePictureUrl
                        )
                    )
                    
                case .group(let id, let url, let encryptionKey):
                    guard let latestGroup: ClosedGroup = try? ClosedGroup.fetchOne(db, id: id) else { return false }
                    
                    return (
                        timestamp >= (latestGroup.lastDisplayPictureUpdate ?? 0) || (
                            encryptionKey == latestGroup.displayPictureEncryptionKey &&
                            url == latestGroup.displayPictureUrl
                        )
                    )
                    
                case .community(let imageId, let roomToken, let server):
                    guard
                        let latestGroup: OpenGroup = try? OpenGroup.fetchOne(
                            db,
                            id: OpenGroup.idFor(roomToken: roomToken, server: server)
                        )
                    else { return false }
                    
                    return (
                        timestamp >= (latestGroup.lastDisplayPictureUpdate ?? 0) ||
                        imageId == latestGroup.imageId
                    )
            }
        }
    }
}
