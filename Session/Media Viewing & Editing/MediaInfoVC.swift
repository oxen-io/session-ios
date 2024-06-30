// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

final class MediaInfoVC: BaseVC, SessionCarouselViewDelegate {
    internal static let mediaSize: CGFloat = UIScreen.main.bounds.width - 2 * Values.veryLargeSpacing
    internal static let arrowSize: CGSize = CGSize(width: 20, height: 30)
    
    private let attachments: [Attachment]
    private let isOutgoing: Bool
    private let threadId: String
    private let threadVariant: SessionThread.Variant
    private let interactionId: Int64
    
    private var currentPage: Int = 0
    
    // MARK: - UI
    private lazy var mediaInfoView: MediaInfoView = MediaInfoView(attachment: nil)
    private lazy var mediaCarouselView: SessionCarouselView = {
        let slices: [MediaPreviewView] = self.attachments.map {
            MediaPreviewView(
                attachment: $0,
                isOutgoing: self.isOutgoing
            )
        }
        let result: SessionCarouselView = SessionCarouselView(
            info: SessionCarouselView.Info(
                slices: slices,
                copyOfFirstSlice: slices.first?.copyView(),
                copyOfLastSlice: slices.last?.copyView(),
                sliceSize: CGSize(
                    width: Self.mediaSize,
                    height: Self.mediaSize
                ),
                shouldShowPageControl: true,
                pageControlStyle: SessionCarouselView.PageControlStyle(
                    size: .medium,
                    backgroundColor: .init(white: 0, alpha: 0.4),
                    bottomInset: Values.mediumSpacing
                ),
                shouldShowArrows: true,
                arrowsSize: Self.arrowSize,
                cornerRadius: 8
            )
        )
        result.set(.height, to: Self.mediaSize)
        result.delegate = self
        
        return result
    }()
    
    private lazy var fullScreenButton: UIButton = {
        let result: UIButton = UIButton(type: .custom)
        result.setImage(
            UIImage(systemName: "arrow.up.left.and.arrow.down.right")?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        result.themeTintColor = .textPrimary
        result.backgroundColor = .init(white: 0, alpha: 0.4)
        result.layer.cornerRadius = 14
        result.set(.width, to: 28)
        result.set(.height, to: 28)
        result.addTarget(self, action: #selector(showMediaFullScreen), for: .touchUpInside)
        
        return result
    }()
    
    // MARK: - Initialization
    
    init(
        attachments: [Attachment],
        isOutgoing: Bool,
        threadId: String,
        threadVariant: SessionThread.Variant,
        interactionId: Int64
    ) {
        self.threadId = threadId
        self.threadVariant = threadVariant
        self.interactionId = interactionId
        self.isOutgoing = isOutgoing
        self.attachments = attachments
        super.init(nibName: nil, bundle: nil)
    }

    override init(nibName: String?, bundle: Bundle?) {
        preconditionFailure("Use init(attachments:) instead.")
    }

    required init?(coder: NSCoder) {
        preconditionFailure("Use init(attachments:) instead.")
    }
    
    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        
        ViewControllerUtilities.setUpDefaultSessionStyle(
            for: self,
            title: "messageInfo".localized(),
            hasCustomBackButton: false
        )
        
        let mediaStackView: UIStackView = UIStackView()
        mediaStackView.axis = .horizontal
        
        mediaInfoView.update(attachment: attachments[0])
        
        mediaCarouselView.addSubview(fullScreenButton)
        fullScreenButton.pin(.trailing, to: .trailing, of: mediaCarouselView, withInset: -(Values.smallSpacing + Values.veryLargeSpacing))
        fullScreenButton.pin(.bottom, to: .bottom, of: mediaCarouselView, withInset: -Values.smallSpacing)
        
        let stackView: UIStackView = UIStackView(arrangedSubviews: [ mediaCarouselView, mediaInfoView ])
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = Values.largeSpacing
        
        self.view.addSubview(stackView)
        stackView.pin([ UIView.HorizontalEdge.leading, UIView.HorizontalEdge.trailing ], to: self.view)
        stackView.pin(.top, to: .top, of: self.view, withInset: Values.veryLargeSpacing)
    }
    
    // MARK: - Interaction
    
    @objc func showMediaFullScreen() {
        let attachment = self.attachments[self.currentPage]
        let viewController: UIViewController? = MediaGalleryViewModel.createDetailViewController(
            for: self.threadId,
            threadVariant: self.threadVariant,
            interactionId: self.interactionId,
            selectedAttachmentId: attachment.id,
            options: [ .sliderEnabled ]
        )
        if let viewController: UIViewController = viewController {
            viewController.transitioningDelegate = nil
            self.present(viewController, animated: true)
        }
    }
    
    // MARK: - SessionCarouselViewDelegate
    
    func carouselViewDidScrollToNewSlice(currentPage: Int) {
        self.currentPage = currentPage
        mediaInfoView.update(attachment: attachments[currentPage])
    }
}
