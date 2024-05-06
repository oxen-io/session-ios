//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.

import UIKit
import Combine
import MediaPlayer
import YYImage
import NVActivityIndicatorView
import SessionUIKit
import SessionMessagingKit
import SignalCoreKit
import SessionUtilitiesKit

public class MediaMessageView: UIView {
    public enum Mode: UInt {
        case large
        case small
        case attachmentApproval
    }

    // MARK: Properties

    private var disposables: Set<AnyCancellable> = Set()
    public let mode: Mode
    public let attachment: SignalAttachment
    
    private lazy var validImage: UIImage? = {
        if attachment.isImage {
            guard
                attachment.isValidImage,
                let image: UIImage = attachment.image(),
                image.size.width > 0,
                image.size.height > 0
            else {
                return nil
            }
            
            return image
        }
        else if attachment.isVideo {
            guard
                attachment.isValidVideo,
                let image: UIImage = attachment.videoPreview(),
                image.size.width > 0,
                image.size.height > 0
            else {
                return nil
            }
            
            return image
        }
        
        return nil
    }()
    private lazy var validAnimatedImage: YYImage? = {
        guard
            attachment.isAnimatedImage,
            attachment.isValidImage,
            let dataUrl: URL = attachment.dataUrl,
            let image: YYImage = YYImage(contentsOfFile: dataUrl.path),
            image.size.width > 0,
            image.size.height > 0
        else {
            return nil
        }
        
        return image
    }()
    private lazy var duration: TimeInterval? = attachment.duration()
    private var linkPreviewInfo: (url: String, draft: LinkPreviewDraft?)?

    // MARK: Initializers

    @available(*, unavailable, message:"use other constructor instead.")
    required public init?(coder aDecoder: NSCoder) {
        notImplemented()
    }

    // Currently we only use one mode (AttachmentApproval), so we could simplify this class, but it's kind
    // of nice that it's written in a flexible way in case we'd want to use it elsewhere again in the future.
    public required init(attachment: SignalAttachment, mode: MediaMessageView.Mode, using dependencies: Dependencies) {
        if attachment.hasError { owsFailDebug(attachment.error.debugDescription) }
        
        self.attachment = attachment
        self.mode = mode
        
        // Set the linkPreviewUrl if it's a url
        if attachment.isUrl, let linkPreviewURL: String = LinkPreview.previewUrl(for: attachment.text()) {
            self.linkPreviewInfo = (url: linkPreviewURL, draft: nil)
        }
        
        super.init(frame: CGRect.zero)

        setupViews(using: dependencies)
        setupLayout()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - UI
    
    private lazy var stackView: UIStackView = {
        let stackView: UIStackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.distribution = .fill
        
        switch mode {
            case .attachmentApproval: stackView.spacing = 2
            case .large: stackView.spacing = 10
            case .small: stackView.spacing = 5
        }
        
        return stackView
    }()
    
    private let loadingView: NVActivityIndicatorView = {
        let result: NVActivityIndicatorView = NVActivityIndicatorView(
            frame: CGRect.zero,
            type: .circleStrokeSpin,
            color: .black,
            padding: nil
        )
        result.translatesAutoresizingMaskIntoConstraints = false
        result.isHidden = true
        
        ThemeManager.onThemeChange(observer: result) { [weak result] theme, _ in
            guard let textPrimary: UIColor = theme.color(for: .textPrimary) else { return }
            
            result?.color = textPrimary
        }
        
        return result
    }()
    
    private lazy var imageView: UIImageView = {
        let view: UIImageView = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFit
        view.image = UIImage(named: "FileLarge")?.withRenderingMode(.alwaysTemplate)
        view.themeTintColor = .textPrimary
        view.isHidden = true
        
        // Override the image to the correct one
        if attachment.isImage || attachment.isVideo {
            if let validImage: UIImage = validImage {
                view.layer.minificationFilter = .trilinear
                view.layer.magnificationFilter = .trilinear
                view.image = validImage
            }
        }
        else if attachment.isUrl {
            view.clipsToBounds = true
            view.image = UIImage(named: "Link")?.withRenderingMode(.alwaysTemplate)
            view.themeTintColor = .messageBubble_outgoingText
            view.contentMode = .center
            view.themeBackgroundColor = .messageBubble_overlay
            view.layer.cornerRadius = 8
        }
        
        return view
    }()
    
    private lazy var fileTypeImageView: UIImageView = {
        let view: UIImageView = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        
        return view
    }()
    
    private lazy var animatedImageView: YYAnimatedImageView = {
        let view: YYAnimatedImageView = YYAnimatedImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        
        if let image: YYImage = validAnimatedImage {
            view.image = image
        }
        else {
            view.contentMode = .scaleAspectFit
            view.image = UIImage(named: "FileLarge")?.withRenderingMode(.alwaysTemplate)
            view.themeTintColor = .textPrimary
        }
        
        return view
    }()
    
    private lazy var titleStackView: UIStackView = {
        let stackView: UIStackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.alignment = (attachment.isUrl && linkPreviewInfo?.url != nil ? .leading : .center)
        stackView.distribution = .fill
        
        switch mode {
            case .attachmentApproval: stackView.spacing = 2
            case .large: stackView.spacing = 10
            case .small: stackView.spacing = 5
        }
        
        return stackView
    }()
    
    private lazy var titleLabel: UILabel = {
        let label: UILabel = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        
        // Styling
        switch mode {
            case .attachmentApproval:
                label.font = UIFont.boldSystemFont(ofSize: Values.scaleFromIPhone5To7Plus(16, 22))
                label.themeTextColor = .textPrimary
                
            case .large:
                label.font = UIFont.systemFont(ofSize: Values.scaleFromIPhone5To7Plus(18, 24))
                label.themeTextColor = .primary
                
            case .small:
                label.font = UIFont.systemFont(ofSize: Values.scaleFromIPhone5To7Plus(14, 14))
                label.themeTextColor = .primary
        }
        
        // Content
        if attachment.isUrl {
            // If we have no link preview info at this point then assume link previews are disabled
            if let linkPreviewURL: String = linkPreviewInfo?.url {
                label.font = .boldSystemFont(ofSize: Values.smallFontSize)
                label.text = linkPreviewURL
                label.textAlignment = .left
                label.lineBreakMode = .byTruncatingTail
                label.numberOfLines = 2
            }
            else {
                label.text = "vc_share_link_previews_disabled_title".localized()
            }
        }
        // Title for everything except these types
        else if !attachment.isImage && !attachment.isAnimatedImage && !attachment.isVideo {
            if let fileName: String = attachment.sourceFilename?.trimmingCharacters(in: .whitespacesAndNewlines), fileName.count > 0 {
                label.text = fileName
            }
            else if let fileExtension: String = attachment.fileExtension {
                label.text = String(
                    format: "ATTACHMENT_APPROVAL_FILE_EXTENSION_FORMAT".localized(),
                    fileExtension.uppercased()
                )
            }
            
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingMiddle
        }
        
        // Hide the label if it has no content
        label.isHidden = ((label.text?.count ?? 0) == 0)
        
        return label
    }()
    
    private lazy var subtitleLabel: UILabel = {
        let label: UILabel = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        
        // Styling
        switch mode {
            case .attachmentApproval:
                label.font = UIFont.systemFont(ofSize: Values.scaleFromIPhone5To7Plus(12, 18))
                label.themeTextColor = .textSecondary
                
            case .large:
                label.font = UIFont.systemFont(ofSize: Values.scaleFromIPhone5To7Plus(18, 24))
                label.themeTextColor = .primary
                
            case .small:
                label.font = UIFont.systemFont(ofSize: Values.scaleFromIPhone5To7Plus(14, 14))
                label.themeTextColor = .primary
        }
        
        // Content
        if attachment.isUrl {
            // We only load Link Previews for HTTPS urls so append an explanation for not
            if let linkPreviewURL: String = linkPreviewInfo?.url {
                if let targetUrl: URL = URL(string: linkPreviewURL), targetUrl.scheme?.lowercased() != "https" {
                    label.font = UIFont.systemFont(ofSize: Values.verySmallFontSize)
                    label.text = "vc_share_link_previews_unsecure".localized()
                    label.themeTextColor = (mode == .attachmentApproval ?
                        .textSecondary :
                        .primary
                    )
                }
            }
            // If we have no link preview info at this point then assume link previews are disabled
            else {
                label.text = "vc_share_link_previews_disabled_explanation".localized()
                label.themeTextColor = .textPrimary
                label.textAlignment = .center
                label.numberOfLines = 0
            }
        }
        // Subtitle for everything else except these types
        else if !attachment.isImage && !attachment.isAnimatedImage && !attachment.isVideo {
            // Format string for file size label in call interstitial view.
            // Embeds: {{file size as 'N mb' or 'N kb'}}.
            let fileSize: UInt = attachment.dataLength
            label.text = duration
                .map { "\(Format.fileSize(fileSize)), \(Format.duration($0))" }
                .defaulting(to: Format.fileSize(fileSize))
            label.textAlignment = .center
        }
        
        // Hide the label if it has no content
        label.isHidden = ((label.text?.count ?? 0) == 0)
        
        return label
    }()
    
    // MARK: - Layout

    private func setupViews(using dependencies: Dependencies) {
        // Plain text will just be put in the 'message' input so do nothing
        guard !attachment.isText else { return }
        
        // Setup the view hierarchy
        addSubview(stackView)
        addSubview(loadingView)
        
        stackView.addArrangedSubview(imageView)
        stackView.addArrangedSubview(animatedImageView)
        if !titleLabel.isHidden { stackView.addArrangedSubview(UIView.vhSpacer(10, 10)) }
        stackView.addArrangedSubview(titleStackView)
        
        titleStackView.addArrangedSubview(titleLabel)
        titleStackView.addArrangedSubview(subtitleLabel)
        
        imageView.addSubview(fileTypeImageView)
        
        // Type-specific configurations
        if attachment.isAnimatedImage {
            animatedImageView.isHidden = false
        }
        else if attachment.isImage {
            imageView.isHidden = false
        }
        else if attachment.isVideo {
            // Note: The 'attachmentApproval' mode provides it's own play button to keep
            // it at the proper scale when zooming
            imageView.isHidden = false
        }
        else if attachment.isAudio {
            // Hide the 'audioPlayPauseButton' if the 'audioPlayer' failed to get created
            imageView.isHidden = false
            
            fileTypeImageView.image = UIImage(named: "table_ic_notification_sound")?
                .withRenderingMode(.alwaysTemplate)
            fileTypeImageView.themeTintColor = .textPrimary
            fileTypeImageView.isHidden = false
        }
        else if attachment.isUrl {
            imageView.isHidden = false
            imageView.alpha = 0 // Not 'isHidden' because we want it to take up space in the UIStackView
            loadingView.isHidden = false
            
            if let linkPreviewUrl: String = linkPreviewInfo?.url {
                // Don't want to change the axis until we have a URL to start loading, otherwise the
                // error message will be broken
                stackView.axis = .horizontal
                
                loadLinkPreview(linkPreviewURL: linkPreviewUrl, using: dependencies)
            }
        }
        else {
            imageView.isHidden = false
        }
    }
    
    private func setupLayout() {
        // Plain text will just be put in the 'message' input so do nothing
        guard !attachment.isText else { return }
        
        // Sizing calculations
        let clampedRatio: CGFloat = {
            if attachment.isUrl {
                return 1
            }
            
            if attachment.isAnimatedImage {
                let imageSize: CGSize = (animatedImageView.image?.size ?? CGSize(width: 1, height: 1))
                let aspectRatio: CGFloat = (imageSize.width / imageSize.height)
            
                return aspectRatio.clamp(0.05, 95.0)
            }
            
            // All other types should maintain the ratio of the image in the 'imageView'
            let imageSize: CGSize = (imageView.image?.size ?? CGSize(width: 1, height: 1))
            let aspectRatio: CGFloat = (imageSize.width / imageSize.height)
        
            return aspectRatio.clamp(0.05, 95.0)
        }()
        
        let maybeImageSize: CGFloat? = {
            if attachment.isImage || attachment.isVideo {
                if validImage != nil { return nil }
                
                // If we don't have a valid image then use the 'generic' case
            }
            else if attachment.isAnimatedImage {
                if validAnimatedImage != nil { return nil }
                
                // If we don't have a valid image then use the 'generic' case
            }
            else if attachment.isUrl {
                return 80
            }
            
            // Generic file size
            switch mode {
                case .large: return 200
                case .attachmentApproval: return 120
                case .small: return 80
            }
        }()
        
        let imageSize: CGFloat = (maybeImageSize ?? 0)
        
        // Actual layout
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor),
            
            (maybeImageSize != nil ?
                stackView.widthAnchor.constraint(
                    equalTo: widthAnchor,
                    constant: (attachment.isUrl ? -(32 * 2) : 0)    // Inset stackView for urls
                ) :
                stackView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor)
            ),
            
            imageView.widthAnchor.constraint(
                equalTo: imageView.heightAnchor,
                multiplier: clampedRatio
            ),
            animatedImageView.widthAnchor.constraint(
                equalTo: animatedImageView.heightAnchor,
                multiplier: clampedRatio
            ),
            
            // Note: AnimatedImage, Image and Video types should allow zooming so be lessThanOrEqualTo
            // the view size but some other types should have specific sizes
            animatedImageView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            animatedImageView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor),
            
            (maybeImageSize != nil ?
                imageView.widthAnchor.constraint(equalToConstant: imageSize) :
                imageView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor)
            ),
            (maybeImageSize != nil ?
                imageView.heightAnchor.constraint(equalToConstant: imageSize) :
                imageView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor)
            ),
            
            fileTypeImageView.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            fileTypeImageView.centerYAnchor.constraint(
                equalTo: imageView.centerYAnchor,
                constant: ceil(imageSize * 0.15)
            ),
            fileTypeImageView.widthAnchor.constraint(
                equalTo: fileTypeImageView.heightAnchor,
                multiplier: ((fileTypeImageView.image?.size.width ?? 1) / (fileTypeImageView.image?.size.height ?? 1))
            ),
            fileTypeImageView.widthAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 0.5),

            loadingView.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            loadingView.widthAnchor.constraint(equalToConstant: ceil(imageSize / 3)),
            loadingView.heightAnchor.constraint(equalToConstant: ceil(imageSize / 3))
        ])
        
        // No inset for the text for URLs but there is for all other layouts
        if !attachment.isUrl {
            NSLayoutConstraint.activate([
                titleLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -(32 * 2)),
                subtitleLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -(32 * 2))
            ])
        }
    }
    
    // MARK: - Link Loading
    
    private func loadLinkPreview(linkPreviewURL: String, using dependencies: Dependencies) {
        loadingView.startAnimating()
        
        LinkPreview.tryToBuildPreviewInfo(previewUrl: linkPreviewURL, using: dependencies)
            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] result in
                    switch result {
                        case .finished: break
                        case .failure:
                            self?.loadingView.alpha = 0
                            self?.loadingView.stopAnimating()
                            self?.imageView.alpha = 1
                            self?.titleLabel.numberOfLines = 1  // Truncates the URL at 1 line so the error is more readable
                            self?.subtitleLabel.isHidden = false
                            
                            // Set the error text appropriately
                            if let targetUrl: URL = URL(string: linkPreviewURL), targetUrl.scheme?.lowercased() != "https" {
                                // This error case is handled already in the 'subtitleLabel' creation
                            }
                            else {
                                self?.subtitleLabel.font = UIFont.systemFont(ofSize: Values.verySmallFontSize)
                                self?.subtitleLabel.text = "vc_share_link_previews_error".localized()
                                self?.subtitleLabel.themeTextColor = (self?.mode == .attachmentApproval ?
                                    .textSecondary :
                                    .primary
                                )
                                self?.subtitleLabel.textAlignment = .left
                            }
                    }
                },
                receiveValue: { [weak self] draft in
                    // TODO: Look at refactoring this behaviour to consolidate attachment mutations
                    self?.attachment.linkPreviewDraft = draft
                    self?.linkPreviewInfo = (url: linkPreviewURL, draft: draft)
                    
                    // Update the UI
                    self?.titleLabel.text = (draft.title ?? self?.titleLabel.text)
                    self?.loadingView.alpha = 0
                    self?.loadingView.stopAnimating()
                    self?.imageView.alpha = 1
                    
                    if let jpegImageData: Data = draft.jpegImageData, let loadedImage: UIImage = UIImage(data: jpegImageData) {
                        self?.imageView.image = loadedImage
                        self?.imageView.contentMode = .scaleAspectFill
                    }
                }
            )
            .store(in: &disposables)
    }
}
