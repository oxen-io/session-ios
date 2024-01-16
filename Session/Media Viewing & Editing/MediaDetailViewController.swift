// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVKit
import AVFoundation
import YYImage
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SignalCoreKit
import SessionUtilitiesKit

public enum MediaGalleryOption {
    case sliderEnabled
    case showAllMediaButton
}

class MediaDetailViewController: OWSViewController, UIScrollViewDelegate {
    public let galleryItem: MediaGalleryViewModel.Item
    public weak var delegate: MediaDetailViewControllerDelegate?
    private var image: UIImage?
    
    // MARK: - UI
    
    private var mediaViewBottomConstraint: NSLayoutConstraint?
    private var mediaViewLeadingConstraint: NSLayoutConstraint?
    private var mediaViewTopConstraint: NSLayoutConstraint?
    private var mediaViewTrailingConstraint: NSLayoutConstraint?
    
    private lazy var scrollView: UIScrollView = {
        let result: UIScrollView = UIScrollView()
        result.showsVerticalScrollIndicator = false
        result.showsHorizontalScrollIndicator = false
        result.contentInsetAdjustmentBehavior = .never
        result.decelerationRate = .fast
        result.delegate = self
        
        return result
    }()
    
    public var mediaView: UIView = UIView()
    private lazy var playVideoButton: UIButton = {
        let result: UIButton = UIButton()
        result.contentMode = .scaleAspectFill
        result.setBackgroundImage(UIImage(named: "CirclePlay"), for: .normal)
        result.addTarget(self, action: #selector(playVideo), for: .touchUpInside)
        result.alpha = 0
        
        let playButtonSize: CGFloat = Values.scaleFromIPhone5(70)
        result.set(.width, to: playButtonSize)
        result.set(.height, to: playButtonSize)
        
        return result
    }()
    
    // MARK: - Initialization
    
    init(
        galleryItem: MediaGalleryViewModel.Item,
        delegate: MediaDetailViewControllerDelegate? = nil
    ) {
        self.galleryItem = galleryItem
        self.delegate = delegate
        
        super.init(nibName: nil, bundle: nil)
        
        // We cache the image data in case the attachment stream is deleted.
        galleryItem.attachment.thumbnail(
            size: .large,
            success: { [weak self] image, _ in
                // Only reload the content if the view has already loaded (if it
                // hasn't then it'll load with the image immediately)
                let updateUICallback = {
                    self?.image = image
                    
                    if self?.isViewLoaded == true {
                        self?.updateContents()
                        self?.updateMinZoomScale()
                    }
                }
                
                guard Thread.isMainThread else {
                    DispatchQueue.main.async {
                        updateUICallback()
                    }
                    return
                }
                
                updateUICallback()
            },
            failure: {
                SNLog("Could not load media.")
            }
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.view.themeBackgroundColor = .newConversation_background
        
        self.view.addSubview(scrollView)
        self.view.addSubview(playVideoButton)
        
        scrollView.pin(to: self.view)
        playVideoButton.center(in: self.view)
        
        self.updateContents()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        self.resetMediaFrame()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if self.parent == nil || !(self.parent is MediaPageViewController) {
            parentDidAppear()
        }
    }
    
    public func parentDidAppear() {
        if mediaView is YYAnimatedImageView {
            (mediaView as? YYAnimatedImageView)?.startAnimating()
        }
            
        if self.galleryItem.attachment.isVideo {
            UIView.animate(withDuration: 0.2) { self.playVideoButton.alpha = 1 }
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        self.updateMinZoomScale()
        self.centerMediaViewConstraints()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        UIView.animate(withDuration: 0.15) { [weak playVideoButton] in playVideoButton?.alpha = 0 }
    }
    
    // MARK: - Functions
    
    private func updateMinZoomScale() {
        let maybeImageSize: CGSize? = {
            switch self.mediaView {
                case let imageView as UIImageView: return (imageView.image?.size ?? .zero)
                case let imageView as YYAnimatedImageView: return (imageView.image?.size ?? .zero)
                default: return nil
            }
        }()
        
        guard let imageSize: CGSize = maybeImageSize else {
            self.scrollView.minimumZoomScale = 1
            self.scrollView.maximumZoomScale = 1
            self.scrollView.zoomScale = 1
            return
        }
        
        let viewSize: CGSize = self.scrollView.bounds.size
        
        guard imageSize.width > 0 && imageSize.height > 0 else {
            SNLog("Invalid image dimensions (\(imageSize.width), \(imageSize.height))")
            return
        }
        
        let scaleWidth: CGFloat = (viewSize.width / imageSize.width)
        let scaleHeight: CGFloat = (viewSize.height / imageSize.height)
        let minScale: CGFloat = min(scaleWidth, scaleHeight)

        if minScale != self.scrollView.minimumZoomScale {
            self.scrollView.minimumZoomScale = minScale
            self.scrollView.maximumZoomScale = (minScale * 8)
            self.scrollView.zoomScale = minScale
        }
    }
    
    public func zoomOut(animated: Bool) {
        if self.scrollView.zoomScale != self.scrollView.minimumZoomScale {
            self.scrollView.setZoomScale(self.scrollView.minimumZoomScale, animated: animated)
        }
    }

    // MARK: - Content
    
    private func updateContents() {
        self.mediaView.removeFromSuperview()
        self.scrollView.zoomScale = 1
        
        if self.galleryItem.attachment.isAnimated {
            if self.galleryItem.attachment.isValid, let originalFilePath: String = self.galleryItem.attachment.originalFilePath {
                let animatedView: YYAnimatedImageView = YYAnimatedImageView()
                animatedView.autoPlayAnimatedImage = false
                animatedView.image = YYImage(contentsOfFile: originalFilePath)
                self.mediaView = animatedView
            }
            else {
                self.mediaView = UIView()
                self.mediaView.themeBackgroundColor = .newConversation_background
            }
        }
        else if self.image == nil {
            // Still loading thumbnail.
            self.mediaView = UIView()
            self.mediaView.themeBackgroundColor = .newConversation_background
        }
        else {
            // Present the static image using standard UIImageView
            self.mediaView = UIImageView(image: self.image)
        }
        
        // We add these gestures to mediaView rather than
        // the root view so that interacting with the video player
        // progres bar doesn't trigger any of these gestures.
        self.addGestureRecognizers(to: self.mediaView)
        self.scrollView.addSubview(self.mediaView)
        
        self.mediaViewLeadingConstraint = self.mediaView.pin(.leading, to: .leading, of: self.scrollView)
        self.mediaViewTopConstraint = self.mediaView.pin(.top, to: .top, of: self.scrollView)
        self.mediaViewTrailingConstraint = self.mediaView.pin(.trailing, to: .trailing, of: self.scrollView)
        self.mediaViewBottomConstraint = self.mediaView.pin(.bottom, to: .bottom, of: self.scrollView)
        
        self.mediaView.contentMode = .scaleAspectFit
        self.mediaView.isUserInteractionEnabled = true
        self.mediaView.clipsToBounds = true
        self.mediaView.layer.allowsEdgeAntialiasing = true
        self.mediaView.translatesAutoresizingMaskIntoConstraints = false

        // Use trilinear filters for better scaling quality at
        // some performance cost.
        self.mediaView.layer.minificationFilter = .trilinear
        self.mediaView.layer.magnificationFilter = .trilinear
    }

    private func addGestureRecognizers(to view: UIView) {
        let doubleTap: UITapGestureRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(didDoubleTapImage(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        let singleTap: UITapGestureRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(didSingleTapImage(_:))
        )
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)
    }

    // MARK: - Gesture Recognizers

    @objc private func didSingleTapImage(_ gesture: UITapGestureRecognizer) {
        self.delegate?.mediaDetailViewControllerDidTapMedia(self)
    }

    @objc private func didDoubleTapImage(_ gesture: UITapGestureRecognizer) {
        guard self.scrollView.zoomScale == self.scrollView.minimumZoomScale else {
            // If already zoomed in at all, zoom out all the way.
            self.zoomOut(animated: true)
            return
        }
        
        let doubleTapZoomScale: CGFloat = 2
        let zoomWidth: CGFloat = (self.scrollView.bounds.width / doubleTapZoomScale)
        let zoomHeight: CGFloat = (self.scrollView.bounds.height / doubleTapZoomScale)

        // Center zoom rect around tapLocation
        let tapLocation: CGPoint = gesture.location(in: self.scrollView)
        let zoomX: CGFloat = max(0, tapLocation.x - zoomWidth / 2)
        let zoomY: CGFloat = max(0, tapLocation.y - zoomHeight / 2)
        let zoomRect: CGRect = CGRect(x: zoomX, y: zoomY, width: zoomWidth, height: zoomHeight)
        let translatedRect: CGRect = self.mediaView.convert(zoomRect, to: self.scrollView)
        
        self.scrollView.zoom(to: translatedRect, animated: true)
    }

    public func didPressPlayBarButton() {
        self.playVideo()
    }

    // MARK: - UIScrollViewDelegate
    
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return self.mediaView
    }
    
    private func centerMediaViewConstraints() {
        let scrollViewSize: CGSize = self.scrollView.bounds.size
        let imageViewSize: CGSize = self.mediaView.frame.size
        
        // We want to modify the yOffset so the content remains centered on the screen (we can do this
        // by subtracting half the parentViewController's y position)
        //
        // Note: Due to weird partial-pixel value rendering behaviours we need to round the inset either
        // up or down depending on which direction the partial-pixel would end up rounded to make it
        // align correctly
        let halfHeightDiff: CGFloat = ((self.scrollView.bounds.size.height - self.mediaView.frame.size.height) / 2)
        let shouldRoundUp: Bool = (round(halfHeightDiff) - halfHeightDiff > 0)

        let yOffset: CGFloat = (
            round((scrollViewSize.height - imageViewSize.height) / 2) -
            (shouldRoundUp ?
                ceil((self.parent?.view.frame.origin.y ?? 0) / 2) :
                floor((self.parent?.view.frame.origin.y ?? 0) / 2)
            )
        )

        self.mediaViewTopConstraint?.constant = yOffset
        self.mediaViewBottomConstraint?.constant = yOffset

        let xOffset: CGFloat = max(0, (scrollViewSize.width - imageViewSize.width) / 2)
        self.mediaViewLeadingConstraint?.constant = xOffset
        self.mediaViewTrailingConstraint?.constant = xOffset
    }
    
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        self.centerMediaViewConstraints()
        self.view.layoutIfNeeded()
    }

    private func resetMediaFrame() {
        // HACK: Setting the frame to itself *seems* like it should be a no-op, but
        // it ensures the content is drawn at the right frame. In particular I was
        // reproducibly seeing some images squished (they were EXIF rotated, maybe
        // related). similar to this report:
        // https://stackoverflow.com/questions/27961884/swift-uiimageview-stretched-aspect
        self.view.layoutIfNeeded()
        self.mediaView.frame = self.mediaView.frame
    }

    // MARK: - Video Playback

    @objc public func playVideo() {
        guard
            let originalFilePath: String = self.galleryItem.attachment.originalFilePath,
            FileManager.default.fileExists(atPath: originalFilePath)
        else { return SNLog("Missing video file") }
        
        let videoUrl: URL = URL(fileURLWithPath: originalFilePath)
        let player: AVPlayer = AVPlayer(url: videoUrl)
        let viewController: AVPlayerViewController = AVPlayerViewController()
        viewController.player = player
        self.present(viewController, animated: true) { [weak player] in
            player?.play()
        }
    }
}

// MARK: - MediaDetailViewControllerDelegate

protocol MediaDetailViewControllerDelegate: AnyObject {
    func mediaDetailViewControllerDidTapMedia(_ mediaDetailViewController: MediaDetailViewController)
}
