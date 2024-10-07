// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import UniformTypeIdentifiers
import YYImage
import SessionSnodeKit
import SignalUtilitiesKit
import SessionUtilitiesKit

class GifPickerCell: UICollectionViewCell {

    // MARK: Properties

    var dependencies: Dependencies?
    var imageInfo: GiphyImageInfo? {
        didSet {
            Log.assertOnMainThread()

            ensureCellState()
        }
    }

    // Loading and playing GIFs is quite expensive (network, memory, cpu).
    // Here's a bit of logic to not preload offscreen cells that are prefetched.
    var isCellVisible = false {
        didSet {
            Log.assertOnMainThread()

            ensureCellState()
        }
    }

    // We do "progressive" loading by loading stills (jpg or gif) and "animated" gifs.
    // This is critical on cellular connections.
    var stillAssetRequest: ProxiedContentAssetRequest?
    var stillAsset: ProxiedContentAsset?
    var animatedAssetRequest: ProxiedContentAssetRequest?
    var animatedAsset: ProxiedContentAsset?
    var imageView: YYAnimatedImageView?
    var activityIndicator: UIActivityIndicatorView?

    var isCellSelected: Bool = false {
        didSet {
            Log.assertOnMainThread()
            ensureCellState()
        }
    }

    // As another bandwidth saving measure, we only fetch the full sized GIF when the user selects it.
    private var renditionForSending: GiphyRendition?

    // MARK: Initializers

    deinit {
        stillAssetRequest?.cancel()
        animatedAssetRequest?.cancel()
    }

    override func prepareForReuse() {
        super.prepareForReuse()

        dependencies = nil
        imageInfo = nil
        isCellVisible = false
        stillAsset = nil
        stillAssetRequest?.cancel()
        stillAssetRequest = nil
        animatedAsset = nil
        animatedAssetRequest?.cancel()
        animatedAssetRequest = nil
        imageView?.removeFromSuperview()
        imageView = nil
        activityIndicator = nil
        isCellSelected = false
    }

    private func clearStillAssetRequest() {
        stillAssetRequest?.cancel()
        stillAssetRequest = nil
    }

    private func clearAnimatedAssetRequest() {
        animatedAssetRequest?.cancel()
        animatedAssetRequest = nil
    }

    private func clearAssetRequests() {
        clearStillAssetRequest()
        clearAnimatedAssetRequest()
    }

    public func ensureCellState() {
        ensureLoadState()
        ensureViewState()
    }

    public func ensureLoadState() {
        guard isCellVisible else {
            // Don't load if cell is not visible.
            clearAssetRequests()
            return
        }
        guard let imageInfo = imageInfo else {
            // Don't load if cell is not configured.
            clearAssetRequests()
            return
        }
        guard self.animatedAsset == nil else {
            // Don't load if cell is already loaded.
            clearAssetRequests()
            return
        }

        // Record high quality animated rendition, but to save bandwidth, don't start downloading
        // until it's selected.
        guard let highQualityAnimatedRendition = imageInfo.pickSendingRendition() else {
            Log.warn(.giphy, "Cell could not pick gif rendition: \(imageInfo.giphyId)")
            clearAssetRequests()
            return
        }
        self.renditionForSending = highQualityAnimatedRendition

        // The Giphy API returns a slew of "renditions" for a given image.
        // It's critical that we carefully "pick" the best rendition to use.
        guard let animatedRendition = imageInfo.pickPreviewRendition() else {
            Log.warn(.giphy, "Cell could not pick gif rendition: \(imageInfo.giphyId)")
            clearAssetRequests()
            return
        }
        guard let stillRendition = imageInfo.pickStillRendition() else {
            Log.warn(.giphy, "Cell could not pick still rendition: \(imageInfo.giphyId)")
            clearAssetRequests()
            return
        }

        // Start still asset request if necessary.
        if stillAsset != nil || animatedAsset != nil {
            clearStillAssetRequest()
        } else if stillAssetRequest == nil {
            stillAssetRequest = dependencies?[singleton: .giphyDownloader].requestAsset(
                assetDescription: stillRendition,
                priority: .high,
                success: { [weak self] assetRequest, asset in
                    if assetRequest != nil && assetRequest != self?.stillAssetRequest {
                        Log.error(.giphy, "Cell received obsolete request callback.")
                        return
                    }
                    
                    self?.clearStillAssetRequest()
                    self?.stillAsset = asset
                    self?.ensureViewState()
                },
                failure: { [weak self] assetRequest in
                    if assetRequest != self?.stillAssetRequest {
                        Log.error(.giphy, "Cell received obsolete request callback.")
                        return
                    }
                    self?.clearStillAssetRequest()
                }
            )
        }

        // Start animated asset request if necessary.
        if animatedAsset != nil {
            clearAnimatedAssetRequest()
        } else if animatedAssetRequest == nil {
            animatedAssetRequest = dependencies?[singleton: .giphyDownloader].requestAsset(
                assetDescription: animatedRendition,
                priority: .low,
                success: { [weak self] assetRequest, asset in
                    if assetRequest != nil && assetRequest != self?.animatedAssetRequest {
                        Log.error(.giphy, "Cell received obsolete request callback.")
                        return
                    }
                    
                    // If we have the animated asset, we don't need the still asset.
                    self?.clearAssetRequests()
                    self?.animatedAsset = asset
                    self?.ensureViewState()
                },
                failure: { [weak self] assetRequest in
                    if assetRequest != self?.animatedAssetRequest {
                        Log.error(.giphy, "Cell received obsolete request callback.")
                        return
                    }
                    
                    self?.clearAnimatedAssetRequest()
                }
            )
        }
    }

    private func ensureViewState() {
        guard isCellVisible else {
            // Clear image view so we don't animate offscreen GIFs.
            clearViewState()
            return
        }
        guard let asset = pickBestAsset() else {
            clearViewState()
            return
        }
        guard let dependencies: Dependencies = dependencies, Data.isValidImage(at: asset.filePath, type: .gif, using: dependencies) else {
            Log.error(.giphy, "Cell received invalid asset.")
            clearViewState()
            return
        }
        guard let image = YYImage(contentsOfFile: asset.filePath) else {
            Log.error(.giphy, "Cell could not load asset.")
            clearViewState()
            return
        }
        if imageView == nil {
            let imageView = YYAnimatedImageView()
            self.imageView = imageView
            self.contentView.addSubview(imageView)
            imageView.pin(to: contentView)
        }
        guard let imageView = imageView else {
            Log.error(.giphy, "Cell missing imageview.")
            clearViewState()
            return
        }
        imageView.image = image
        imageView.accessibilityIdentifier = "gif cell"
        self.themeBackgroundColor = nil

        if self.isCellSelected {
            let activityIndicator = UIActivityIndicatorView(style: .medium)
            self.activityIndicator = activityIndicator
            addSubview(activityIndicator)
            activityIndicator.center(in: self)
            activityIndicator.startAnimating()

            // Render activityIndicator on a white tile to ensure it's visible on
            // when overlayed on a variety of potential gifs.
            activityIndicator.themeBackgroundColor = .white
            activityIndicator.alpha = 0.3
            activityIndicator.set(.width, to: 30)
            activityIndicator.set(.height, to: 30)
            activityIndicator.themeShadowColor = .black
            activityIndicator.layer.cornerRadius = 3
            activityIndicator.layer.shadowOffset = CGSize(width: 1, height: 1)
            activityIndicator.layer.shadowOpacity = 0.7
            activityIndicator.layer.shadowRadius = 1.0
        } else {
            self.activityIndicator?.stopAnimating()
            self.activityIndicator = nil
        }
    }

    public func requestRenditionForSending() -> AnyPublisher<ProxiedContentAsset, Error> {
        guard let renditionForSending = self.renditionForSending else {
            Log.error(.giphy, "Cell renditionForSending was unexpectedly nil")
            return Fail(error: GiphyError.assertionError(description: "renditionForSending was unexpectedly nil"))
                .eraseToAnyPublisher()
        }
        guard let dependencies: Dependencies = self.dependencies else {
            return Fail(error: GiphyError.assertionError(description: "dependencies was unexpectedly nil"))
                .eraseToAnyPublisher()
        }

        // We don't retain a handle on the asset request, since there will only ever
        // be one selected asset, and we never want to cancel it.
        return dependencies[singleton: .giphyDownloader]
            .requestAsset(
                assetDescription: renditionForSending,
                priority: .high
            )
            .mapError { _ -> Error in
                // TODO: GiphyDownloader API should pass through a useful failing error so we can pass it through here
                Log.error(.giphy, "Cell request failed")
                return GiphyError.fetchFailure
            }
            .map { asset, _ in asset }
            .eraseToAnyPublisher()
    }

    private func clearViewState() {
        imageView?.image = nil
        self.themeBackgroundColor = .backgroundSecondary
    }

    private func pickBestAsset() -> ProxiedContentAsset? {
        return animatedAsset ?? stillAsset
    }
}
