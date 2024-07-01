// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration adds a flag indicating whether a profile has indicated it is blocking community message requests
enum _015_BlockCommunityMessageRequests: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "BlockCommunityMessageRequests" // stringlint:disable
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.01
    static var requirements: [MigrationRequirement] = [.libSessionStateLoaded]
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = [
        Identity.self, Setting.self
    ]
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = [Profile.self]
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        // Add the new 'Profile' properties
        try db.alter(table: Profile.self) { t in
            t.add(.blocksCommunityMessageRequests, .boolean)
            t.add(.lastBlocksCommunityMessageRequests, .integer).defaults(to: 0)
        }
        
        // If the user exists and the 'checkForCommunityMessageRequests' hasn't already been set then default it to "false"
        if
            Identity.userExists(db),
            (try Setting.exists(db, id: Setting.BoolKey.checkForCommunityMessageRequests.rawValue)) == false
        {
            let rawBlindedMessageRequestValue: Int32 = try LibSession
                .config(for: .userProfile, publicKey: getUserHexEncodedPublicKey(db))
                .wrappedValue
                .map { conf -> Int32 in try LibSession.rawBlindedMessageRequestValue(in: conf) }
                .defaulting(to: -1)
            
            // Use the value in the config if we happen to have one, otherwise use the default
            db[.checkForCommunityMessageRequests] = (rawBlindedMessageRequestValue < 0 ?
                true :
                (rawBlindedMessageRequestValue > 0)
            )
        }
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}
