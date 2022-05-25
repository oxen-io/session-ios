// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SignalUtilitiesKit
import SessionUtilitiesKit

public class MediaGalleryViewModel {
    public typealias SectionModel = ArraySection<Section, Item>
    
    // MARK: - Section
    
    public enum Section: Differentiable, Equatable, Comparable, Hashable {
        case emptyGallery
        case loadOlder
        case galleryMonth(date: GalleryDate)
        case loadNewer
    }
    
    public let threadId: String
    public let threadVariant: SessionThread.Variant
    private var focusedAttachmentId: String?
    public private(set) var focusedIndexPath: IndexPath?
    
    /// This value is the current state of an album view
    private var cachedInteractionIdBefore: Atomic<[Int64: Int64]> = Atomic([:])
    private var cachedInteractionIdAfter: Atomic<[Int64: Int64]> = Atomic([:])
    
    public var interactionIdBefore: [Int64: Int64] { cachedInteractionIdBefore.wrappedValue }
    public var interactionIdAfter: [Int64: Int64] { cachedInteractionIdAfter.wrappedValue }
    public private(set) var albumData: [Int64: [Item]] = [:]
    public private(set) var pagedDatabaseObserver: PagedDatabaseObserver<Attachment, Item>?
    
    /// This value is the current state of a gallery view
    public private(set) var galleryData: [SectionModel] = []
    public var onGalleryChange: (([SectionModel]) -> ())?
    
    // MARK: - Initialization
    
    init(
        threadId: String,
        threadVariant: SessionThread.Variant,
        isPagedData: Bool,
        pageSize: Int = 1,
        focusedAttachmentId: String? = nil
    ) {
        self.threadId = threadId
        self.threadVariant = threadVariant
        self.focusedAttachmentId = focusedAttachmentId
        self.pagedDatabaseObserver = nil
        
        guard isPagedData else { return }
     
        var hasSavedIntialUpdate: Bool = false
        let filterSQL: SQL = Item.filterSQL(threadId: threadId)
        self.pagedDatabaseObserver = PagedDatabaseObserver(
            pagedTable: Attachment.self,
            pageSize: pageSize,
            idColumn: .id,
            initialFocusedId: focusedAttachmentId,
            observedChanges: [
                PagedData.ObservedChanges(
                    table: Attachment.self,
                    columns: [.isValid]
                )
            ],
            joinSQL: Item.joinSQL,
            filterSQL: filterSQL,
            orderSQL: Item.galleryOrderSQL,
            dataQuery: Item.baseQuery(orderSQL: Item.galleryOrderSQL, baseFilterSQL: filterSQL),
            onChangeUnsorted: { [weak self] updatedData, updatedPageInfo in
                guard let updatedGalleryData: [SectionModel] = self?.process(data: updatedData, for: updatedPageInfo) else {
                    return
                }
                
                // If we haven't stored the data for the initial fetch then do so now (no need
                // to call 'onGalleryChange' in this case as it will always be null)
                guard hasSavedIntialUpdate else {
                    self?.updateGalleryData(updatedGalleryData)
                    hasSavedIntialUpdate = true
                    return
                }
                
                self?.onGalleryChange?(updatedGalleryData)
            }
        )
    }
    
    // MARK: - Data
    
    public struct GalleryDate: Differentiable, Equatable, Comparable, Hashable {
        private static let thisYearFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM"

            return formatter
        }()

        private static let olderFormatter: DateFormatter = {
            // FIXME: localize for RTL, or is there a built in way to do this?
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM yyyy"

            return formatter
        }()
        
        let year: Int
        let month: Int
        
        private var date: Date? {
            var components = DateComponents()
            components.month = self.month
            components.year = self.year

            return Calendar.current.date(from: components)
        }

        var localizedString: String {
            let isSameMonth: Bool = (self.month == Calendar.current.component(.month, from: Date()))
            let isCurrentYear: Bool = (self.year == Calendar.current.component(.year, from: Date()))
            let galleryDate: Date = (self.date ?? Date())
            
            switch (isSameMonth, isCurrentYear) {
                case (true, true): return "MEDIA_GALLERY_THIS_MONTH_HEADER".localized()
                case (false, true): return GalleryDate.thisYearFormatter.string(from: galleryDate)
                default: return GalleryDate.olderFormatter.string(from: galleryDate)
            }
        }
        
        // MARK: - --Initialization

        init(messageDate: Date) {
            self.year = Calendar.current.component(.year, from: messageDate)
            self.month = Calendar.current.component(.month, from: messageDate)
        }

        // MARK: - --Comparable

        public static func < (lhs: GalleryDate, rhs: GalleryDate) -> Bool {
            switch ((lhs.year != rhs.year), (lhs.month != rhs.month)) {
                case (true, _): return lhs.year < rhs.year
                case (_, true): return lhs.month < rhs.month
                default: return false
            }
        }
    }
    
    public struct Item: FetchableRecordWithRowId, Decodable, Identifiable, Differentiable, Equatable, Hashable {
        fileprivate static let interactionIdKey: SQL = SQL(stringLiteral: CodingKeys.interactionId.stringValue)
        fileprivate static let interactionVariantKey: SQL = SQL(stringLiteral: CodingKeys.interactionVariant.stringValue)
        fileprivate static let interactionAuthorIdKey: SQL = SQL(stringLiteral: CodingKeys.interactionAuthorId.stringValue)
        fileprivate static let interactionTimestampMsKey: SQL = SQL(stringLiteral: CodingKeys.interactionTimestampMs.stringValue)
        fileprivate static let rowIdKey: SQL = SQL(stringLiteral: CodingKeys.rowId.stringValue)
        fileprivate static let attachmentKey: SQL = SQL(stringLiteral: CodingKeys.attachment.stringValue)
        fileprivate static let attachmentAlbumIndexKey: SQL = SQL(stringLiteral: CodingKeys.attachmentAlbumIndex.stringValue)
        
        fileprivate static let attachmentString: String = CodingKeys.attachment.stringValue
        
        public var id: String { attachment.id }
        public var differenceIdentifier: String { attachment.id }
        
        let interactionId: Int64
        let interactionVariant: Interaction.Variant
        let interactionAuthorId: String
        let interactionTimestampMs: Int64
        
        public var rowId: Int64
        let attachmentAlbumIndex: Int
        let attachment: Attachment
        
        var galleryDate: GalleryDate {
            GalleryDate(
                messageDate: Date(timeIntervalSince1970: (Double(interactionTimestampMs) / 1000))
            )
        }
        
        var isVideo: Bool { attachment.isVideo }
        var isAnimated: Bool { attachment.isAnimated }
        var isImage: Bool { attachment.isImage }

        var imageSize: CGSize {
            guard let width: UInt = attachment.width, let height: UInt = attachment.height else {
                return .zero
            }
            
            return CGSize(width: Int(width), height: Int(height))
        }
        
        var captionForDisplay: String? { attachment.caption?.filterForDisplay }
        
        // MARK: - Query
        
        fileprivate static let joinSQL: SQL = {
            let attachment: TypedTableAlias<Attachment> = TypedTableAlias()
            let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
            let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
            
            return """
                JOIN \(InteractionAttachment.self) ON \(interactionAttachment[.attachmentId]) = \(attachment[.id])
                JOIN \(Interaction.self) ON \(interaction[.id]) = \(interactionAttachment[.interactionId])
            """
        }()
        
        fileprivate static func filterSQL(threadId: String) -> SQL {
            let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
            let attachment: TypedTableAlias<Attachment> = TypedTableAlias()
            
            return SQL("""
                \(attachment[.isVisualMedia]) = true AND
                \(attachment[.isValid]) = true AND
                \(interaction[.threadId]) = \(threadId)
            """)
        }
        
        fileprivate static let galleryOrderSQL: SQL = {
            let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
            let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
            
            /// **Note:** This **MUST** match the desired sort behaviour for the screen otherwise paging will be
            /// very broken
            return SQL("\(interaction[.timestampMs].desc), \(interactionAttachment[.albumIndex])")
        }()
        
        fileprivate static let galleryReverseOrderSQL: SQL = {
            let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
            let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
            
            /// **Note:** This **MUST** match the desired sort behaviour for the screen otherwise paging will be
            /// very broken
            return SQL("\(interaction[.timestampMs]), \(interactionAttachment[.albumIndex].desc)")
        }()
        
        fileprivate static func baseQuery(orderSQL: SQL, baseFilterSQL: SQL) -> ((SQL?, SQL?) -> AdaptedFetchRequest<SQLRequest<Item>>) {
            return { additionalFilters, limitSQL -> AdaptedFetchRequest<SQLRequest<Item>> in
                let attachment: TypedTableAlias<Attachment> = TypedTableAlias()
                let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
                
                let finalFilterSQL: SQL = {
                    guard let additionalFilters: SQL = additionalFilters else {
                        return """
                            WHERE (
                                \(baseFilterSQL)
                            )
                        """
                    }

                    return """
                        WHERE (
                            \(baseFilterSQL) AND
                            \(additionalFilters)
                        )
                    """
                }()
                let finalLimitSQL: SQL = (limitSQL ?? SQL(stringLiteral: ""))
                let numColumnsBeforeLinkedRecords: Int = 6
                let request: SQLRequest<Item> = """
                    SELECT
                        \(interaction[.id]) AS \(Item.interactionIdKey),
                        \(interaction[.variant]) AS \(Item.interactionVariantKey),
                        \(interaction[.authorId]) AS \(Item.interactionAuthorIdKey),
                        \(interaction[.timestampMs]) AS \(Item.interactionTimestampMsKey),

                        \(attachment.alias[Column.rowID]) AS \(Item.rowIdKey),
                        \(interactionAttachment[.albumIndex]) AS \(Item.attachmentAlbumIndexKey),
                        \(Item.attachmentKey).*
                    FROM \(Attachment.self)
                    \(joinSQL)
                    \(finalFilterSQL)
                    ORDER BY \(orderSQL)
                    \(finalLimitSQL)
                """
                
                return request.adapted { db in
                    let adapters = try splittingRowAdapters(columnCounts: [
                        numColumnsBeforeLinkedRecords,
                        Attachment.numberOfSelectedColumns(db)
                    ])

                    return ScopeAdapter([
                        Item.attachmentString: adapters[1]
                    ])
                }
            }
        }
        
        fileprivate static func baseQuery(orderSQL: SQL, baseFilterSQL: SQL) -> AdaptedFetchRequest<SQLRequest<Item>> {
            return Item.baseQuery(orderSQL: orderSQL, baseFilterSQL: baseFilterSQL)(nil, nil)
        }

        func thumbnailImage(async: @escaping (UIImage) -> ()) {
            attachment.thumbnail(size: .small, success: { image, _ in async(image) }, failure: {})
        }
    }
    
    // MARK: - Album
    
    /// This is all the data the screen needs to populate itself, please see the following link for tips to help optimise
    /// performance https://github.com/groue/GRDB.swift#valueobservation-performance
    ///
    /// **Note:** The 'trackingConstantRegion' is optimised in such a way that the request needs to be static
    /// otherwise there may be situations where it doesn't get updates, this means we can't have conditional queries
    public typealias AlbumObservation = ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<[Item]>>>
    public lazy var observableAlbumData: AlbumObservation = buildAlbumObservation(for: nil)
    
    private func buildAlbumObservation(for interactionId: Int64?) -> AlbumObservation {
        return ValueObservation
            .trackingConstantRegion { db -> [Item] in
                guard let interactionId: Int64 = interactionId else { return [] }
                
                let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
                
                return try Item
                    .baseQuery(
                        orderSQL: SQL(interactionAttachment[.albumIndex]),
                        baseFilterSQL: SQL("\(interaction[.id]) = \(interactionId)")
                    )
                    .fetchAll(db)
            }
            .removeDuplicates()
    }
    
    @discardableResult public func loadAndCacheAlbumData(for interactionId: Int64) -> [Item] {
        typealias AlbumInfo = (albumData: [Item], interactionIdBefore: Int64?, interactionIdAfter: Int64?)
        
        // Note: It's possible we already have cached album data for this interaction
        // but to avoid displaying stale data we re-fetch from the database anyway
        let maybeAlbumInfo: AlbumInfo? = GRDBStorage.shared
            .read { db -> AlbumInfo in
                let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
                
                let newAlbumData: [Item] = try Item
                    .baseQuery(
                        orderSQL: SQL(interactionAttachment[.albumIndex]),
                        baseFilterSQL: SQL("\(interaction[.id]) = \(interactionId)")
                    )
                    .fetchAll(db)
                
                guard let albumTimestampMs: Int64 = newAlbumData.first?.interactionTimestampMs else {
                    return (newAlbumData, nil, nil)
                }
                
                let itemBefore: Item? = try Item
                    .baseQuery(
                        orderSQL: Item.galleryReverseOrderSQL,
                        baseFilterSQL: SQL("\(interaction[.timestampMs]) > \(albumTimestampMs)")
                    )
                    .fetchOne(db)
                let itemAfter: Item? = try Item
                    .baseQuery(
                        orderSQL: Item.galleryOrderSQL,
                        baseFilterSQL: SQL("\(interaction[.timestampMs]) < \(albumTimestampMs)")
                    )
                    .fetchOne(db)
                
                return (newAlbumData, itemBefore?.interactionId, itemAfter?.interactionId)
            }
        
        guard let newAlbumInfo: AlbumInfo = maybeAlbumInfo else { return [] }
        
        // Cache the album info for the new interactionId
        self.updateAlbumData(newAlbumInfo.albumData, for: interactionId)
        self.cachedInteractionIdBefore.mutate { $0[interactionId] = newAlbumInfo.interactionIdBefore }
        self.cachedInteractionIdAfter.mutate { $0[interactionId] = newAlbumInfo.interactionIdAfter }
        
        return newAlbumInfo.albumData
    }
    
    public func replaceAlbumObservation(toObservationFor interactionId: Int64) {
        self.observableAlbumData = self.buildAlbumObservation(for: interactionId)
    }
    
    public func updateAlbumData(_ updatedData: [Item], for interactionId: Int64) {
        self.albumData[interactionId] = updatedData
    }
    
    // MARK: - Gallery
    
    private func process(data: [Item], for pageInfo: PagedData.PageInfo) -> [SectionModel] {
        let galleryData: [SectionModel] = data
            .grouped(by: \.galleryDate)
            .mapValues { sectionItems -> [Item] in
                sectionItems
                    .sorted { lhs, rhs -> Bool in
                        if lhs.interactionTimestampMs == rhs.interactionTimestampMs {
                            // Start of album first
                            return (lhs.attachmentAlbumIndex < rhs.attachmentAlbumIndex)
                        }
                        
                        // Newer interactions first
                        return (lhs.interactionTimestampMs > rhs.interactionTimestampMs)
                    }
            }
            .map { galleryDate, items in
                SectionModel(model: .galleryMonth(date: galleryDate), elements: items)
            }
        
        // Remove and re-add the custom sections as needed
        return [
            (data.isEmpty ? [SectionModel(section: .emptyGallery)] : []),
            (!data.isEmpty && pageInfo.pageOffset > 0 ? [SectionModel(section: .loadNewer)] : []),
            galleryData,
            (!data.isEmpty && (pageInfo.pageOffset + pageInfo.currentCount) < pageInfo.totalCount ?
                [SectionModel(section: .loadOlder)] :
                []
            )
        ]
        .flatMap { $0 }
        .sorted { lhs, rhs -> Bool in (lhs.model > rhs.model) }
    }
    
    public func updateGalleryData(_ updatedData: [SectionModel]) {
        self.galleryData = updatedData
        
        // If we have a focused attachment id then we need to make sure the 'focusedIndexPath'
        // is updated to be accurate
        if let focusedAttachmentId: String = focusedAttachmentId {
            self.focusedIndexPath = nil
            
            for (section, sectionData) in updatedData.enumerated() {
                for (index, item) in sectionData.elements.enumerated() {
                    if item.attachment.id == focusedAttachmentId {
                        self.focusedIndexPath = IndexPath(item: index, section: section)
                        break
                    }
                }
                
                if self.focusedIndexPath != nil { break }
            }
        }
    }
    
    public func loadNewerGalleryItems() {
        self.pagedDatabaseObserver?.load(.pageBefore)
    }
    
    public func loadOlderGalleryItems() {
        self.pagedDatabaseObserver?.load(.pageAfter)
    }
    
    public func updateFocusedItem(attachmentId: String, indexPath: IndexPath) {
        // Note: We need to set both of these as the 'focusedIndexPath' is usually
        // derived and if the data changes it will be regenerated using the
        // 'focusedAttachmentId' value
        self.focusedAttachmentId = attachmentId
        self.focusedIndexPath = indexPath
    }
    
    // MARK: - Creation Functions
    
    public static func createDetailViewController(
        for threadId: String,
        threadVariant: SessionThread.Variant,
        interactionId: Int64,
        selectedAttachmentId: String,
        options: [MediaGalleryOption]
    ) -> UIViewController? {
        // Load the data for the album immediately (needed before pushing to the screen so
        // transitions work nicely)
        let viewModel: MediaGalleryViewModel = MediaGalleryViewModel(
            threadId: threadId,
            threadVariant: threadVariant,
            isPagedData: false
        )
        viewModel.loadAndCacheAlbumData(for: interactionId)
        viewModel.replaceAlbumObservation(toObservationFor: interactionId)
        
        guard
            !viewModel.albumData.isEmpty,
            let initialItem: Item = viewModel.albumData[interactionId]?.first(where: { item -> Bool in
                item.attachment.id == selectedAttachmentId
            })
        else { return nil }
        
        let pageViewController: MediaPageViewController = MediaPageViewController(
            viewModel: viewModel,
            initialItem: initialItem,
            options: options
        )
        let navController: MediaGalleryNavigationController = MediaGalleryNavigationController()
        navController.viewControllers = [pageViewController]
        navController.modalPresentationStyle = .fullScreen
        navController.transitioningDelegate = pageViewController
        
        return navController
    }
    
    public static func createTileViewController(
        threadId: String,
        threadVariant: SessionThread.Variant,
        focusedAttachmentId: String?
    ) -> MediaTileViewController {
        let viewModel: MediaGalleryViewModel = MediaGalleryViewModel(
            threadId: threadId,
            threadVariant: threadVariant,
            isPagedData: true,
            pageSize: MediaTileViewController.itemPageSize,
            focusedAttachmentId: focusedAttachmentId
        )
        
        return MediaTileViewController(
            viewModel: viewModel
        )
    }
}

// MARK: - Objective-C Support

// FIXME: Remove when we can

@objc(SNMediaGallery)
public class SNMediaGallery: NSObject {
    @objc(pushTileViewWithSliderEnabledForThreadId:isClosedGroup:isOpenGroup:fromNavController:)
    static func pushTileView(threadId: String, isClosedGroup: Bool, isOpenGroup: Bool, fromNavController: OWSNavigationController) {
        fromNavController.pushViewController(
            MediaGalleryViewModel.createTileViewController(
                threadId: threadId,
                threadVariant: {
                    if isClosedGroup { return .closedGroup }
                    if isOpenGroup { return .openGroup }

                    return .contact
                }(),
                focusedAttachmentId: nil
            ),
            animated: true
        )
    }
}