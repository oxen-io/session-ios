// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class PhotoCollectionPickerViewModel: SessionTableViewModel, ObservableTableSource {
    typealias TableItem = String
    
    public let dependencies: Dependencies
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private let library: PhotoLibrary
    private let onCollectionSelected: (PhotoCollection) -> Void
    private var photoCollections: CurrentValueSubject<[PhotoCollection], Error>

    // MARK: - Initialization

    init(
        library: PhotoLibrary,
        onCollectionSelected: @escaping (PhotoCollection) -> Void,
        using dependencies: Dependencies = Dependencies()
    ) {
        self.dependencies = dependencies
        self.library = library
        self.onCollectionSelected = onCollectionSelected
        self.photoCollections = CurrentValueSubject(library.allPhotoCollections())
    }
    
    // MARK: - Config
    
    public enum Section: SessionTableSection {
        case content
    }

    // MARK: - Content

    let title: String = "NOTIFICATIONS_STYLE_SOUND_TITLE".localized()
    
    lazy var observation: TargetObservation = ObservationBuilder
        .subject(photoCollections)
        .map { collections -> [SectionModel] in
            [
                SectionModel(
                    model: .content,
                    elements: collections.map { collection in
                        let contents: PhotoCollectionContents = collection.contents()
                        let photoMediaSize: PhotoMediaSize = PhotoMediaSize(
                            thumbnailSize: CGSize(
                                width: IconSize.extraLarge.size,
                                height: IconSize.extraLarge.size
                            )
                        )
                        let lastAssetItem: PhotoPickerAssetItem? = contents.lastAssetItem(photoMediaSize: photoMediaSize)
                        
                        return SessionCell.Info(
                            id: collection.id,
                            leadingAccessory: .iconAsync(size: .extraLarge, shouldFill: true) { imageView in
                                // Note: We need to capture 'lastAssetItem' otherwise it'll be released and we won't
                                // be able to load the thumbnail
                                lastAssetItem?.asyncThumbnail { [weak imageView] image in
                                    imageView?.image = image
                                }
                            },
                            title: collection.localizedTitle(),
                            subtitle: "\(contents.assetCount)",
                            onTap: { [weak self] in
                                self?.onCollectionSelected(collection)
                            }
                        )
                    }
                )
            ]
        }
    
    // MARK: PhotoLibraryDelegate

    func photoLibraryDidChange(_ photoLibrary: PhotoLibrary) {
        self.photoCollections.send(library.allPhotoCollections())
    }
}
