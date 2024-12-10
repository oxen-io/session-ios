// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("RetrieveDefaultOpenGroupRoomsJob", defaultLevel: .info)
}

// MARK: - RetrieveDefaultOpenGroupRoomsJob

public enum RetrieveDefaultOpenGroupRoomsJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        /// Don't run when inactive or not in main app
        ///
        /// Additionally, since this job can be triggered by the user viewing the "Join Community" screen it's possible for multiple jobs to run at
        /// the same time, we don't want to waste bandwidth by making redundant calls to fetch the default rooms so don't do anything if there
        /// is already a job running
        guard
            dependencies[defaults: .appGroup, key: .isMainAppActive],
            dependencies[singleton: .jobRunner]
                .jobInfoFor(state: .running, variant: .retrieveDefaultOpenGroupRooms)
                .filter({ key, info in key != job.id })     // Exclude this job
                .isEmpty
        else { return deferred(job) }
        
        // The OpenGroupAPI won't make any API calls if there is no entry for an OpenGroup
        // in the database so we need to create a dummy one to retrieve the default room data
        let defaultGroupId: String = OpenGroup.idFor(roomToken: "", server: OpenGroupAPI.defaultServer)
        
        dependencies[singleton: .storage].write { db in
            guard try OpenGroup.exists(db, id: defaultGroupId) == false else { return }
            
            try OpenGroup(
                server: OpenGroupAPI.defaultServer,
                roomToken: "",
                publicKey: OpenGroupAPI.defaultServerPublicKey,
                isActive: false,
                name: "",
                userCount: 0,
                infoUpdates: 0
            )
            .upserted(db)
        }
        
        /// Try to retrieve the default rooms 8 times
        dependencies[singleton: .storage]
            .readPublisher { [dependencies] db -> Network.PreparedRequest<OpenGroupAPI.CapabilitiesAndRoomsResponse> in
                try OpenGroupAPI.preparedCapabilitiesAndRooms(
                    db,
                    on: OpenGroupAPI.defaultServer,
                    using: dependencies
                )
            }
            .flatMap { [dependencies] request in request.send(using: dependencies) }
            .subscribe(on: queue, using: dependencies)
            .receive(on: queue, using: dependencies)
            .retry(8, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished:
                            Log.info(.cat, "Successfully retrieved default Community rooms")
                            success(job, false)
                        
                        case .failure(let error):
                            Log.error(.cat, "Failed to get default Community rooms due to error: \(error)")
                            failure(job, error, false)
                    }
                },
                receiveValue: { info, response in
                    let defaultRooms: [OpenGroupManager.DefaultRoomInfo]? = dependencies[singleton: .storage].write { db -> [OpenGroupManager.DefaultRoomInfo] in
                        // Store the capabilities first
                        OpenGroupManager.handleCapabilities(
                            db,
                            capabilities: response.capabilities.data,
                            on: OpenGroupAPI.defaultServer
                        )
                        
                        let existingImageIds: [String: String] = try OpenGroup
                            .filter(OpenGroup.Columns.server == OpenGroupAPI.defaultServer)
                            .filter(OpenGroup.Columns.imageId != nil)
                            .fetchAll(db)
                            .reduce(into: [:]) { result, next in result[next.id] = next.imageId }
                        let result: [OpenGroupManager.DefaultRoomInfo] = try response.rooms.data
                            .compactMap { room -> OpenGroupManager.DefaultRoomInfo? in
                                /// Try to insert an inactive version of the OpenGroup (use `insert` rather than
                                /// `save` as we want it to fail if the room already exists)
                                do {
                                    return (
                                        room,
                                        try OpenGroup(
                                            server: OpenGroupAPI.defaultServer,
                                            roomToken: room.token,
                                            publicKey: OpenGroupAPI.defaultServerPublicKey,
                                            isActive: false,
                                            name: room.name,
                                            roomDescription: room.roomDescription,
                                            imageId: room.imageId,
                                            userCount: room.activeUsers,
                                            infoUpdates: room.infoUpdates
                                        )
                                        .inserted(db)
                                    )
                                }
                                catch {
                                    return try OpenGroup
                                        .fetchOne(
                                            db,
                                            id: OpenGroup.idFor(
                                                roomToken: room.token,
                                                server: OpenGroupAPI.defaultServer
                                            )
                                        )
                                        .map { (room, $0) }
                                }
                            }
                        
                        /// Schedule the room image download (if it doesn't match out current one)
                        result.forEach { room, openGroup in
                            let openGroupId: String = OpenGroup.idFor(roomToken: room.token, server: OpenGroupAPI.defaultServer)
                            
                            guard
                                let imageId: String = room.imageId,
                                imageId != existingImageIds[openGroupId] ||
                                openGroup.displayPictureFilename == nil
                            else { return }
                            
                            dependencies[singleton: .jobRunner].add(
                                db,
                                job: Job(
                                    variant: .displayPictureDownload,
                                    shouldBeUnique: true,
                                    details: DisplayPictureDownloadJob.Details(
                                        target: .community(
                                            imageId: imageId,
                                            roomToken: room.token,
                                            server: OpenGroupAPI.defaultServer
                                        ),
                                        timestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
                                    )
                                ),
                                canStartJob: true
                            )
                        }
                        
                        return result
                    }
                    
                    /// Update the `openGroupManager` cache to have the default rooms
                    dependencies.mutate(cache: .openGroupManager) { cache in
                        cache.setDefaultRoomInfo(defaultRooms ?? [])
                    }
                }
            )
    }
    
    public static func run(using dependencies: Dependencies) {
        RetrieveDefaultOpenGroupRoomsJob.run(
            Job(variant: .retrieveDefaultOpenGroupRooms, behaviour: .runOnce),
            queue: DispatchQueue.global(qos: .default),
            success: { _, _ in },
            failure: { _, _, _ in },
            deferred: { _ in },
            using: dependencies
        )
    }
}
