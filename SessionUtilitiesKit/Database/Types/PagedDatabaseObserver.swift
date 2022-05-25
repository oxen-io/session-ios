// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

// MARK: - PagedDatabaseObserver

/// This type manages observation and paging for the provided dataQuery
///
/// **Note:** We **MUST** have accurate `filterSQL` and `orderSQL` values otherwise the indexing won't work
public class PagedDatabaseObserver<ObservedTable, T>: TransactionObserver where ObservedTable: TableRecord & ColumnExpressible & Identifiable, T: FetchableRecordWithRowId & Identifiable {
    // MARK: - Variables
    
    private let pagedTableName: String
    private let idColumnName: String
    private var pageInfo: Atomic<PagedData.PageInfo>
    
    private let allObservedTableNames: Set<String>
    private let observedInserts: Set<String>
    private let observedUpdateColumns: [String: Set<String>]
    private let observedDeletes: Set<String>
    
    private let joinSQL: SQL?
    private let filterSQL: SQL
    private let orderSQL: SQL
    private let dataQuery: (SQL?, SQL?) -> AdaptedFetchRequest<SQLRequest<T>>
    private let associatedRecords: [ErasedAssociatedRecord]
    
    private var dataCache: Atomic<DataCache<T>> = Atomic(DataCache())
    private var isLoadingMoreData: Atomic<Bool> = Atomic(false)
    private let changesInCommit: Atomic<Set<PagedData.TrackedChange>> = Atomic([])
    private let onChangeUnsorted: (([T], PagedData.PageInfo) -> ())
    
    // MARK: - Initialization
    
    fileprivate init(
        pagedTable: ObservedTable.Type,
        pageSize: Int,
        idColumn: ObservedTable.Columns,
        observedChanges: [PagedData.ObservedChanges],
        joinSQL: SQL? = nil,
        filterSQL: SQL,
        orderSQL: SQL,
        dataQuery: @escaping (SQL?, SQL?) -> AdaptedFetchRequest<SQLRequest<T>>,
        associatedRecords: [ErasedAssociatedRecord] = [],
        onChangeUnsorted: @escaping ([T], PagedData.PageInfo) -> (),
        initialQueryTarget: PagedData.PageInfo.InternalTarget?
    ) {
        let associatedTables: Set<String> = associatedRecords.map { $0.databaseTableName }.asSet()
        assert(!associatedTables.contains(pagedTable.databaseTableName), "The paged table cannot also exist as an associatedRecord")
        
        self.pagedTableName = pagedTable.databaseTableName
        self.idColumnName = idColumn.name
        self.pageInfo = Atomic(PagedData.PageInfo(pageSize: pageSize))
        self.joinSQL = joinSQL
        self.filterSQL = filterSQL
        self.orderSQL = orderSQL
        self.dataQuery = dataQuery
        self.associatedRecords = associatedRecords
        self.onChangeUnsorted = onChangeUnsorted
        
        // Combine the various observed changes into a single set
        let allObservedChanges: [PagedData.ObservedChanges] = observedChanges
            .appending(contentsOf: associatedRecords.flatMap { $0.observedChanges })
        self.allObservedTableNames = allObservedChanges
            .map { $0.databaseTableName }
            .asSet()
        self.observedInserts = allObservedChanges
            .filter { $0.events.contains(.insert) }
            .map { $0.databaseTableName }
            .asSet()
        self.observedUpdateColumns = allObservedChanges
            .filter { $0.events.contains(.update) }
            .reduce(into: [:]) { (prev: inout [String: Set<String>], next: PagedData.ObservedChanges) in
                guard !next.columns.isEmpty else { return }
                
                prev[next.databaseTableName] = next.columns.asSet()
            }
        self.observedDeletes = allObservedChanges
            .filter { $0.events.contains(.delete) }
            .map { $0.databaseTableName }
            .asSet()
        
        // Run the initial query if there is one
        guard let initialQueryTarget: PagedData.PageInfo.InternalTarget = initialQueryTarget else { return }
        
        self.load(initialQueryTarget)
    }
    
    // MARK: - TransactionObserver
    
    public func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        switch eventKind {
            case .insert(let tableName): return self.observedInserts.contains(tableName)
            case .delete(let tableName): return self.observedDeletes.contains(tableName)
            
            case .update(let tableName, let columnNames):
                return (self.observedUpdateColumns[tableName]?
                    .intersection(columnNames)
                    .isEmpty == false)
        }
    }
    
    public func databaseDidChange(with event: DatabaseEvent) {
        // This will get called whenever the `observes(eventsOfKind:)` returns
        // true and will include all changes which occurred in the commit so we
        // need to ignore any non-observed tables, unfortunately we also won't
        // know if the changes to observed tables are actually relevant yet as
        // changes only include table and column info at this stage
        guard allObservedTableNames.contains(event.tableName) else { return }
        
        // The 'event' object only exists during this method so we need to copy the info
        // from it, otherwise it will cease to exist after this metod call finishes
        changesInCommit.mutate { $0.insert(PagedData.TrackedChange(event: event)) }
    }
    
    // Note: We will process all updates which come through this method even if
    // 'onChange' is null because if the UI stops observing and then starts again
    // later we don't want to have missed any changes which happened while the UI
    // wasn't subscribed (and doing a full re-query seems painful...)
    public func databaseDidCommit(_ db: Database) {
        var committedChanges: Set<PagedData.TrackedChange> = []
        self.changesInCommit.mutate { cachedChanges in
            committedChanges = cachedChanges
            cachedChanges.removeAll()
        }
        
        // Note: This method will be called regardless of whether there were actually changes
        // in the areas we are observing so we want to early-out if there aren't any relevant
        // updated rows
        guard !committedChanges.isEmpty else { return }
        
        let orderSQL: SQL = self.orderSQL
        let filterSQL: SQL = self.filterSQL
        let associatedRecords: [ErasedAssociatedRecord] = self.associatedRecords
        
        let updateDataAndCallbackIfNeeded: (DataCache<T>, PagedData.PageInfo, Bool) -> () = { [weak self] updatedDataCache, updatedPageInfo, cacheHasChanges in
            let associatedDataInfo: [(hasChanges: Bool, data: ErasedAssociatedRecord)] = associatedRecords
                .map { associatedRecord in
                    let hasChanges: Bool = associatedRecord.tryUpdateForDatabaseCommit(
                        db,
                        changes: committedChanges,
                        orderSQL: orderSQL,
                        filterSQL: filterSQL,
                        pageInfo: updatedPageInfo
                    )
                    
                    return (hasChanges, associatedRecord)
                }
            
            // Check if we need to trigger a change callback
            guard cacheHasChanges || associatedDataInfo.contains(where: { hasChanges, _ in hasChanges }) else {
                return
            }
            
            // If the associated data changed then update the updatedCachedData with the
            // updated associated data
            var finalUpdatedDataCache: DataCache<T> = updatedDataCache
            
            associatedDataInfo.forEach { hasChanges, associatedData in
                guard cacheHasChanges || hasChanges else { return }
                
                finalUpdatedDataCache = associatedData.attachAssociatedData(to: finalUpdatedDataCache)
            }
            
            // Update the cache, pageInfo and the change callback
            self?.dataCache.mutate { $0 = finalUpdatedDataCache }
            self?.pageInfo.mutate { $0 = updatedPageInfo }
            
            DispatchQueue.main.async { [weak self] in
                self?.onChangeUnsorted(finalUpdatedDataCache.values, updatedPageInfo)
            }
        }
        
        // Determing if there were any relevant paged data changes
        let relevantChanges: Set<PagedData.TrackedChange> = committedChanges
            .filter { $0.tableName == pagedTableName }
        
        guard !relevantChanges.isEmpty else {
            updateDataAndCallbackIfNeeded(self.dataCache.wrappedValue, self.pageInfo.wrappedValue, false)
            return
        }
        
        var updatedPageInfo: PagedData.PageInfo = self.pageInfo.wrappedValue
        var updatedDataCache: DataCache<T> = self.dataCache.wrappedValue
        let deletionChanges: [Int64] = relevantChanges
            .filter { $0.kind == .delete }
            .map { $0.rowId }
        let oldDataCount: Int = dataCache.wrappedValue.count
        
        // First remove any items which have been deleted
        if !deletionChanges.isEmpty {
            updatedDataCache = updatedDataCache.deleting(rowIds: deletionChanges)
            
            // Make sure there were actually changes
            if updatedDataCache.count != oldDataCount {
                let dataSizeDiff: Int = (updatedDataCache.count - oldDataCount)
                
                updatedPageInfo = PagedData.PageInfo(
                    pageSize: updatedPageInfo.pageSize,
                    pageOffset: updatedPageInfo.pageOffset,
                    currentCount: (updatedPageInfo.currentCount + dataSizeDiff),
                    totalCount: (updatedPageInfo.totalCount + dataSizeDiff)
                )
            }
        }
        
        // If there are no inserted/updated rows then trigger the update callback and stop here
        let rowIdsToQuery: [Int64] = committedChanges
            .filter { $0.kind != .delete }
            .map { $0.rowId }
        
        guard !rowIdsToQuery.isEmpty else {
            updateDataAndCallbackIfNeeded(updatedDataCache, updatedPageInfo, !deletionChanges.isEmpty)
            return
        }
        
        // Fetch the indexes of the rowIds so we can determine whether they should be added to the screen
        let itemIndexes: [Int64] = PagedData.indexes(
            db,
            rowIds: rowIdsToQuery,
            tableName: pagedTableName,
            orderSQL: orderSQL,
            filterSQL: filterSQL
        )
        
        // Determine if the indexes for the row ids should be displayed on the screen and remove any
        // which shouldn't - values less than 'currentCount' or if there is at least one value less than
        // 'currentCount' and the indexes are sequential (ie. more than the current loaded content was
        // added at once)
        let itemIndexesAreSequential: Bool = (itemIndexes.map { $0 - 1 }.dropFirst() == itemIndexes.dropLast())
        let hasOneValidIndex: Bool = itemIndexes.contains(where: { $0 < updatedPageInfo.currentCount })
        let validRowIds: [Int64] = (itemIndexesAreSequential && hasOneValidIndex ?
            rowIdsToQuery :
            zip(itemIndexes, rowIdsToQuery)
                .filter { index, _ -> Bool in index < updatedPageInfo.currentCount }
                .map { _, rowId -> Int64 in rowId }
        )

        // If there are no valid attachment row ids then stop here
        guard !validRowIds.isEmpty else {
            updateDataAndCallbackIfNeeded(updatedDataCache, updatedPageInfo, !deletionChanges.isEmpty)
            return
        }

        // Fetch the inserted/updated rows
        let additionalFilters: SQL = SQL(validRowIds.contains(Column.rowID))
        let updatedItems: [T] = (try? dataQuery(additionalFilters, nil)
            .fetchAll(db))
            .defaulting(to: [])

        // If the inserted/updated rows we irrelevant (associated to data which doesn't pass
        // the filter) then trigger the update callback (if there were deletions) and stop here
        guard !updatedItems.isEmpty else {
            updateDataAndCallbackIfNeeded(updatedDataCache, updatedPageInfo, !deletionChanges.isEmpty)
            return
        }

        // Process the upserted data
        updatedDataCache = updatedDataCache.upserting(items: updatedItems)
        
        // Update the page info for the upserted data
        let dataSizeDiff: Int = (updatedDataCache.count - oldDataCount)
        
        updatedPageInfo = PagedData.PageInfo(
            pageSize: updatedPageInfo.pageSize,
            pageOffset: updatedPageInfo.pageOffset,
            currentCount: (updatedPageInfo.currentCount + dataSizeDiff),
            totalCount: (updatedPageInfo.totalCount + dataSizeDiff)
        )
        
        updateDataAndCallbackIfNeeded(updatedDataCache, updatedPageInfo, true)
    }
    
    public func databaseDidRollback(_ db: Database) {}
    
    // MARK: - Functions
    
    fileprivate func load(_ target: PagedData.PageInfo.InternalTarget) {
        // Only allow a single page load at a time
        guard !self.isLoadingMoreData.wrappedValue else { return }

        // Prevent more fetching until we have completed adding the page
        self.isLoadingMoreData.mutate { $0 = true }
        
        let currentPageInfo: PagedData.PageInfo = self.pageInfo.wrappedValue
        
        if case .initialPageAround(_) = target, currentPageInfo.currentCount > 0 {
            SNLog("Unable to load initialPageAround if there is already data")
            return
        }
        
        // Store locally to avoid giant capture code
        let pagedTableName: String = self.pagedTableName
        let idColumnName: String = self.idColumnName
        let joinSQL: SQL? = self.joinSQL
        let filterSQL: SQL = self.filterSQL
        let orderSQL: SQL = self.orderSQL
        let dataQuery: (SQL?, SQL?) -> AdaptedFetchRequest<SQLRequest<T>> = self.dataQuery
        
        let loadedPage: (data: [T]?, pageInfo: PagedData.PageInfo)? = GRDBStorage.shared.read { [weak self] db in
            let totalCount: Int = try dataQuery(filterSQL, nil)
                .fetchCount(db)
            let queryInfo: (limit: Int, offset: Int, updatedCacheOffset: Int)? = {
                switch target {
                    case .initialPageAround(let targetId):
                        // If we want to focus on a specific item then we need to find it's index in
                        // the queried data
                        let maybeIndex: Int? = PagedData.index(
                            db,
                            for: targetId,
                            tableName: pagedTableName,
                            idColumn: idColumnName,
                            requiredJoinSQL: joinSQL,
                            orderSQL: orderSQL,
                            filterSQL: filterSQL
                        )
                        
                        // If we couldn't find the targetId then just load the first page
                        guard let targetIndex: Int = maybeIndex else {
                            return (currentPageInfo.pageSize, 0, 0)
                        }
                        
                        let updatedOffset: Int = {
                            // If the focused item is within the first or last half of the page
                            // then we still want to retrieve a full page so calculate the offset
                            // needed to do so (snapping to the ends)
                            let halfPageSize: Int = Int(floor(Double(currentPageInfo.pageSize) / 2))
                            
                            guard targetIndex > halfPageSize else { return 0 }
                            guard targetIndex < (totalCount - halfPageSize) else {
                                return (totalCount - currentPageInfo.pageSize)
                            }

                            return (targetIndex - halfPageSize)
                        }()

                        return (currentPageInfo.pageSize, updatedOffset, updatedOffset)
                        
                    case .pageBefore:
                        let updatedOffset: Int = max(0, (currentPageInfo.pageOffset - currentPageInfo.pageSize))
                        
                        return (
                            currentPageInfo.pageSize,
                            updatedOffset,
                            updatedOffset
                        )
                        
                    case .pageAfter:
                        return (
                            currentPageInfo.pageSize,
                            (currentPageInfo.pageOffset + currentPageInfo.currentCount),
                            currentPageInfo.pageOffset
                        )
                    
                    case .untilInclusive(let targetId, let padding):
                        // If we want to focus on a specific item then we need to find it's index in
                        // the queried data
                        let maybeIndex: Int? = PagedData.index(
                            db,
                            for: targetId,
                            tableName: pagedTableName,
                            idColumn: idColumnName,
                            orderSQL: orderSQL,
                            filterSQL: filterSQL
                        )
                        let cacheCurrentEndIndex: Int = (currentPageInfo.pageOffset + currentPageInfo.currentCount)
                        
                        // If we couldn't find the targetId or it's already in the cache then do nothing
                        guard
                            let targetIndex: Int = maybeIndex.map({ max(0, min(totalCount, $0)) }),
                            (
                                targetIndex < currentPageInfo.pageOffset ||
                                targetIndex > cacheCurrentEndIndex
                            )
                        else { return nil }
                        
                        // If the target is before the cached data then load before
                        if targetIndex < currentPageInfo.pageOffset {
                            let finalIndex: Int = max(0, (targetIndex - abs(padding)))
                            
                            return (
                                (currentPageInfo.pageOffset - finalIndex),
                                finalIndex,
                                finalIndex
                            )
                        }
                        
                        // Otherwise load after
                        let finalIndex: Int = min(totalCount, (targetIndex + abs(padding)))
                        
                        return (
                            (finalIndex - cacheCurrentEndIndex),
                            cacheCurrentEndIndex,
                            currentPageInfo.pageOffset
                        )
                }
            }()
            
            // If there is no queryOffset then we already have the data we need so
            // early-out (may as well update the 'totalCount' since it may be relevant)
            guard let queryInfo: (limit: Int, offset: Int, updatedCacheOffset: Int) = queryInfo else {
                return (
                    nil,
                    PagedData.PageInfo(
                        pageSize: currentPageInfo.pageSize,
                        pageOffset: currentPageInfo.pageOffset,
                        currentCount: currentPageInfo.currentCount,
                        totalCount: totalCount
                    )
                )
            }
            
            // Fetch the desired data
            let limitSQL: SQL = SQL(stringLiteral: "LIMIT \(queryInfo.limit) OFFSET \(queryInfo.offset)")
            let newData: [T] = try dataQuery(filterSQL, limitSQL)
                .fetchAll(db)
            let updatedLimitInfo: PagedData.PageInfo = PagedData.PageInfo(
                pageSize: currentPageInfo.pageSize,
                pageOffset: queryInfo.updatedCacheOffset,
                currentCount: (currentPageInfo.currentCount + newData.count),
                totalCount: totalCount
            )
            
            // Update the associatedRecords for the newly retrieved data
            self?.associatedRecords.forEach { record in
                record.updateCache(
                    db,
                    rowIds: PagedData.associatedRowIds(
                        db,
                        tableName: record.databaseTableName,
                        pagedTableName: pagedTableName,
                        pagedTypeRowIds: newData.map { $0.rowId },
                        joinToPagedType: record.joinToPagedType
                    ),
                    hasOtherChanges: false
                )
            }

            return (newData, updatedLimitInfo)
        }
        
        // Unwrap the updated data
        guard
            let loadedPageData: [T] = loadedPage?.data,
            let updatedPageInfo: PagedData.PageInfo = loadedPage?.pageInfo
        else {
            // It's possible to get updated page info without having updated data, in that case
            // we do want to update the cache but probably don't need to trigger the change callback
            if let updatedPageInfo: PagedData.PageInfo = loadedPage?.pageInfo {
                self.pageInfo.mutate { $0 = updatedPageInfo }
            }
            return
        }
        
        // Attach any associated data to the loadedPageData
        var associatedLoadedData: DataCache<T> = DataCache(items: loadedPageData)
        
        self.associatedRecords.forEach { record in
            associatedLoadedData = record.attachAssociatedData(to: associatedLoadedData)
        }
        
        // Update the cache and pageInfo
        self.dataCache.mutate { $0 = $0.upserting(items: associatedLoadedData.values) }
        self.pageInfo.mutate { $0 = updatedPageInfo }
        
        let triggerUpdates: () -> () = { [weak self, dataCache = self.dataCache.wrappedValue] in
            self?.onChangeUnsorted(dataCache.values, updatedPageInfo)
            self?.isLoadingMoreData.mutate { $0 = false }
        }
        
        // Make sure the updates run on the main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async { triggerUpdates() }
            return
        }
        
        triggerUpdates()
    }
}

// MARK: - Convenience

public extension PagedDatabaseObserver {
    fileprivate static func initialQueryTarget<ID: SQLExpressible>(
        for initialFocusedId: ID?,
        skipInitialQuery: Bool
    ) -> PagedData.PageInfo.InternalTarget? {
        // Determine if we want to laod the first page immediately (this is generally needed
        // to prevent transitions from looking buggy)
        guard !skipInitialQuery else { return nil }

        switch initialFocusedId {
            case .some(let targetId): return .initialPageAround(id: targetId.sqlExpression)

            // If we don't have a `initialFocusedId` then default to `.pageBefore` (it'll query
            // from a `0` offset
            case .none: return .pageBefore
        }
    }
    
    convenience init(
        pagedTable: ObservedTable.Type,
        pageSize: Int,
        idColumn: ObservedTable.Columns,
        initialFocusedId: ObservedTable.ID? = nil,
        observedChanges: [PagedData.ObservedChanges],
        joinSQL: SQL? = nil,
        filterSQL: SQL,
        orderSQL: SQL,
        dataQuery: @escaping (SQL?, SQL?) -> AdaptedFetchRequest<SQLRequest<T>>,
        associatedRecords: [ErasedAssociatedRecord] = [],
        onChangeUnsorted: @escaping ([T], PagedData.PageInfo) -> (),
        skipInitialQuery: Bool = false
    ) where ObservedTable.ID: SQLExpressible {
        self.init(
            pagedTable: pagedTable,
            pageSize: pageSize,
            idColumn: idColumn,
            observedChanges: observedChanges,
            joinSQL: joinSQL,
            filterSQL: filterSQL,
            orderSQL: orderSQL,
            dataQuery: dataQuery,
            associatedRecords: associatedRecords,
            onChangeUnsorted: onChangeUnsorted,
            initialQueryTarget: PagedDatabaseObserver.initialQueryTarget(
                for: initialFocusedId,
                skipInitialQuery: skipInitialQuery
            )
        )
    }
    
    convenience init(
        pagedTable: ObservedTable.Type,
        pageSize: Int,
        idColumn: ObservedTable.Columns,
        initialFocusedId: ObservedTable.ID? = nil,
        observedChanges: [PagedData.ObservedChanges],
        joinSQL: SQL? = nil,
        filterSQL: SQL,
        orderSQL: SQL,
        dataQuery: @escaping (SQL?, SQL?) -> SQLRequest<T>,
        associatedRecords: [ErasedAssociatedRecord] = [],
        onChangeUnsorted: @escaping ([T], PagedData.PageInfo) -> (),
        skipInitialQuery: Bool = false
    ) where ObservedTable.ID: SQLExpressible {
        self.init(
            pagedTable: pagedTable,
            pageSize: pageSize,
            idColumn: idColumn,
            observedChanges: observedChanges,
            joinSQL: joinSQL,
            filterSQL: filterSQL,
            orderSQL: orderSQL,
            dataQuery: { additionalFilters, limit in
                dataQuery(additionalFilters, limit).adapted { _ in ScopeAdapter([:]) }
            },
            associatedRecords: associatedRecords,
            onChangeUnsorted: onChangeUnsorted,
            initialQueryTarget: PagedDatabaseObserver.initialQueryTarget(
                for: initialFocusedId,
                skipInitialQuery: skipInitialQuery
            )
        )
    }
    
    convenience init<ID>(
        pagedTable: ObservedTable.Type,
        pageSize: Int,
        idColumn: ObservedTable.Columns,
        initialFocusedId: ID? = nil,
        observedChanges: [PagedData.ObservedChanges],
        joinSQL: SQL? = nil,
        filterSQL: SQL,
        orderSQL: SQL,
        dataQuery: @escaping (SQL?, SQL?) -> AdaptedFetchRequest<SQLRequest<T>>,
        associatedRecords: [ErasedAssociatedRecord] = [],
        onChangeUnsorted: @escaping ([T], PagedData.PageInfo) -> (),
        skipInitialQuery: Bool = false
    ) where ObservedTable.ID == Optional<ID>, ID: SQLExpressible {
        self.init(
            pagedTable: pagedTable,
            pageSize: pageSize,
            idColumn: idColumn,
            observedChanges: observedChanges,
            joinSQL: joinSQL,
            filterSQL: filterSQL,
            orderSQL: orderSQL,
            dataQuery: dataQuery,
            associatedRecords: associatedRecords,
            onChangeUnsorted: onChangeUnsorted,
            initialQueryTarget: PagedDatabaseObserver.initialQueryTarget(
                for: initialFocusedId,
                skipInitialQuery: skipInitialQuery
            )
        )
    }
    
    convenience init<ID>(
        pagedTable: ObservedTable.Type,
        pageSize: Int,
        idColumn: ObservedTable.Columns,
        initialFocusedId: ID? = nil,
        observedChanges: [PagedData.ObservedChanges],
        joinSQL: SQL? = nil,
        filterSQL: SQL,
        orderSQL: SQL,
        dataQuery: @escaping (SQL?, SQL?) -> SQLRequest<T>,
        associatedRecords: [ErasedAssociatedRecord] = [],
        onChangeUnsorted: @escaping ([T], PagedData.PageInfo) -> (),
        skipInitialQuery: Bool = false
    ) where ObservedTable.ID == Optional<ID>, ID: SQLExpressible {
        self.init(
            pagedTable: pagedTable,
            pageSize: pageSize,
            idColumn: idColumn,
            observedChanges: observedChanges,
            joinSQL: joinSQL,
            filterSQL: filterSQL,
            orderSQL: orderSQL,
            dataQuery: { additionalFilters, limit in
                dataQuery(additionalFilters, limit).adapted { _ in ScopeAdapter([:]) }
            },
            associatedRecords: associatedRecords,
            onChangeUnsorted: onChangeUnsorted,
            initialQueryTarget: PagedDatabaseObserver.initialQueryTarget(
                for: initialFocusedId,
                skipInitialQuery: skipInitialQuery
            )
        )
    }
    
    func load(_ target: PagedData.PageInfo.Target<ObservedTable.ID>) where ObservedTable.ID: SQLExpressible {
        self.load(target.internalTarget)
    }
    
    func load<ID>(_ target: PagedData.PageInfo.Target<ID>) where ObservedTable.ID == Optional<ID>, ID: SQLExpressible {
        self.load(target.internalTarget)
    }
}

// MARK: - FetchableRecordWithRowId

public protocol FetchableRecordWithRowId: FetchableRecord {
    var rowId: Int64 { get }
}

// MARK: - ErasedAssociatedRecord

public protocol ErasedAssociatedRecord {
    var databaseTableName: String { get }
    var observedChanges: [PagedData.ObservedChanges] { get }
    var joinToPagedType: SQL { get }
    
    func tryUpdateForDatabaseCommit(
        _ db: Database,
        changes: Set<PagedData.TrackedChange>,
        orderSQL: SQL,
        filterSQL: SQL,
        pageInfo: PagedData.PageInfo
    ) -> Bool
    @discardableResult func updateCache(_ db: Database, rowIds: [Int64], hasOtherChanges: Bool) -> Bool
    func attachAssociatedData<O>(to unassociatedCache: DataCache<O>) -> DataCache<O>
}

// MARK: - DataCache

public struct DataCache<T: FetchableRecordWithRowId & Identifiable> {
    /// This is a map of `[RowId: Value]`
    public let data: [Int64: T]
    
    /// This is a map of `[(Identifiable)id: RowId]` and can be used to find the RowId for
    /// a cached value given it's `Identifiable` `id` value
    public let lookup: [AnyHashable: Int64]
    
    public var count: Int { data.count }
    public var values: [T] { Array(data.values) }
    
    // MARK: - Initialization
    
    public init(
        data: [Int64: T] = [:],
        lookup: [AnyHashable: Int64] = [:]
    ) {
        self.data = data
        self.lookup = lookup
    }
    
    fileprivate init(items: [T]) {
        self = DataCache().upserting(items: items)
    }

    // MARK: - Functions
    
    public func deleting(rowIds: [Int64]) -> DataCache<T> {
        var updatedData: [Int64: T] = self.data
        var updatedLookup: [AnyHashable: Int64] = self.lookup
        
        rowIds.forEach { rowId in
            if let cachedItem: T = updatedData.removeValue(forKey: rowId) {
                updatedLookup.removeValue(forKey: cachedItem.id)
            }
        }
        
        return DataCache(
            data: updatedData,
            lookup: updatedLookup
        )
    }
    
    public func upserting(_ item: T) -> DataCache<T> {
        return upserting(items: [item])
    }
    
    public func upserting(items: [T]) -> DataCache<T> {
        var updatedData: [Int64: T] = self.data
        var updatedLookup: [AnyHashable: Int64] = self.lookup
        
        items.forEach { item in
            updatedData[item.rowId] = item
            updatedLookup[item.id] = item.rowId
        }
        
        return DataCache(
            data: updatedData,
            lookup: updatedLookup
        )
    }
}

// MARK: - PagedData

public enum PagedData {
    // MARK: - PageInfo
    
    public struct PageInfo {
        /// This type is identical to the 'Target' type but has it's 'SQLExpressible' requirement removed
        fileprivate enum InternalTarget {
            case initialPageAround(id: SQLExpression)
            case pageBefore
            case pageAfter
            case untilInclusive(id: SQLExpression, padding: Int)
        }
        
        public enum Target<ID: SQLExpressible> {
            /// This will attempt to load a page of data around a specified id
            ///
            /// **Note:** This target will only work if there is no other data in the cache
            case initialPageAround(id: ID)
            
            /// This will attempt to load a page of data before the first item in the cache
            case pageBefore
            
            /// This will attempt to load a page of data after the last item in the cache
            case pageAfter
            
            /// This will attempt to load all data between what is currently in the cache until the
            /// specified id (plus the padding amount)
            ///
            /// **Note:** If the id is already within the cache then this will do nothing (even if
            /// the padding would mean more data should be loaded)
            case untilInclusive(id: ID, padding: Int)
            
            fileprivate var internalTarget: InternalTarget {
                switch self {
                    case .initialPageAround(let id): return .initialPageAround(id: id.sqlExpression)
                    case .pageBefore: return .pageBefore
                    case .pageAfter: return .pageAfter
                    case .untilInclusive(let id, let padding):
                        return .untilInclusive(id: id.sqlExpression, padding: padding)
                }
            }
        }
        
        public let pageSize: Int
        public let pageOffset: Int
        public let currentCount: Int
        public let totalCount: Int
        
        // MARK: - Initizliation
        
        public init(
            pageSize: Int,
            pageOffset: Int = 0,
            currentCount: Int = 0,
            totalCount: Int = 0
        ) {
            self.pageSize = pageSize
            self.pageOffset = pageOffset
            self.currentCount = currentCount
            self.totalCount = totalCount
        }
    }
    
    // MARK: - ObservedChanges

    /// This type contains the information needed to define what changes should be included when observing
    /// changes to a database
    ///
    /// - Parameters:
    ///   - table: The table whose changes should be observed
    ///   - events: The database events which should be observed
    ///   - columns: The specific columns which should trigger changes (**Note:** These only apply to `update` changes)
    public struct ObservedChanges {
        public let databaseTableName: String
        public let events: [DatabaseEvent.Kind]
        public let columns: [String]
        
        public init<T: TableRecord & ColumnExpressible>(
            table: T.Type,
            events: [DatabaseEvent.Kind] = [.insert, .update, .delete],
            columns: [T.Columns]
        ) {
            self.databaseTableName = table.databaseTableName
            self.events = events
            self.columns = columns.map { $0.name }
        }
    }

    // MARK: - TrackedChange

    public struct TrackedChange: Hashable {
        let tableName: String
        let kind: DatabaseEvent.Kind
        let rowId: Int64
        
        init(event: DatabaseEvent) {
            self.tableName = event.tableName
            self.kind = event.kind
            self.rowId = event.rowID
        }
    }
    
    // MARK: - Internal Functions
    
    fileprivate static func index<ID: SQLExpressible>(
        _ db: Database,
        for id: ID,
        tableName: String,
        idColumn: String,
        requiredJoinSQL: SQL? = nil,
        orderSQL: SQL,
        filterSQL: SQL,
        joinToPagedType: SQL? = nil
    ) -> Int? {
        let tableNameLiteral: SQL = SQL(stringLiteral: tableName)
        let idColumnLiteral: SQL = SQL(stringLiteral: idColumn)
        let request: SQLRequest<Int> = """
            SELECT
                (data.rowIndex - 1) AS rowIndex -- Converting from 1-Indexed to 0-indexed
            FROM (
                SELECT
                    \(tableNameLiteral).\(idColumnLiteral) AS \(idColumnLiteral),
                    ROW_NUMBER() OVER (ORDER BY \(orderSQL)) AS rowIndex
                FROM \(tableNameLiteral)
                \(requiredJoinSQL ?? "")
                \(joinToPagedType ?? "")
                WHERE \(filterSQL)
            ) AS data
            WHERE \(SQL("data.\(idColumnLiteral) = \(id)"))
        """
        
        return try? request.fetchOne(db)
    }

    /// Returns the indexes the requested rowIds will have in the paged query
    ///
    /// **Note:** If the `associatedRecord` is null then the index for the rowId of the paged data type will be returned
    fileprivate static func indexes(
        _ db: Database,
        rowIds: [Int64],
        tableName: String,
        requiredJoinSQL: SQL? = nil,
        orderSQL: SQL,
        filterSQL: SQL,
        joinToPagedType: SQL? = nil
    ) -> [Int64] {
        let tableNameLiteral: SQL = SQL(stringLiteral: tableName)
        let request: SQLRequest<Int64> = """
            SELECT
                (data.rowIndex - 1) AS rowIndex -- Converting from 1-Indexed to 0-indexed
            FROM (
                SELECT
                    \(tableNameLiteral).rowid AS rowid,
                    ROW_NUMBER() OVER (ORDER BY \(orderSQL)) AS rowIndex
                FROM \(tableNameLiteral)
                \(requiredJoinSQL ?? "")
                \(joinToPagedType ?? "")
                WHERE \(filterSQL)
            ) AS data
            WHERE \(SQL("data.rowid IN \(rowIds)"))
        """
        
        return (try? request.fetchAll(db))
            .defaulting(to: [])
    }
    
    /// Returns the rowIds for the associated types based on the specified pagedTypeRowIds
    fileprivate static func associatedRowIds(
        _ db: Database,
        tableName: String,
        pagedTableName: String,
        pagedTypeRowIds: [Int64],
        joinToPagedType: SQL
    ) -> [Int64] {
        let tableNameLiteral: SQL = SQL(stringLiteral: tableName)
        let pagedTableNameLiteral: SQL = SQL(stringLiteral: pagedTableName)
        let request: SQLRequest<Int64> = """
            SELECT \(tableNameLiteral).rowid AS rowid
            FROM \(tableNameLiteral)
            \(joinToPagedType)
            WHERE \(pagedTableNameLiteral).rowId IN \(pagedTypeRowIds)
        """
        
        return (try? request.fetchAll(db))
            .defaulting(to: [])
    }
}

// MARK: - AssociatedRecord

public class AssociatedRecord<T, PagedType>: ErasedAssociatedRecord where T: FetchableRecordWithRowId & Identifiable, PagedType: FetchableRecordWithRowId & Identifiable {
    public let databaseTableName: String
    public let observedChanges: [PagedData.ObservedChanges]
    public let joinToPagedType: SQL
    
    fileprivate let dataCache: Atomic<DataCache<T>> = Atomic(DataCache())
    fileprivate let dataQuery: (SQL?) -> AdaptedFetchRequest<SQLRequest<T>>
    fileprivate let associateData: (DataCache<T>, DataCache<PagedType>) -> DataCache<PagedType>
    
    // MARK: - Initialization
    
    public init<Table: TableRecord>(
        trackedAgainst: Table.Type,
        observedChanges: [PagedData.ObservedChanges],
        dataQuery: @escaping (SQL?) -> AdaptedFetchRequest<SQLRequest<T>>,
        joinToPagedType: SQL,
        associateData: @escaping (DataCache<T>, DataCache<PagedType>) -> DataCache<PagedType>
    ) {
        self.databaseTableName = trackedAgainst.databaseTableName
        self.observedChanges = observedChanges
        self.dataQuery = dataQuery
        self.joinToPagedType = joinToPagedType
        self.associateData = associateData
    }
    
    convenience init<Table: TableRecord>(
        trackedAgainst: Table.Type,
        observedChanges: [PagedData.ObservedChanges],
        dataQuery: @escaping (SQL?) -> SQLRequest<T>,
        joinToPagedType: SQL,
        associateData: @escaping (DataCache<T>, DataCache<PagedType>) -> DataCache<PagedType>
    ) {
        self.init(
            trackedAgainst: trackedAgainst,
            observedChanges: observedChanges,
            dataQuery: { additionalFilters in
                dataQuery(additionalFilters).adapted { _ in ScopeAdapter([:]) }
            },
            joinToPagedType: joinToPagedType,
            associateData: associateData
        )
    }
    
    // MARK: - AssociatedRecord
    
    public func tryUpdateForDatabaseCommit(
        _ db: Database,
        changes: Set<PagedData.TrackedChange>,
        orderSQL: SQL,
        filterSQL: SQL,
        pageInfo: PagedData.PageInfo
    ) -> Bool {
        // Ignore any changes which aren't relevant to this type
        let relevantChanges: Set<PagedData.TrackedChange> = changes
            .filter { $0.tableName == databaseTableName }
        
        guard !relevantChanges.isEmpty else { return false }
        
        // First remove any items which have been deleted
        let oldCount: Int = self.dataCache.wrappedValue.count
        let deletionChanges: [Int64] = relevantChanges
            .filter { $0.kind == .delete }
            .map { $0.rowId }
        
        dataCache.mutate { $0 = $0.deleting(rowIds: deletionChanges) }
        
        // Get an updated count to avoid locking the dataCache unnecessarily
        let countAfterDeletions: Int = self.dataCache.wrappedValue.count
        
        // If there are no inserted/updated rows then trigger the update callback and stop here
        let rowIdsToQuery: [Int64] = relevantChanges
            .filter { $0.kind != .delete }
            .map { $0.rowId }
        
        guard !rowIdsToQuery.isEmpty else { return (oldCount != countAfterDeletions) }
        
        // Fetch the indexes of the rowIds so we can determine whether they should be added to the screen
        let itemIndexes: [Int64] = PagedData.indexes(
            db,
            rowIds: rowIdsToQuery,
            tableName: databaseTableName,
            orderSQL: orderSQL,
            filterSQL: filterSQL,
            joinToPagedType: joinToPagedType
        )
        
        // Determine if the indexes for the row ids should be displayed on the screen and remove any
        // which shouldn't - values less than 'currentCount' or if there is at least one value less than
        // 'currentCount' and the indexes are sequential (ie. more than the current loaded content was
        // added at once)
        let itemIndexesAreSequential: Bool = (itemIndexes.map { $0 - 1 }.dropFirst() == itemIndexes.dropLast())
        let hasOneValidIndex: Bool = itemIndexes.contains(where: { $0 < pageInfo.currentCount })
        let validRowIds: [Int64] = (itemIndexesAreSequential && hasOneValidIndex ?
            itemIndexes :
            zip(itemIndexes, rowIdsToQuery)
                .filter { index, _ -> Bool in index < pageInfo.currentCount }
                .map { _, rowId -> Int64 in rowId }
        )

        // Attempt to update the cache with the `validRowIds` array
        return updateCache(
            db,
            rowIds: validRowIds,
            hasOtherChanges: (oldCount != countAfterDeletions)
        )
    }
    
    @discardableResult public func updateCache(_ db: Database, rowIds: [Int64], hasOtherChanges: Bool = false) -> Bool {
        // If there are no rowIds then stop here
        guard !rowIds.isEmpty else { return hasOtherChanges }
        
        // Fetch the inserted/updated rows
        let additionalFilters: SQL = SQL(rowIds.contains(Column.rowID))
        let updatedItems: [T] = (try? dataQuery(additionalFilters)
            .fetchAll(db))
            .defaulting(to: [])
        
        // If the inserted/updated rows we irrelevant (eg. associated to another thread, a quote or a link
        // preview) then trigger the update callback (if there were deletions) and stop here
        guard !updatedItems.isEmpty else { return hasOtherChanges }
        
        // Process the upserted data (assume at least one value changed)
        dataCache.mutate { $0 = $0.upserting(items: updatedItems) }
        
        return true
    }
    
    public func attachAssociatedData<O>(to unassociatedCache: DataCache<O>) -> DataCache<O> {
        guard let typedCache: DataCache<PagedType> = unassociatedCache as? DataCache<PagedType> else {
            return unassociatedCache
        }
        
        return (associateData(dataCache.wrappedValue, typedCache) as? DataCache<O>)
            .defaulting(to: unassociatedCache)
    }
}