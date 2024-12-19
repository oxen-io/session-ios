// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import Photos
import CoreServices
import UniformTypeIdentifiers
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

protocol PhotoLibraryDelegate: AnyObject {
    func photoLibraryDidChange(_ photoLibrary: PhotoLibrary)
}

class PhotoMediaSize {
    var thumbnailSize: CGSize

    init() {
        self.thumbnailSize = .zero
    }

    init(thumbnailSize: CGSize) {
        self.thumbnailSize = thumbnailSize
    }
}

class PhotoPickerAssetItem: PhotoGridItem {

    let asset: PHAsset
    let photoCollectionContents: PhotoCollectionContents
    let photoMediaSize: PhotoMediaSize

    init(asset: PHAsset, photoCollectionContents: PhotoCollectionContents, photoMediaSize: PhotoMediaSize) {
        self.asset = asset
        self.photoCollectionContents = photoCollectionContents
        self.photoMediaSize = photoMediaSize
    }

    // MARK: PhotoGridItem

    var type: PhotoGridItemType {
        if asset.mediaType == .video {
            return .video
        }

        // TODO show GIF badge?

        return  .photo
    }

    func asyncThumbnail(completion: @escaping (UIImage?) -> Void) {
        var hasLoadedImage = false

        // Surprisingly, iOS will opportunistically run the completion block sync if the image is
        // already available.
        photoCollectionContents.requestThumbnail(for: self.asset, thumbnailSize: photoMediaSize.thumbnailSize) { image, _ in
            Threading.dispatchMainThreadSafe {
                // Once we've _successfully_ completed (e.g. invoked the completion with
                // a non-nil image), don't invoke the completion again with a nil argument.
                if !hasLoadedImage || image != nil {
                    completion(image)

                    if image != nil {
                        hasLoadedImage = true
                    }
                }
            }
        }
    }
}

class PhotoCollectionContents {

    let fetchResult: PHFetchResult<PHAsset>
    let localizedTitle: String?

    enum PhotoLibraryError: Error {
        case assertionError(description: String)
        case unsupportedMediaType
    }

    init(fetchResult: PHFetchResult<PHAsset>, localizedTitle: String?) {
        self.fetchResult = fetchResult
        self.localizedTitle = localizedTitle
    }

    private let imageManager = PHCachingImageManager()

    // MARK: - Asset Accessors

    var assetCount: Int {
        return fetchResult.count
    }

    var lastAsset: PHAsset? {
        guard assetCount > 0 else {
            return nil
        }
        return asset(at: assetCount - 1)
    }

    var firstAsset: PHAsset? {
        guard assetCount > 0 else {
            return nil
        }
        return asset(at: 0)
    }

    func asset(at index: Int) -> PHAsset? {
        guard index >= 0 && index < fetchResult.count else { return nil }
        
        return fetchResult.object(at: index)
    }

    // MARK: - AssetItem Accessors

    func assetItem(at index: Int, photoMediaSize: PhotoMediaSize) -> PhotoPickerAssetItem? {
        guard let mediaAsset: PHAsset = asset(at: index) else { return nil }
        
        return PhotoPickerAssetItem(asset: mediaAsset, photoCollectionContents: self, photoMediaSize: photoMediaSize)
    }

    func firstAssetItem(photoMediaSize: PhotoMediaSize) -> PhotoPickerAssetItem? {
        guard let mediaAsset = firstAsset else { return nil }
        
        return PhotoPickerAssetItem(asset: mediaAsset, photoCollectionContents: self, photoMediaSize: photoMediaSize)
    }

    func lastAssetItem(photoMediaSize: PhotoMediaSize) -> PhotoPickerAssetItem? {
        guard let mediaAsset = lastAsset else { return nil }
        
        return PhotoPickerAssetItem(asset: mediaAsset, photoCollectionContents: self, photoMediaSize: photoMediaSize)
    }

    // MARK: ImageManager

    func requestThumbnail(for asset: PHAsset, thumbnailSize: CGSize, resultHandler: @escaping (UIImage?, [AnyHashable: Any]?) -> Void) {
        _ = imageManager.requestImage(for: asset, targetSize: thumbnailSize, contentMode: .aspectFill, options: nil, resultHandler: resultHandler)
    }

    private func requestImageDataSource(for asset: PHAsset, using dependencies: Dependencies) -> AnyPublisher<(dataSource: (any DataSource), type: UTType), Error> {
        return Deferred {
            Future { [weak self] resolver in
                let options: PHImageRequestOptions = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                
                _ = self?.imageManager.requestImageData(for: asset, options: options) { imageData, dataUTI, orientation, info in
                    
                    guard let imageData = imageData else {
                        resolver(Result.failure(PhotoLibraryError.assertionError(description: "imageData was unexpectedly nil")))
                        return
                    }
                    
                    guard let type: UTType = dataUTI.map({ UTType($0) }) else {
                        resolver(Result.failure(PhotoLibraryError.assertionError(description: "dataUTI was unexpectedly nil")))
                        return
                    }
                    
                    guard let dataSource = DataSourceValue(data: imageData, dataType: type, using: dependencies) else {
                        resolver(Result.failure(PhotoLibraryError.assertionError(description: "dataSource was unexpectedly nil")))
                        return
                    }
                    
                    resolver(Result.success((dataSource: dataSource, type: type)))
                }
            }
        }
        .eraseToAnyPublisher()
    }

    private func requestVideoDataSource(for asset: PHAsset, using dependencies: Dependencies) -> AnyPublisher<(dataSource: (any DataSource), type: UTType), Error> {
        return Deferred {
            Future { [weak self] resolver in
                let options: PHVideoRequestOptions = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = true
                
                _ = self?.imageManager.requestExportSession(forVideo: asset, options: options, exportPreset: AVAssetExportPresetMediumQuality) { exportSession, foo in
                    
                    guard let exportSession = exportSession else {
                        resolver(Result.failure(PhotoLibraryError.assertionError(description: "exportSession was unexpectedly nil")))
                        return
                    }
                    
                    exportSession.outputFileType = AVFileType.mp4
                    exportSession.metadataItemFilter = AVMetadataItemFilter.forSharing()
                    
                    let exportPath = dependencies[singleton: .fileManager].temporaryFilePath(fileExtension: "mp4") // stringlint:ignore
                    let exportURL = URL(fileURLWithPath: exportPath)
                    exportSession.outputURL = exportURL
                    
                    Log.debug("[PhotoLibrary] Starting video export")
                    exportSession.exportAsynchronously { [weak exportSession] in
                        Log.debug("[PhotoLibrary] Completed video export")
                        
                        guard
                            exportSession?.status == .completed,
                            let dataSource = DataSourcePath(fileUrl: exportURL, sourceFilename: nil, shouldDeleteOnDeinit: true, using: dependencies)
                        else {
                            resolver(Result.failure(PhotoLibraryError.assertionError(description: "Failed to build data source for exported video URL")))
                            return
                        }
                        
                        resolver(Result.success((dataSource: dataSource, type: .mpeg4Movie)))
                    }
                }
            }
        }
        .eraseToAnyPublisher()
    }

    func outgoingAttachment(for asset: PHAsset, using dependencies: Dependencies) -> AnyPublisher<SignalAttachment, Error> {
        switch asset.mediaType {
            case .image:
                return requestImageDataSource(for: asset, using: dependencies)
                    .map { (dataSource: DataSource, type: UTType) in
                        SignalAttachment.attachment(dataSource: dataSource, type: type, imageQuality: .medium, using: dependencies)
                    }
                    .eraseToAnyPublisher()
                
            case .video:
                return requestVideoDataSource(for: asset, using: dependencies)
                    .map { (dataSource: DataSource, type: UTType) in
                        SignalAttachment.attachment(dataSource: dataSource, type: type, using: dependencies)
                    }
                    .eraseToAnyPublisher()
                
            default:
                return Fail(error: PhotoLibraryError.unsupportedMediaType)
                    .eraseToAnyPublisher()
        }
    }
}

class PhotoCollection {
    public let id: String
    private let collection: PHAssetCollection
    
    // The user never sees this collection, but we use it for a null object pattern
    // when the user has denied photos access.
    static let empty = PhotoCollection(id: "", collection: PHAssetCollection())

    init(id: String, collection: PHAssetCollection) {
        self.id = id
        self.collection = collection
    }

    func localizedTitle() -> String {
        guard let localizedTitle = collection.localizedTitle?.stripped,
            localizedTitle.count > 0 else {
            return "attachmentsAlbumUnnamed".localized()
        }
        return localizedTitle
    }

    // stringlint:ignore_contents
    func contents() -> PhotoCollectionContents {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetchResult = PHAsset.fetchAssets(in: collection, options: options)

        return PhotoCollectionContents(fetchResult: fetchResult, localizedTitle: localizedTitle())
    }
}

extension PhotoCollection: Equatable {
    static func == (lhs: PhotoCollection, rhs: PhotoCollection) -> Bool {
        return lhs.collection == rhs.collection
    }
}

class PhotoLibrary: NSObject, PHPhotoLibraryChangeObserver {
    typealias WeakDelegate = Weak<PhotoLibraryDelegate>
    var delegates = [WeakDelegate]()

    public func add(delegate: PhotoLibraryDelegate) {
        delegates.append(WeakDelegate(value: delegate))
    }

    var assetCollection: PHAssetCollection!

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async {
            for weakDelegate in self.delegates {
                weakDelegate.value?.photoLibraryDidChange(self)
            }
        }
    }

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
    
    // stringlint:ignore_contents
    private lazy var fetchOptions: PHFetchOptions = {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "endDate", ascending: true)]
        return fetchOptions
    }()

    func defaultPhotoCollection() -> PhotoCollection {
        var fetchedCollection: PhotoCollection?
        PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumUserLibrary,
            options: fetchOptions
        ).enumerateObjects { collection, _, stop in
            fetchedCollection = PhotoCollection(id: collection.localIdentifier, collection: collection)
            stop.pointee = true
        }

        guard let photoCollection = fetchedCollection else {
            Log.debug("[PhotoLibrary] Using empty photo collection.")
            Log.assert(PHPhotoLibrary.authorizationStatus() == .denied)
            return PhotoCollection.empty
        }

        return photoCollection
    }

    func allPhotoCollections() -> [PhotoCollection] {
        var collections = [PhotoCollection]()
        var collectionIds = Set<String>()

        let processPHCollection: ((collection: PHCollection, hideIfEmpty: Bool)) -> Void = { arg in
            let (collection, hideIfEmpty) = arg

            // De-duplicate by id.
            let collectionId: String = collection.localIdentifier
            
            guard !collectionIds.contains(collectionId) else { return }
            collectionIds.insert(collectionId)

            guard let assetCollection = collection as? PHAssetCollection else {
                Log.error("[PhotoLibrary] Asset collection has unexpected type: \(type(of: collection))")
                return
            }
            let photoCollection = PhotoCollection(id: collectionId, collection: assetCollection)
            guard !hideIfEmpty || photoCollection.contents().assetCount > 0 else {
                return
            }

            collections.append(photoCollection)
        }
        let processPHAssetCollections: ((fetchResult: PHFetchResult<PHAssetCollection>, hideIfEmpty: Bool)) -> Void = { arg in
            let (fetchResult, hideIfEmpty) = arg

            fetchResult.enumerateObjects { (assetCollection, _, _) in
                // We're already sorting albums by last-updated. "Recently Added" is mostly redundant
                guard assetCollection.assetCollectionSubtype != .smartAlbumRecentlyAdded else {
                    return
                }

                // undocumented constant
                let kRecentlyDeletedAlbumSubtype = PHAssetCollectionSubtype(rawValue: 1000000201)
                guard assetCollection.assetCollectionSubtype != kRecentlyDeletedAlbumSubtype else {
                    return
                }

                processPHCollection((collection: assetCollection, hideIfEmpty: hideIfEmpty))
            }
        }
        let processPHCollections: ((fetchResult: PHFetchResult<PHCollection>, hideIfEmpty: Bool)) -> Void = { arg in
            let (fetchResult, hideIfEmpty) = arg

            for index in 0..<fetchResult.count {
                processPHCollection((collection: fetchResult.object(at: index), hideIfEmpty: hideIfEmpty))
            }
        }
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "endDate", ascending: true)] // stringlint:ignore

        // Try to add "Camera Roll" first.
        processPHAssetCollections((fetchResult: PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: fetchOptions),
                                   hideIfEmpty: false))

        // Favorites
        processPHAssetCollections((fetchResult: PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: fetchOptions),
                                   hideIfEmpty: true))

        // Smart albums.
        processPHAssetCollections((fetchResult: PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .albumRegular, options: fetchOptions),
                                   hideIfEmpty: true))

        // User-created albums.
        processPHCollections((fetchResult: PHAssetCollection.fetchTopLevelUserCollections(with: fetchOptions),
                              hideIfEmpty: true))

        return collections
    }
}
