// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import Photos
import PhotosUI
import SessionUIKit
import SignalUtilitiesKit
import SignalCoreKit
import SessionUtilitiesKit
import SessionMessagingKit

protocol ImagePickerGridControllerDelegate: AnyObject {
    func imagePickerDidCompleteSelection(_ imagePicker: ImagePickerGridController)
    func imagePickerDidCancel(_ imagePicker: ImagePickerGridController)

    func imagePicker(_ imagePicker: ImagePickerGridController, isAssetSelected asset: PHAsset) -> Bool
    func imagePicker(_ imagePicker: ImagePickerGridController, didSelectAsset asset: PHAsset, attachmentPublisher: AnyPublisher<SignalAttachment, Error>)
    func imagePicker(_ imagePicker: ImagePickerGridController, didDeselectAsset asset: PHAsset)

    var isInBatchSelectMode: Bool { get }
    func imagePickerCanSelectAdditionalItems(_ imagePicker: ImagePickerGridController) -> Bool
    func imagePicker(_ imagePicker: ImagePickerGridController, failedToRetrieveAssetAt index: Int, forCount count: Int)
}

class ImagePickerGridController: UICollectionViewController, PhotoLibraryDelegate {

    weak var delegate: ImagePickerGridControllerDelegate?

    private let library: PhotoLibrary = PhotoLibrary()
    private var photoCollection: PhotoCollection
    private var photoCollectionContents: PhotoCollectionContents
    private let photoMediaSize = PhotoMediaSize()

    var collectionViewFlowLayout: UICollectionViewFlowLayout
    var titleView: TitleView!

    init() {
        collectionViewFlowLayout = type(of: self).buildLayout()
        photoCollection = library.defaultPhotoCollection()
        photoCollectionContents = photoCollection.contents()

        super.init(collectionViewLayout: collectionViewFlowLayout)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationItem.backButtonTitle = ""
        self.view.themeBackgroundColor = .newConversation_background

        library.add(delegate: self)

        guard let collectionView = collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        collectionView.register(view: PhotoGridViewCell.self)

        // ensure images at the end of the list can be scrolled above the bottom buttons
        let bottomButtonInset = -1 * SendMediaNavigationController.bottomButtonsCenterOffset + SendMediaNavigationController.bottomButtonWidth / 2 + 16
        collectionView.contentInset.bottom = bottomButtonInset + 16

        // The PhotoCaptureVC needs a shadow behind it's cancel button, so we use a custom icon.
        // This VC has a visible navbar so doesn't need the shadow, but because the user can
        // quickly toggle between the Capture and the Picker VC's, we use the same custom "X"
        // icon here rather than the system "stop" icon so that the spacing matches exactly.
        // Otherwise there's a noticable shift in the icon placement.
        let cancelImage = UIImage(imageLiteralResourceName: "X")
        let cancelButton = UIBarButtonItem(image: cancelImage, style: .plain, target: self, action: #selector(didPressCancel))

        cancelButton.themeTintColor = .textPrimary
        navigationItem.leftBarButtonItem = cancelButton

        let titleView = TitleView()
        titleView.delegate = self
        titleView.text = photoCollection.localizedTitle()
        navigationItem.titleView = titleView
        self.titleView = titleView

        collectionView.themeBackgroundColor = .newConversation_background

        let selectionPanGesture = DirectionalPanGestureRecognizer(direction: [.horizontal], target: self, action: #selector(didPanSelection))
        selectionPanGesture.delegate = self
        self.selectionPanGesture = selectionPanGesture
        collectionView.addGestureRecognizer(selectionPanGesture)
        
        if #available(iOS 14, *) {
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
                let addSeletedPhotoButton = UIBarButtonItem.init(barButtonSystemItem: .add, target: self, action: #selector(addSelectedPhoto))
                self.navigationItem.rightBarButtonItem = addSeletedPhotoButton
            }
        }
    }
    
    @objc func addSelectedPhoto(_ sender: Any) {
        if #available(iOS 14, *) {
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self)
        }
    }

    var selectionPanGesture: UIPanGestureRecognizer?
    enum BatchSelectionGestureMode {
        case select, deselect
    }
    
    var selectionPanGestureMode: BatchSelectionGestureMode = .select
    var hasEverAppeared: Bool = false
    
    @objc
    func didPanSelection(_ selectionPanGesture: UIPanGestureRecognizer) {
        guard let collectionView = collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        guard let delegate = delegate else {
            owsFailDebug("delegate was unexpectedly nil")
            return
        }

        guard delegate.isInBatchSelectMode else {
            return
        }

        switch selectionPanGesture.state {
            case .possible: break
            case .began:
                collectionView.isUserInteractionEnabled = false
                collectionView.isScrollEnabled = false

                let location = selectionPanGesture.location(in: collectionView)
                guard
                    let indexPath: IndexPath = collectionView.indexPathForItem(at: location),
                    let asset: PHAsset = photoCollectionContents.asset(at: indexPath.item)
                else { return }
                
                if delegate.imagePicker(self, isAssetSelected: asset) {
                    selectionPanGestureMode = .deselect
                }
                else {
                    selectionPanGestureMode = .select
                }
                
            case .changed:
                let location = selectionPanGesture.location(in: collectionView)
                guard let indexPath = collectionView.indexPathForItem(at: location) else { return }
                
                tryToToggleBatchSelect(at: indexPath)
                
            case .cancelled, .ended, .failed:
                collectionView.isUserInteractionEnabled = true
                collectionView.isScrollEnabled = true
            
            @unknown default: break
        }
    }

    func tryToToggleBatchSelect(at indexPath: IndexPath) {
        guard let collectionView = collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        guard let delegate = delegate else {
            owsFailDebug("delegate was unexpectedly nil")
            return
        }

        guard delegate.isInBatchSelectMode else {
            owsFailDebug("isInBatchSelectMode was unexpectedly false")
            return
        }

        guard let asset: PHAsset = photoCollectionContents.asset(at: indexPath.item) else { return }
        
        switch selectionPanGestureMode {
        case .select:
            guard delegate.imagePickerCanSelectAdditionalItems(self) else {
                showTooManySelectedToast()
                return
            }

            delegate.imagePicker(
                self,
                didSelectAsset: asset,
                attachmentPublisher: photoCollectionContents.outgoingAttachment(for: asset)
            )
            collectionView.selectItem(at: indexPath, animated: true, scrollPosition: [])
        case .deselect:
            delegate.imagePicker(self, didDeselectAsset: asset)
            collectionView.deselectItem(at: indexPath, animated: true)
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateLayout()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Determine the size of the thumbnails to request
        let scale = UIScreen.main.scale
        let cellSize = collectionViewFlowLayout.itemSize
        photoMediaSize.thumbnailSize = CGSize(width: cellSize.width * scale, height: cellSize.height * scale)
 
        if !hasEverAppeared {
            scrollToBottom(animated: false)
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        if !hasEverAppeared {
            // To scroll precisely to the bottom of the content, we have to account for the space
            // taken up by the navbar and any notch.
            //
            // Before iOS11 the system accounts for this by assigning contentInset to the scrollView
            // which is available by the time `viewWillAppear` is called.
            //
            // On iOS11+, contentInsets are not assigned to the scrollView in `viewWillAppear`, but
            // this method, `viewSafeAreaInsetsDidChange` is called *between* `viewWillAppear` and
            // `viewDidAppear` and indicates `safeAreaInsets` have been assigned.
            scrollToBottom(animated: false)
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        hasEverAppeared = true
        
        // Since we're presenting *over* the ConversationVC, we need to `becomeFirstResponder`.
        //
        // Otherwise, the `ConversationVC.inputAccessoryView` will appear over top of us whenever
        // OWSWindowManager window juggling executes `[rootWindow makeKeyAndVisible]`.
        //
        // We don't need to do this when pushing VCs onto the SignalsNavigationController - only when
        // presenting directly from ConversationVC.
        _ = self.becomeFirstResponder()

        DispatchQueue.main.async {
            // pre-layout collectionPicker for snappier response
            self.collectionPickerController.view.layoutIfNeeded()
        }
    }

    // HACK: Though we don't have an input accessory view, the VC we are presented above (ConversationVC) does.
    // If the app is backgrounded and then foregrounded, when OWSWindowManager calls mainWindow.makeKeyAndVisible
    // the ConversationVC's inputAccessoryView will appear *above* us unless we'd previously become first responder.
    override public var canBecomeFirstResponder: Bool {
        Logger.debug("")
        return true
    }

    // MARK: 
    
    var lastPageYOffset: CGFloat {
        return (collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom + view.safeAreaInsets.bottom)
    }

    func scrollToBottom(animated: Bool) {
        self.view.layoutIfNeeded()

        guard let collectionView = collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        let yOffset = lastPageYOffset
        guard yOffset > 0 else {
            // less than 1 page of content. Do not offset.
            return
        }

        collectionView.setContentOffset(CGPoint(x: 0, y: yOffset), animated: animated)
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if !hasEverAppeared, collectionView.contentOffset.y != lastPageYOffset {
            // We initially want the user to be scrolled to the bottom of the media library content.
            // However, at least on iOS12, we were finding that when the view finally presented,
            // the content was not *quite* to the bottom (~20px above it).
            //
            // Debugging shows that initially we have the correct offset, but that *something* is
            // causing the content to adjust *after* viewWillAppear and viewSafeAreaInsetsDidChange.
            // Because that something results in `scrollViewDidScroll` we re-adjust the content
            // insets to the bottom.
            Logger.debug("adjusting scroll offset back to bottom")
            scrollToBottom(animated: false)
        }
    }

    // MARK: - Actions

    @objc
    func didPressCancel(sender: UIBarButtonItem) {
        self.delegate?.imagePickerDidCancel(self)
    }

    // MARK: - Layout

    static let kInterItemSpacing: CGFloat = 2
    private class func buildLayout() -> UICollectionViewFlowLayout {
        let layout = UICollectionViewFlowLayout()
        layout.sectionInsetReference = .fromSafeArea
        layout.minimumInteritemSpacing = kInterItemSpacing
        layout.minimumLineSpacing = kInterItemSpacing
        layout.sectionHeadersPinToVisibleBounds = true

        return layout
    }

    func updateLayout() {
        let containerWidth: CGFloat = self.view.safeAreaLayoutGuide.layoutFrame.size.width
        let kItemsPerPortraitRow = 4
        let screenWidth = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        let approxItemWidth = screenWidth / CGFloat(kItemsPerPortraitRow)

        let itemCount = round(containerWidth / approxItemWidth)
        let spaceWidth = (itemCount + 1) * type(of: self).kInterItemSpacing
        let availableWidth = containerWidth - spaceWidth

        let itemWidth = floor(availableWidth / CGFloat(itemCount))
        let newItemSize = CGSize(width: itemWidth, height: itemWidth)

        if (newItemSize != collectionViewFlowLayout.itemSize) {
            collectionViewFlowLayout.itemSize = newItemSize
            collectionViewFlowLayout.invalidateLayout()
        }
    }

    // MARK: - Batch Selection

    func batchSelectModeDidChange() {
        guard let delegate = delegate else { return }

        guard let collectionView = collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        collectionView.allowsMultipleSelection = delegate.isInBatchSelectMode
    }

    func clearCollectionViewSelection() {
        guard let collectionView = self.collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        collectionView.indexPathsForSelectedItems?.forEach { collectionView.deselectItem(at: $0, animated: false)}
    }

    func showTooManySelectedToast() {
        Logger.info("")

        guard let  collectionView  = collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        let toastFormat = NSLocalizedString("IMAGE_PICKER_CAN_SELECT_NO_MORE_TOAST_FORMAT",
                                            comment: "Momentarily shown to the user when attempting to select more images than is allowed. Embeds {{max number of items}} that can be shared.")

        let toastText = String(format: toastFormat, NSNumber(value: SignalAttachment.maxAttachmentsAllowed))

        let toastController = ToastController(text: toastText, background: .backgroundPrimary)

        let kToastInset: CGFloat = 10
        let bottomInset = kToastInset + collectionView.contentInset.bottom + view.layoutMargins.bottom

        toastController.presentToastView(fromBottomOfView: view, inset: bottomInset)
    }

    // MARK: - PhotoLibraryDelegate

    func photoLibraryDidChange(_ photoLibrary: PhotoLibrary) {
        photoCollectionContents = photoCollection.contents()
        collectionView?.reloadData()
    }

    // MARK: - PhotoCollectionPicker Presentation

    var isShowingCollectionPickerController: Bool = false
    
    lazy var collectionPickerController: SessionTableViewController = SessionTableViewController(
        viewModel: PhotoCollectionPickerViewModel(library: library) { [weak self] collection in
            guard self?.photoCollection != collection else {
                self?.hideCollectionPicker()
                return
            }

            // Any selections are invalid as they refer to indices in a different collection
            self?.clearCollectionViewSelection()

            self?.photoCollection = collection
            self?.photoCollectionContents = collection.contents()

            self?.titleView.text = collection.localizedTitle()

            self?.collectionView?.reloadData()
            self?.scrollToBottom(animated: false)
            self?.hideCollectionPicker()
        }
    )

    func showCollectionPicker() {
        Logger.debug("")

        guard let collectionPickerView = collectionPickerController.view else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        assert(!isShowingCollectionPickerController)
        isShowingCollectionPickerController = true
        addChild(collectionPickerController)

        view.addSubview(collectionPickerView)
        collectionPickerView.pin(.top, to: .top, of: view.safeAreaLayoutGuide)
        collectionPickerView.pin(.leading, to: .leading, of: view)
        collectionPickerView.pin(.trailing, to: .trailing, of: view)
        collectionPickerView.pin(.bottom, to: .bottom, of: view)
        collectionPickerView.layoutIfNeeded()
        
        // Initially position offscreen, we'll animate it in.
        collectionPickerView.frame = collectionPickerView.frame.offsetBy(dx: 0, dy: collectionPickerView.frame.height)
        
        UIView.animate(withDuration: 0.25) {
            collectionPickerView.superview?.layoutIfNeeded()
            self.titleView.rotateIcon(.up)
        }
    }

    func hideCollectionPicker() {
        Logger.debug("")

        assert(isShowingCollectionPickerController)
        isShowingCollectionPickerController = false
        
        UIView.animate(
            withDuration: 0.25,
            animations: {
                self.collectionPickerController.view.frame = self.view.frame.offsetBy(dx: 0, dy: self.view.frame.height)
                self.titleView.rotateIcon(.down)
            },
            completion: { [weak self] _ in
                self?.collectionPickerController.view.removeFromSuperview()
                self?.collectionPickerController.removeFromParent()
            }
        )
    }
    
    // MARK: - UICollectionView

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let indexPathsForSelectedItems = collectionView.indexPathsForSelectedItems else {
            return true
        }

        if (indexPathsForSelectedItems.count < SignalAttachment.maxAttachmentsAllowed) {
            return true
        } else {
            showTooManySelectedToast()
            return false
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let delegate = delegate else {
            owsFailDebug("delegate was unexpectedly nil")
            return
        }

        guard let asset: PHAsset = photoCollectionContents.asset(at: indexPath.item) else {
            SNLog("Failed to select cell for asset at \(indexPath.item)")
            delegate.imagePicker(self, failedToRetrieveAssetAt: indexPath.item, forCount: photoCollectionContents.assetCount)
            return
        }
        
        delegate.imagePicker(
            self,
            didSelectAsset: asset,
            attachmentPublisher: photoCollectionContents.outgoingAttachment(for: asset)
        )

        if !delegate.isInBatchSelectMode {
            // Don't show "selected" badge unless we're in batch mode
            collectionView.deselectItem(at: indexPath, animated: false)
            delegate.imagePickerDidCompleteSelection(self)
        }
    }

    public override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        Logger.debug("")
        guard let delegate = delegate else {
            owsFailDebug("delegate was unexpectedly nil")
            return
        }

        guard let asset: PHAsset = photoCollectionContents.asset(at: indexPath.item) else {
            SNLog("Failed to deselect cell for asset at \(indexPath.item)")
            delegate.imagePicker(self, failedToRetrieveAssetAt: indexPath.item, forCount: photoCollectionContents.assetCount)
            return
        }
        
        delegate.imagePicker(self, didDeselectAsset: asset)
    }

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return photoCollectionContents.assetCount
    }

    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let delegate = delegate else {
            return UICollectionViewCell()
        }

        let cell: PhotoGridViewCell = collectionView.dequeue(type: PhotoGridViewCell.self, for: indexPath)
        
        guard let assetItem: PhotoPickerAssetItem = photoCollectionContents.assetItem(at: indexPath.item, photoMediaSize: photoMediaSize) else {
            SNLog("Failed to style cell for asset at \(indexPath.item)")
            return cell
        }
         
        cell.configure(item: assetItem)
        cell.isAccessibilityElement = true
        cell.accessibilityIdentifier = "\(assetItem.asset.modificationDate.map { "\($0)" } ?? "Unknown Date")"
        cell.isSelected = delegate.imagePicker(self, isAssetSelected: assetItem.asset)

        return cell
    }
}

extension ImagePickerGridController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Ensure we can still scroll the collectionView by allowing other gestures to
        // take precedence.
        guard otherGestureRecognizer == selectionPanGesture else {
            return true
        }

        // Once we've startd the selectionPanGesture, don't allow scrolling
        if otherGestureRecognizer.state == .began || otherGestureRecognizer.state == .changed {
            return false
        }

        return true
    }
}

protocol TitleViewDelegate: AnyObject {
    func titleViewWasTapped(_ titleView: TitleView)
}

class TitleView: UIView {

    // MARK: - Private

    private let label = UILabel()
    private let iconView = UIImageView()
    private let stackView: UIStackView

    // MARK: - Initializers

    override init(frame: CGRect) {
        let stackView = UIStackView(arrangedSubviews: [label, iconView])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 8
        stackView.isUserInteractionEnabled = true

        self.stackView = stackView

        super.init(frame: frame)

        addSubview(stackView)
        stackView.pin(to: self)
        
        label.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        label.themeTextColor = .textPrimary

        iconView.image = UIImage(named: "navbar_disclosure_down")?.withRenderingMode(.alwaysTemplate)
        iconView.themeTintColor = .textPrimary

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(titleTapped)))
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public

    weak var delegate: TitleViewDelegate?

    public var text: String? {
        get {
            return label.text
        }
        set {
            label.text = newValue
        }
    }

    public enum TitleViewRotationDirection {
        case up, down
    }

    public func rotateIcon(_ direction: TitleViewRotationDirection) {
        switch direction {
        case .up:
            // *slightly* more than `pi` to ensure the chevron animates counter-clockwise
            let chevronRotationAngle = CGFloat.pi + 0.001
            iconView.transform = CGAffineTransform(rotationAngle: chevronRotationAngle)
        case .down:
            iconView.transform = .identity
        }
    }

    // MARK: - Events

    @objc
    func titleTapped(_ tapGesture: UITapGestureRecognizer) {
        self.delegate?.titleViewWasTapped(self)
    }
}

extension ImagePickerGridController: TitleViewDelegate {
    func titleViewWasTapped(_ titleView: TitleView) {
        if isShowingCollectionPickerController {
            hideCollectionPicker()
        } else {
            showCollectionPicker()
        }
    }
}
