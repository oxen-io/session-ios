// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

@testable import GRDB

public extension MutablePersistableRecord {
    /// This is a test method which allows for inserting with a pre-defined id (it triggers the `didInsert` function directly before inserting which
    /// is likely to cause problems with other tests if we ever use it for anything other than assigning the `id`)
    mutating func insert(_ db: Database, withRowId rowID: Int64) throws {
        didInsert(InsertionSuccess(rowID: rowID, rowIDColumn: nil, persistenceContainer: PersistenceContainer()))
        try insert(db)
    }
}
