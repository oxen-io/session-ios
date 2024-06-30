// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit
import SessionMessagingKit
import SignalUtilitiesKit

extension MediaInfoVC {
    final class MediaInfoView: UIView {
        private static let cornerRadius: CGFloat = 12
        
        private var attachment: Attachment?
        private let width: CGFloat = MediaInfoVC.mediaSize - 2 * MediaInfoVC.arrowSize.width
        
        // MARK: - UI
        
        private lazy var fileIdLabel: UILabel = {
            let result: UILabel = UILabel()
            result.font = .systemFont(ofSize: Values.mediumFontSize)
            result.themeTextColor = .textPrimary
            
            return result
        }()
        
        private lazy var fileTypeLabel: UILabel = {
            let result: UILabel = UILabel()
            result.font = .systemFont(ofSize: Values.mediumFontSize)
            result.themeTextColor = .textPrimary
            
            return result
        }()
        
        private lazy var fileSizeLabel: UILabel = {
            let result: UILabel = UILabel()
            result.font = .systemFont(ofSize: Values.mediumFontSize)
            result.themeTextColor = .textPrimary
            
            return result
        }()
        
        private lazy var resolutionLabel: UILabel = {
            let result: UILabel = UILabel()
            result.font = .systemFont(ofSize: Values.mediumFontSize)
            result.themeTextColor = .textPrimary
            
            return result
        }()
        
        private lazy var durationLabel: UILabel = {
            let result: UILabel = UILabel()
            result.font = .systemFont(ofSize: Values.mediumFontSize)
            result.themeTextColor = .textPrimary
            
            return result
        }()
        
        // MARK: - Lifecycle
        
        init(attachment: Attachment?) {
            self.attachment = attachment
            
            super.init(frame: CGRect.zero)
            self.accessibilityLabel = "Media info"
            setUpViewHierarchy()
            update(attachment: attachment)
        }

        override init(frame: CGRect) {
            preconditionFailure("Use init(attachment:) instead.")
        }

        required init?(coder: NSCoder) {
            preconditionFailure("Use init(attachment:) instead.")
        }

        private func setUpViewHierarchy() {
            let backgroundView: UIView = UIView()
            backgroundView.clipsToBounds = true
            backgroundView.themeBackgroundColor = .contextMenu_background
            backgroundView.layer.cornerRadius = Self.cornerRadius
            addSubview(backgroundView)
            backgroundView.pin(to: self)
            
            let container: UIView = UIView()
            container.set(.width, to: self.width)
            
            // File ID
            let fileIdTitleLabel: UILabel = {
                let result = UILabel()
                result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
                result.text = "attachmentsFileId".localized()
                result.themeTextColor = .textPrimary
                
                return result
            }()
            let fileIdContainerStackView: UIStackView = UIStackView(arrangedSubviews: [ fileIdTitleLabel, fileIdLabel ])
            fileIdContainerStackView.axis = .vertical
            fileIdContainerStackView.spacing = 6
            container.addSubview(fileIdContainerStackView)
            fileIdContainerStackView.pin([ UIView.HorizontalEdge.leading, UIView.HorizontalEdge.trailing, UIView.VerticalEdge.top ], to: container)
            
            // File Type
            let fileTypeTitleLabel: UILabel = {
                let result = UILabel()
                result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
                result.text = "attachmentsFileType".localized()
                result.themeTextColor = .textPrimary
                
                return result
            }()
            let fileTypeContainerStackView: UIStackView = UIStackView(arrangedSubviews: [ fileTypeTitleLabel, fileTypeLabel ])
            fileTypeContainerStackView.axis = .vertical
            fileTypeContainerStackView.spacing = 6
            container.addSubview(fileTypeContainerStackView)
            fileTypeContainerStackView.pin(.leading, to: .leading, of: container)
            fileTypeContainerStackView.pin(.top, to: .bottom, of: fileIdContainerStackView, withInset: Values.largeSpacing)
            
            // File Size
            let fileSizeTitleLabel: UILabel = {
                let result = UILabel()
                result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
                result.text = "attachmentsFileSize".localized()
                result.themeTextColor = .textPrimary
                
                return result
            }()
            let fileSizeContainerStackView: UIStackView = UIStackView(arrangedSubviews: [ fileSizeTitleLabel, fileSizeLabel ])
            fileSizeContainerStackView.axis = .vertical
            fileSizeContainerStackView.spacing = 6
            container.addSubview(fileSizeContainerStackView)
            fileSizeContainerStackView.pin(.trailing, to: .trailing, of: container)
            fileSizeContainerStackView.pin(.top, to: .bottom, of: fileIdContainerStackView, withInset: Values.largeSpacing)
            fileSizeContainerStackView.set(.width, to: 90)
            
            // Resolution
            let resolutionTitleLabel: UILabel = {
                let result = UILabel()
                result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
                result.text = "attachmentsResolution".localized()
                result.themeTextColor = .textPrimary
                
                return result
            }()
            let resolutionContainerStackView: UIStackView = UIStackView(arrangedSubviews: [ resolutionTitleLabel, resolutionLabel ])
            resolutionContainerStackView.axis = .vertical
            resolutionContainerStackView.spacing = 6
            container.addSubview(resolutionContainerStackView)
            resolutionContainerStackView.pin(.leading, to: .leading, of: container)
            resolutionContainerStackView.pin(.top, to: .bottom, of: fileTypeContainerStackView, withInset: Values.largeSpacing)
            
            // Duration
            let durationTitleLabel: UILabel = {
                let result = UILabel()
                result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
                result.text = "attachmentsDuration".localized()
                result.themeTextColor = .textPrimary
                
                return result
            }()
            let durationContainerStackView: UIStackView = UIStackView(arrangedSubviews: [ durationTitleLabel, durationLabel ])
            durationContainerStackView.axis = .vertical
            durationContainerStackView.spacing = 6
            container.addSubview(durationContainerStackView)
            durationContainerStackView.pin(.trailing, to: .trailing, of: container)
            durationContainerStackView.pin(.top, to: .bottom, of: fileSizeContainerStackView, withInset: Values.largeSpacing)
            durationContainerStackView.set(.width, to: 90)
            container.pin(.bottom, to: .bottom, of: durationContainerStackView)
            
            backgroundView.addSubview(container)
            container.pin(to: backgroundView, withInset: Values.largeSpacing)
        }
        
        // MARK: - Interaction
        
        public func update(attachment: Attachment?) {
            guard let attachment: Attachment = attachment else { return }
            
            self.attachment = attachment
            
            fileIdLabel.text = attachment.serverId
            fileTypeLabel.text = attachment.contentType
            fileSizeLabel.text = Format.fileSize(attachment.byteCount)
            resolutionLabel.text = {
                guard let width = attachment.width, let height = attachment.height else { return "attachmentsNa".localized() }
                return "\(width)×\(height)"
            }()
            durationLabel.text = {
                guard let duration = attachment.duration else { return "attachmentsNa".localized() }
                return floor(duration).formatted(format: .videoDuration)
            }()
        }
    }
}
