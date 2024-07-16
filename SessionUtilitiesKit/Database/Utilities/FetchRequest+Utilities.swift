// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import GRDB

public extension FetchRequest where RowDecoder: FetchableRecord {
    func fetchOne(_ db: Database, orThrow error: Error) throws -> RowDecoder {
        guard let result: RowDecoder = try fetchOne(db) else { throw error }
        
        return result
    }
}

public extension FetchRequest where RowDecoder: DatabaseValueConvertible {
    func fetchOne(_ db: Database, orThrow error: Error) throws -> RowDecoder {
        guard let result: RowDecoder = try fetchOne(db) else { throw error }
        
        return result
    }
}
