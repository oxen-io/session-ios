// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import UIKit.UIImage
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

enum _022_GroupsRebuildChanges: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "GroupsRebuildChanges"
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var requirements: [MigrationRequirement] = [.sessionIdCached, .libSessionStateLoaded]
    static var fetchedTables: [(FetchableRecord & TableRecord).Type] = [
        Identity.self, OpenGroup.self
    ]
    static var createdOrAlteredTables: [(FetchableRecord & TableRecord).Type] = [
        SessionThread.self, ClosedGroup.self, OpenGroup.self, GroupMember.self
    ]
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        try db.alter(table: SessionThread.self) { t in
            t.add(.isDraft, .boolean).defaults(to: false)
        }
        
        try db.alter(table: ClosedGroup.self) { t in
            t.add(.groupDescription, .text)
            t.add(.displayPictureUrl, .text)
            t.add(.displayPictureFilename, .text)
            t.add(.displayPictureEncryptionKey, .blob)
            t.add(.lastDisplayPictureUpdate, .integer).defaults(to: 0)
            t.add(.shouldPoll, .boolean).defaults(to: false)
            t.add(.groupIdentityPrivateKey, .blob)
            t.add(.authData, .blob)
            t.add(.invited, .boolean).defaults(to: false)
        }
        
        try db.alter(table: OpenGroup.self) { t in
            t.add(.displayPictureFilename, .text)
            t.add(.lastDisplayPictureUpdate, .integer).defaults(to: 0)
        }
        
        try db.alter(table: GroupMember.self) { t in
            t.add(.roleStatus, .integer)
                .notNull()
                .defaults(to: GroupMember.RoleStatus.accepted)
        }
        
        // Update existing groups where the current user is a member to have `shouldPoll` as `true`
        try ClosedGroup
            .joining(
                required: ClosedGroup.members
                    .filter(GroupMember.Columns.profileId == dependencies[cache: .general].sessionId.hexString)
            )
            .updateAll(
                db,
                ClosedGroup.Columns.shouldPoll.set(to: true)
            )
        
        // Move the `imageData` out of the `OpenGroup` table and on to disk to be consistent with
        // the other display picture logic
        let existingImageInfo: [OpenGroupImageInfo] = try OpenGroup
            .filter(OpenGroup.Columns.deprecatedColumn("imageData") != nil)
            .select(OpenGroup.Columns.threadId, OpenGroup.Columns.deprecatedColumn("imageData"))
            .asRequest(of: OpenGroupImageInfo.self)
            .fetchAll(db)
        
        existingImageInfo.forEach { imageInfo in
            let fileName: String = DisplayPictureManager.generateFilename(using: dependencies)
            
            guard let filePath: String = try? DisplayPictureManager.filepath(for: fileName, using: dependencies) else {
                Log.error("[GroupsRebuildChanges] Failed to generate community file path for current file name")
                return
            }
            
            // Save the decrypted display picture to disk
            try? imageInfo.data.write(to: URL(fileURLWithPath: filePath), options: [.atomic])
            
            guard UIImage(contentsOfFile: filePath) != nil else {
                Log.error("[GroupsRebuildChanges] Failed to save Community imageData for \(imageInfo.threadId)")
                return
            }
            
            // Update the database with the new info
            _ = try? OpenGroup
                .filter(id: imageInfo.threadId)
                .updateAll( // Unsynced so no 'updateAllAndConfig'
                    db,
                    OpenGroup.Columns.deprecatedColumn("imageData").set(to: nil),
                    OpenGroup.Columns.displayPictureFilename.set(to: fileName),
                    OpenGroup.Columns.lastDisplayPictureUpdate.set(
                        to: TimeInterval(dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
                    )
                )
        }
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
    
    struct OpenGroupImageInfo: FetchableRecord, Decodable, ColumnExpressible {
        typealias Columns = CodingKeys
        enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case threadId
            case data = "imageData"
        }
        
        let threadId: String
        let data: Data
    }
}
