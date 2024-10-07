// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
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
        // Don't run when inactive or not in main app
        guard dependencies[defaults: .appGroup, key: .isMainAppActive] else {
            return deferred(job) // Don't need to do anything if it's not the main app
        }
        
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
        
        dependencies[singleton: .openGroupManager]
            .getDefaultRoomsIfNeeded()
            .subscribe(on: queue)
            .receive(on: queue)
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
                }
            )
    }
}
