// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public enum RetrieveDefaultOpenGroupRoomsJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies
    ) {
        // Don't run when inactive or not in main app
        guard dependencies[defaults: .appGroup, key: .isMainAppActive] else {
            deferred(job, dependencies) // Don't need to do anything if it's not the main app
            return
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
        
        OpenGroupManager.getDefaultRoomsIfNeeded()
            .subscribe(on: queue)
            .receive(on: queue)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished:
                            SNLog("[RetrieveDefaultOpenGroupRoomsJob] Successfully retrieved default Community rooms")
                            success(job, false, dependencies)
                            
                        case .failure(let error):
                            SNLog("[RetrieveDefaultOpenGroupRoomsJob] Failed to get default Community rooms")
                            failure(job, error, false, dependencies)
                    }
                }
            )
    }
}
