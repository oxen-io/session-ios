// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

enum _001_InitialSetupMigration: Migration {
    static let identifier: String = "initialSetup"
    
    static func migrate(_ db: Database) throws {
        try db.create(table: Identity.self) { t in
            t.column(.variant, .text)
                .notNull()
                .unique()
                .primaryKey()
            t.column(.data, .blob).notNull()
        }
        
        try db.create(table: Job.self) { t in
            t.column(.id, .integer)
                .notNull()
                .primaryKey(autoincrement: true)
            t.column(.failureCount, .integer)
                .notNull()
                .defaults(to: 0)
            t.column(.variant, .integer)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column(.behaviour, .integer)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column(.nextRunTimestamp, .double)
                .notNull()
                .indexed()                                            // Quicker querying
                .defaults(to: 0)
            t.column(.threadId, .text)
                .indexed()                                            // Quicker querying
            t.column(.interactionId, .text)
                .indexed()                                            // Quicker querying
            t.column(.details, .blob)
        }
        
        try db.create(table: JobDependencies.self) { t in
            t.column(.jobId, .integer)
                .notNull()
                .references(Job.self, onDelete: .cascade)             // Delete if Job deleted
            t.column(.dependantId, .integer)
                .notNull()
                .indexed()                                            // Quicker querying
                .references(Job.self, onDelete: .cascade)             // Delete if Job deleted
            
            t.primaryKey([.jobId, .dependantId])
        }
        
        try db.create(table: Setting.self) { t in
            t.column(.key, .text)
                .notNull()
                .unique()
                .primaryKey()
            t.column(.value, .blob).notNull()
        }
    }
}