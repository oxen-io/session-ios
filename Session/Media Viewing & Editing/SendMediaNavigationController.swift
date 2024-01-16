// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import Photos
import SignalUtilitiesKit
import SignalCoreKit
import SessionUIKit
import SessionUtilitiesKit
import SessionMessagingKit

class SendMediaNavigationController: UINavigationController {
    public override var preferredStatusBarStyle: UIStatusBarStyle {
        return ThemeManager.currentTheme.statusBarStyle
    }
    
    // This is a sensitive constant, if you change it make sure to check
    // on iPhone5, 6, 6+, X, layouts.
    static let bottomButtonsCenterOffset: CGFloat = -50
    
    private let dependencies: Dependencies
    private let threadId: String
    private let threadVariant: SessionThread.Variant
    private var disposables: Set<AnyCancellable> = Set()
    
    // MARK: - Initialization
    
    init(threadId: String, threadVariant: SessionThread.Variant, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.threadVariant = threadVariant
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Overrides
    
    override func viewDidLoad() {
        super.viewDidLoad()

        self.delegate = self

        let bottomButtonsCenterOffset = SendMediaNavigationController.bottomButtonsCenterOffset
        view.addSubview(batchModeButton)
        batchModeButton.setCompressionResistance(to: .required)
        batchModeButton.centerYAnchor.constraint(equalTo: view.layoutMarginsGuide.bottomAnchor, constant: bottomButtonsCenterOffset).isActive = true
        batchModeButton.centerXAnchor
            .constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -20)
            .isActive = true
        view.addSubview(doneButton)
        doneButton.setCompressionResistance(to: .required)
        doneButton.centerYAnchor.constraint(equalTo: view.layoutMarginsGuide.bottomAnchor, constant: bottomButtonsCenterOffset).isActive = true
        doneButton.pin(.trailing, toMargin: .trailing, of: view)
        view.addSubview(cameraModeButton)
        cameraModeButton.setCompressionResistance(to: .required)
        cameraModeButton.centerYAnchor
            .constraint(equalTo: view.layoutMarginsGuide.bottomAnchor, constant: bottomButtonsCenterOffset)
            .isActive = true
        cameraModeButton.centerXAnchor
            .constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 20)
            .isActive = true
        view.addSubview(mediaLibraryModeButton)
        mediaLibraryModeButton.setCompressionResistance(to: .required)
        mediaLibraryModeButton.centerYAnchor.constraint(equalTo: view.layoutMarginsGuide.bottomAnchor, constant: bottomButtonsCenterOffset).isActive = true
        mediaLibraryModeButton.centerXAnchor
            .constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 20)
            .isActive = true
    }

    // MARK: -

    public weak var sendMediaNavDelegate: SendMediaNavDelegate?

    public class func showingCameraFirst(threadId: String, threadVariant: SessionThread.Variant, using dependencies: Dependencies) -> SendMediaNavigationController {
        let navController = SendMediaNavigationController(threadId: threadId, threadVariant: threadVariant, using: dependencies)
        navController.viewControllers = [navController.captureViewController]

        return navController
    }

    public class func showingMediaLibraryFirst(threadId: String, threadVariant: SessionThread.Variant, using dependencies: Dependencies) -> SendMediaNavigationController {
        let navController = SendMediaNavigationController(threadId: threadId, threadVariant: threadVariant, using: dependencies)
        navController.viewControllers = [navController.mediaLibraryViewController]

        return navController
    }

    var isInBatchSelectMode = false {
        didSet {
            if oldValue != isInBatchSelectMode {
                mediaLibraryViewController.batchSelectModeDidChange()
                
                guard let topViewController = viewControllers.last else { return }
                
                updateButtons(topViewController: topViewController)
            }
        }
    }

    func updateButtons(topViewController: UIViewController) {
        switch topViewController {
            case is AttachmentApprovalViewController:
                batchModeButton.isHidden = true
                doneButton.isHidden = true
                cameraModeButton.isHidden = true
                mediaLibraryModeButton.isHidden = true
                
            case is ImagePickerGridController:
                batchModeButton.isHidden = isInBatchSelectMode
                doneButton.isHidden = !isInBatchSelectMode || (attachmentDraftCollection.count == 0 && mediaLibrarySelections.count == 0)
                cameraModeButton.isHidden = false
                mediaLibraryModeButton.isHidden = true
                
            case is PhotoCaptureViewController:
                batchModeButton.isHidden = isInBatchSelectMode
                doneButton.isHidden = !isInBatchSelectMode || (attachmentDraftCollection.count == 0 && mediaLibrarySelections.count == 0)
                cameraModeButton.isHidden = true
                mediaLibraryModeButton.isHidden = false
                
            default:
                owsFailDebug("unexpected topViewController: \(topViewController)")
        }

        doneButton.updateCount()
    }

    func fadeTo(viewControllers: [UIViewController]) {
        let transition: CATransition = CATransition()
        transition.duration = 0.1
        transition.type = CATransitionType.fade
        view.layer.add(transition, forKey: nil)
        setViewControllers(viewControllers, animated: false)
    }

    // MARK: - Events

    private func didTapBatchModeButton() {
        // There's no way to _disable_ batch mode.
        isInBatchSelectMode = true
    }

    private func didTapCameraModeButton() {
        Permissions.requestCameraPermissionIfNeeded(using: dependencies) { [weak self] in
            DispatchQueue.main.async {
                self?.fadeTo(viewControllers: ((self?.captureViewController).map { [$0] } ?? []))
            }
        }
    }

    private func didTapMediaLibraryModeButton() {
        Permissions.requestLibraryPermissionIfNeeded(using: dependencies) { [weak self] in
            DispatchQueue.main.async {
                self?.fadeTo(viewControllers: ((self?.mediaLibraryViewController).map { [$0] } ?? []))
            }
        }
    }

    // MARK: Views
    public static let bottomButtonWidth: CGFloat = 44

    private lazy var doneButton: DoneButton = {
        let button = DoneButton()
        button.delegate = self

        return button
    }()

    private lazy var batchModeButton: InputViewButton = {
        let result: InputViewButton = InputViewButton(
            icon: UIImage(named: "media_send_batch_mode_disabled")?
                .withRenderingMode(.alwaysTemplate)
        ) { [weak self] in self?.didTapBatchModeButton() }
        
        return result
    }()

    private lazy var cameraModeButton: InputViewButton = {
        let result: InputViewButton = InputViewButton(
            icon: UIImage(named: "settings-avatar-camera-2")?
                .withRenderingMode(.alwaysTemplate)
        ) { [weak self] in self?.didTapCameraModeButton() }

        return result
    }()

    private lazy var mediaLibraryModeButton: InputViewButton = {
        let result: InputViewButton = InputViewButton(
            icon: UIImage(named: "actionsheet_camera_roll_black")?
                .withRenderingMode(.alwaysTemplate)
        ) { [weak self] in self?.didTapMediaLibraryModeButton() }

        return result
    }()

    // MARK: State

    private lazy var attachmentDraftCollection = AttachmentDraftCollection.empty // Lazy to avoid https://bugs.swift.org/browse/SR-6657

    private var attachments: [SignalAttachment] {
        return attachmentDraftCollection.attachmentDrafts.map { $0.attachment }
    }

    private lazy var mediaLibrarySelections = OrderedDictionary<PHAsset, MediaLibrarySelection>() // Lazy to avoid https://bugs.swift.org/browse/SR-6657

    // MARK: Child VC's

    private lazy var captureViewController: PhotoCaptureViewController = {
        let vc = PhotoCaptureViewController()
        vc.delegate = self

        return vc
    }()

    private lazy var mediaLibraryViewController: ImagePickerGridController = {
        let vc = ImagePickerGridController()
        vc.delegate = self
        vc.collectionView.accessibilityLabel = "Images"

        return vc
    }()

    private func pushApprovalViewController() -> Bool {
        guard let sendMediaNavDelegate = self.sendMediaNavDelegate else {
            owsFailDebug("sendMediaNavDelegate was unexpectedly nil")
            return false
        }
        
        guard
            let approvalViewController: AttachmentApprovalViewController = AttachmentApprovalViewController(
                mode: .sharedNavigation,
                threadId: self.threadId,
                threadVariant: self.threadVariant,
                attachments: self.attachments,
                using: dependencies
            )
        else {
            return false
        }

        approvalViewController.approvalDelegate = self
        approvalViewController.messageText = sendMediaNavDelegate.sendMediaNavInitialMessageText(self)

        pushViewController(approvalViewController, animated: true)
        return true
    }

    private func didRequestExit() {
        guard attachmentDraftCollection.count > 0 else {
            self.sendMediaNavDelegate?.sendMediaNavDidCancel(self)
            return
        }
        
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "SEND_MEDIA_ABANDON_TITLE".localized(),
                confirmTitle: "SEND_MEDIA_CONFIRM_ABANDON_ALBUM".localized(),
                confirmStyle: .danger,
                cancelStyle: .alert_text,
                onConfirm: { [weak self] _ in
                    self?.sendMediaNavDelegate?.sendMediaNavDidCancel(self)
                }
            )
        )
        self.present(modal, animated: true)
    }
}

extension SendMediaNavigationController: UINavigationControllerDelegate {
    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        switch viewController {
            case is PhotoCaptureViewController:
                if attachmentDraftCollection.count == 1 && !isInBatchSelectMode {
                    // User is navigating "back" to the previous view, indicating
                    // they want to discard the previously captured item
                    discardDraft()
                }
            
            case is ImagePickerGridController:
                if attachmentDraftCollection.count == 1 && !isInBatchSelectMode {
                    isInBatchSelectMode = true
                    self.mediaLibraryViewController.batchSelectModeDidChange()
                }
            
            default:
                break
        }

        self.updateButtons(topViewController: viewController)
    }

    // In case back navigation was canceled, we re-apply whatever is showing.
    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        self.updateButtons(topViewController: viewController)
    }
}

extension SendMediaNavigationController: PhotoCaptureViewControllerDelegate {
    func photoCaptureViewController(_ photoCaptureViewController: PhotoCaptureViewController, didFinishProcessingAttachment attachment: SignalAttachment) {
        attachmentDraftCollection.append(.camera(attachment: attachment))
        if isInBatchSelectMode {
            updateButtons(topViewController: photoCaptureViewController)
        }
        else {
            pushApprovalViewController()
        }
    }

    func photoCaptureViewControllerDidCancel(_ photoCaptureViewController: PhotoCaptureViewController) {
        didRequestExit()
    }

    func discardDraft() {
        assert(attachmentDraftCollection.attachmentDrafts.count <= 1)
        if let lastAttachmentDraft = attachmentDraftCollection.attachmentDrafts.last {
            attachmentDraftCollection.remove(attachment: lastAttachmentDraft.attachment)
        }
        assert(attachmentDraftCollection.attachmentDrafts.count == 0)
    }
}

extension SendMediaNavigationController: ImagePickerGridControllerDelegate {

    func imagePickerDidCompleteSelection(_ imagePicker: ImagePickerGridController) {
        showApprovalAfterProcessingAnyMediaLibrarySelections()
    }

    func imagePickerDidCancel(_ imagePicker: ImagePickerGridController) {
        didRequestExit()
    }

    func showApprovalAfterProcessingAnyMediaLibrarySelections() {
        let mediaLibrarySelections: [MediaLibrarySelection] = self.mediaLibrarySelections.orderedValues

        let backgroundBlock: (ModalActivityIndicatorViewController) -> Void = { [weak self] modal in
            guard let strongSelf = self else { return }
            
            Publishers
                .MergeMany(mediaLibrarySelections.map { $0.publisher })
                .collect()
                .sink(
                    receiveCompletion: { result in
                        switch result {
                            case .finished: break
                            case .failure(let error):
                                Logger.error("failed to prepare attachments. error: \(error)")
                                modal.dismiss { [weak self] in
                                    let modal: ConfirmationModal = ConfirmationModal(
                                        targetView: self?.view,
                                        info: ConfirmationModal.Info(
                                            title: "IMAGE_PICKER_FAILED_TO_PROCESS_ATTACHMENTS".localized(),
                                            cancelTitle: "BUTTON_OK".localized(),
                                            cancelStyle: .alert_text
                                        )
                                    )
                                    self?.present(modal, animated: true)
                                }
                        }
                    },
                    receiveValue: { attachments in
                        Logger.debug("built all attachments")
                        modal.dismiss {
                            self?.attachmentDraftCollection.selectedFromPicker(attachments: attachments)
                            
                            guard self?.pushApprovalViewController() == true else {
                                let modal: ConfirmationModal = ConfirmationModal(
                                    info: ConfirmationModal.Info(
                                        title: "IMAGE_PICKER_FAILED_TO_PROCESS_ATTACHMENTS".localized(),
                                        cancelTitle: "BUTTON_OK".localized(),
                                        cancelStyle: .alert_text
                                    )
                                )
                                self?.present(modal, animated: true)
                                return
                            }
                        }
                    }
                )
                .store(in: &strongSelf.disposables)
        }

        ModalActivityIndicatorViewController.present(
            fromViewController: self,
            canCancel: false,
            onAppear: backgroundBlock
        )
    }

    func imagePicker(_ imagePicker: ImagePickerGridController, isAssetSelected asset: PHAsset) -> Bool {
        return mediaLibrarySelections.hasValue(forKey: asset)
    }

    func imagePicker(_ imagePicker: ImagePickerGridController, didSelectAsset asset: PHAsset, attachmentPublisher: AnyPublisher<SignalAttachment, Error>) {
        guard !mediaLibrarySelections.hasValue(forKey: asset) else { return }

        let libraryMedia = MediaLibrarySelection(
            asset: asset,
            signalAttachmentPublisher: attachmentPublisher
        )
        mediaLibrarySelections.append(key: asset, value: libraryMedia)
        updateButtons(topViewController: imagePicker)
    }

    func imagePicker(_ imagePicker: ImagePickerGridController, didDeselectAsset asset: PHAsset) {
        guard mediaLibrarySelections.hasValue(forKey: asset) else { return }
        
        mediaLibrarySelections.remove(key: asset)
        updateButtons(topViewController: imagePicker)
    }

    func imagePickerCanSelectAdditionalItems(_ imagePicker: ImagePickerGridController) -> Bool {
        return attachmentDraftCollection.count <= SignalAttachment.maxAttachmentsAllowed
    }
    
    func imagePicker(_ imagePicker: ImagePickerGridController, failedToRetrieveAssetAt index: Int, forCount count: Int) {
        let modal: ConfirmationModal = ConfirmationModal(
            targetView: self.view,
            info: ConfirmationModal.Info(
                title: "IMAGE_PICKER_FAILED_TO_PROCESS_ATTACHMENTS".localized(),
                cancelTitle: "BUTTON_OK".localized(),
                cancelStyle: .alert_text
            )
        )
        self.present(modal, animated: true)
    }
}

extension SendMediaNavigationController: AttachmentApprovalViewControllerDelegate {
    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didChangeMessageText newMessageText: String?) {
        sendMediaNavDelegate?.sendMediaNav(self, didChangeMessageText: newMessageText)
    }

    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didRemoveAttachment attachment: SignalAttachment) {
        guard let removedDraft = attachmentDraftCollection.attachmentDrafts.first(where: { $0.attachment == attachment}) else {
            owsFailDebug("removedDraft was unexpectedly nil")
            return
        }

        switch removedDraft.source {
        case .picker(attachment: let pickerAttachment):
            mediaLibrarySelections.remove(key: pickerAttachment.asset)
        case .camera(attachment: _):
            break
        }

        attachmentDraftCollection.remove(attachment: attachment)
    }

    func attachmentApproval(
        _ attachmentApproval: AttachmentApprovalViewController,
        didApproveAttachments attachments: [SignalAttachment],
        forThreadId threadId: String,
        threadVariant: SessionThread.Variant,
        messageText: String?
    ) {
        sendMediaNavDelegate?.sendMediaNav(
            self,
            didApproveAttachments: attachments,
            forThreadId: threadId,
            threadVariant: threadVariant,
            messageText: messageText
        )
    }

    func attachmentApprovalDidCancel(_ attachmentApproval: AttachmentApprovalViewController) {
        sendMediaNavDelegate?.sendMediaNavDidCancel(self)
    }

    func attachmentApprovalDidTapAddMore(_ attachmentApproval: AttachmentApprovalViewController) {
        // Current design dicates we'll go "back" to the single thing before us.
        assert(viewControllers.count == 2)

        // regardless of which VC we're going "back" to, we're in "batch" mode at this point.
        isInBatchSelectMode = true
        mediaLibraryViewController.batchSelectModeDidChange()

        popViewController(animated: true)
    }
}

private enum AttachmentDraft {
    case camera(attachment: SignalAttachment)
    case picker(attachment: MediaLibraryAttachment)
}

private extension AttachmentDraft {
    var attachment: SignalAttachment {
        switch self {
        case .camera(let cameraAttachment):
            return cameraAttachment
        case .picker(let pickerAttachment):
            return pickerAttachment.signalAttachment
        }
    }

    var source: AttachmentDraft {
        return self
    }
}

private final class AttachmentDraftCollection {
    lazy var attachmentDrafts = [AttachmentDraft]() // Lazy to avoid https://bugs.swift.org/browse/SR-6657

    static var empty: AttachmentDraftCollection {
        return AttachmentDraftCollection(attachmentDrafts: [])
    }
    
    init(attachmentDrafts: [AttachmentDraft]) {
        self.attachmentDrafts = attachmentDrafts
    }
    
    // MARK: -

    var count: Int {
        return attachmentDrafts.count
    }

    var pickerAttachments: [MediaLibraryAttachment] {
        return attachmentDrafts.compactMap { attachmentDraft in
            switch attachmentDraft.source {
            case .picker(let pickerAttachment):
                return pickerAttachment
            case .camera:
                return nil
            }
        }
    }

    var cameraAttachments: [SignalAttachment] {
        return attachmentDrafts.compactMap { attachmentDraft in
            switch attachmentDraft.source {
            case .picker:
                return nil
            case .camera(let cameraAttachment):
                return cameraAttachment
            }
        }
    }

    func append(_ element: AttachmentDraft) {
        attachmentDrafts.append(element)
    }

    func remove(attachment: SignalAttachment) {
        attachmentDrafts.removeAll { $0.attachment == attachment }
    }

    func selectedFromPicker(attachments: [MediaLibraryAttachment]) {
        let pickedAttachments: Set<MediaLibraryAttachment> = Set(attachments)
        let oldPickerAttachments: Set<MediaLibraryAttachment> = Set(self.pickerAttachments)

        for removedAttachment in oldPickerAttachments.subtracting(pickedAttachments) {
            remove(attachment: removedAttachment.signalAttachment)
        }

        // enumerate over new attachments to maintain order from picker
        for attachment in attachments {
            guard !oldPickerAttachments.contains(attachment) else {
                continue
            }
            append(.picker(attachment: attachment))
        }
    }
}

private struct MediaLibrarySelection: Hashable, Equatable {
    let asset: PHAsset
    let signalAttachmentPublisher: AnyPublisher<SignalAttachment, Error>

    func hash(into hasher: inout Hasher) {
        asset.hash(into: &hasher)
    }

    var publisher: AnyPublisher<MediaLibraryAttachment, Error> {
        let asset = self.asset
        return signalAttachmentPublisher
            .map { MediaLibraryAttachment(asset: asset, signalAttachment: $0) }
            .eraseToAnyPublisher()
    }

    static func ==(lhs: MediaLibrarySelection, rhs: MediaLibrarySelection) -> Bool {
        return lhs.asset == rhs.asset
    }
}

private struct MediaLibraryAttachment: Hashable, Equatable {
    let asset: PHAsset
    let signalAttachment: SignalAttachment

    func hash(into hasher: inout Hasher) {
        asset.hash(into: &hasher)
    }

    public static func == (lhs: MediaLibraryAttachment, rhs: MediaLibraryAttachment) -> Bool {
        return lhs.asset == rhs.asset
    }
}

extension SendMediaNavigationController: DoneButtonDelegate {
    var doneButtonCount: Int {
        return attachmentDraftCollection.count - attachmentDraftCollection.pickerAttachments.count + mediaLibrarySelections.count
    }

    fileprivate func doneButtonWasTapped(_ doneButton: DoneButton) {
        assert(attachmentDraftCollection.count > 0 || mediaLibrarySelections.count > 0)
        showApprovalAfterProcessingAnyMediaLibrarySelections()
    }
}

private protocol DoneButtonDelegate: AnyObject {
    func doneButtonWasTapped(_ doneButton: DoneButton)
    var doneButtonCount: Int { get }
}

private class DoneButton: UIView {
    weak var delegate: DoneButtonDelegate?
    let numberFormatter: NumberFormatter = NumberFormatter()
    
    private var didTouchDownInside: Bool = false
    
    // MARK: - UI
    
    private let container: UIView = {
        let result: UIView = UIView()
        result.themeBackgroundColor = .inputButton_background
        result.layer.cornerRadius = 20
        
        return result
    }()
    
    private lazy var badge: CircleView = {
        let result: CircleView = CircleView()
        result.themeBackgroundColor = .primary

        return result
    }()

    private lazy var badgeLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .regular
        )
        result.themeTextColor = .black   // Will render on the primary color so should always be black
        result.textAlignment = .center
        
        return result
    }()

    private lazy var chevron: UIView = {
        let image: UIImage = {
            guard Dependencies.isRTL else { return #imageLiteral(resourceName: "small_chevron_right") }
            
            return #imageLiteral(resourceName: "small_chevron_left")
        }()
        let result: UIImageView = UIImageView(image: image.withRenderingMode(.alwaysTemplate))
        result.contentMode = .scaleAspectFit
        result.themeTintColor = .textPrimary
        result.set(.width, to: 10)
        result.set(.height, to: 18)

        return result
    }()
    
    // MARK: - Lifecycle

    init() {
        super.init(frame: .zero)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(didTap(tapGesture:)))
        addGestureRecognizer(tapGesture)
        
        addSubview(container)
        container.pin(to: self)
        
        badge.addSubview(badgeLabel)
        badgeLabel.pin(to: badge, withInset: 4)
        
        // Constrain to be a pill that is at least a circle, and maybe wider.
        badgeLabel.set(.width, greaterThanOrEqualTo: .height, of: badgeLabel, multiplier: 1)
        badgeLabel.set(.width, to: .height, of: badgeLabel, multiplier: 1).setting(priority: .defaultLow)

        let stackView = UIStackView(arrangedSubviews: [badge, chevron])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 9

        addSubview(stackView)
        stackView.pin(.top, to: .top, of: self, withInset: 7)
        stackView.pin(.leading, to: .leading, of: self, withInset: 8)
        stackView.pin(.trailing, to: .trailing, of: self, withInset: -8)
        stackView.pin(.bottom, to: .bottom, of: self, withInset: -7)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Functions
    
    func updateCount() {
        guard let delegate = delegate else { return }

        badgeLabel.text = numberFormatter.string(for: delegate.doneButtonCount)
    }
    
    // MARK: - Interaction
    
    private func animate(
        to scale: CGFloat,
        themeBackgroundColor: ThemeValue,
        themeBadgeBackgroundColor: ThemeValue,
        themeTintColor: ThemeValue
    ) {
        UIView.animate(withDuration: 0.25) {
            self.container.transform = CGAffineTransform.identity.scaledBy(x: scale, y: scale)
            self.badgeLabel.themeTextColor = themeTintColor
            self.badge.themeBackgroundColor = themeBadgeBackgroundColor
            self.container.themeBackgroundColor = themeBackgroundColor
        }
    }
    
    private func expand() {
        animate(
            to: (InputViewButton.expandedSize / InputViewButton.size),
            themeBackgroundColor: .primary,
            themeBadgeBackgroundColor: .inputButton_background,
            themeTintColor: .textPrimary
        )
    }
    
    private func collapse() {
        animate(
            to: 1,
            themeBackgroundColor: .inputButton_background,
            themeBadgeBackgroundColor: .primary,
            themeTintColor: .black
        )
    }

    @objc func didTap(tapGesture: UITapGestureRecognizer) {
        delegate?.doneButtonWasTapped(self)
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard
            isUserInteractionEnabled,
            let location: CGPoint = touches.first?.location(in: self),
            bounds.contains(location)
        else { return }
        
        didTouchDownInside = true
        expand()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard
            isUserInteractionEnabled,
            let location: CGPoint = touches.first?.location(in: self),
            bounds.contains(location),
            didTouchDownInside
        else {
            if didTouchDownInside {
                collapse()
            }
            return
        }
        
        expand()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if didTouchDownInside {
            collapse()
        }
        
        didTouchDownInside = false
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if didTouchDownInside {
            collapse()
        }
        
        didTouchDownInside = false
    }
}

// MARK: - SendMediaNavDelegate

protocol SendMediaNavDelegate: AnyObject {
    func sendMediaNavDidCancel(_ sendMediaNavigationController: SendMediaNavigationController?)
    func sendMediaNav(_ sendMediaNavigationController: SendMediaNavigationController, didApproveAttachments attachments: [SignalAttachment], forThreadId threadId: String, threadVariant: SessionThread.Variant, messageText: String?)

    func sendMediaNavInitialMessageText(_ sendMediaNavigationController: SendMediaNavigationController) -> String?
    func sendMediaNav(_ sendMediaNavigationController: SendMediaNavigationController, didChangeMessageText newMessageText: String?)
}
