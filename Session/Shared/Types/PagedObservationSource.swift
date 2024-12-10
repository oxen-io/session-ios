// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

protocol PagedObservationSource {
    associatedtype PagedTable: TableRecord & ColumnExpressible & Identifiable
    associatedtype PagedDataModel: FetchableRecordWithRowId & Identifiable
    
    var pagedDataObserver: PagedDatabaseObserver<PagedTable, PagedDataModel>? { get }
    
    func didInit(using dependencies: Dependencies)
    func loadPageBefore()
    func loadPageAfter()
}

extension PagedObservationSource {
    public func didInit(using dependencies: Dependencies) {
        dependencies[singleton: .storage].addObserver(pagedDataObserver)
    }
}

extension PagedObservationSource where PagedTable.ID: SQLExpressible {
    func loadPageBefore() { pagedDataObserver?.load(.pageBefore) }
    func loadPageAfter() { pagedDataObserver?.load(.pageAfter) }
}
