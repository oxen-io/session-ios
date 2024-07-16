// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit
import SessionSnodeKit

extension ContextMenuVC {
    final class ActionView: UIView {
        private static let iconSize: CGFloat = 16
        private static let iconImageViewSize: CGFloat = 24
        
        private let dependencies: Dependencies
        private let action: Action
        private let dismiss: () -> Void
        private var didTouchDownInside: Bool = false
        private var timer: Timer?
        
        // MARK: - UI
        
        private lazy var iconImageView: UIImageView = {
            let result: UIImageView = UIImageView()
            result.contentMode = .center
            result.themeTintColor = action.themeColor
            result.set(.width, to: ActionView.iconImageViewSize)
            result.set(.height, to: ActionView.iconImageViewSize)
            
            return result
        }()
        
        private lazy var titleLabel: UILabel = {
            let result: UILabel = UILabel()
            result.font = .systemFont(ofSize: Values.mediumFontSize)
            result.themeTextColor = action.themeColor
            
            return result
        }()
        
        private lazy var subtitleLabel: UILabel = {
            let result: UILabel = UILabel()
            result.font = .systemFont(ofSize: Values.miniFontSize)
            result.themeTextColor = action.themeColor
            
            return result
        }()
        
        private lazy var labelContainer: UIView = {
            let result: UIView = UIView()
            result.addSubview(titleLabel)
            result.addSubview(subtitleLabel)
            titleLabel.pin([ UIView.HorizontalEdge.leading, UIView.HorizontalEdge.trailing, UIView.VerticalEdge.top ], to: result)
            subtitleLabel.pin([ UIView.HorizontalEdge.leading, UIView.HorizontalEdge.trailing, UIView.VerticalEdge.bottom ], to: result)
            titleLabel.pin(.bottom, to: .top, of: subtitleLabel)
            
            return result
        }()
        
        private lazy var subtitleWidthConstraint = labelContainer.set(.width, greaterThanOrEqualTo: 115)

        // MARK: - Lifecycle
        
        init(for action: Action, using dependencies: Dependencies, dismiss: @escaping () -> Void) {
            self.dependencies = dependencies
            self.action = action
            self.dismiss = dismiss
            
            super.init(frame: CGRect.zero)
            self.accessibilityLabel = action.accessibilityLabel
            setUpViewHierarchy()
        }

        override init(frame: CGRect) {
            preconditionFailure("Use init(for:) instead.")
        }

        required init?(coder: NSCoder) {
            preconditionFailure("Use init(for:) instead.")
        }

        private func setUpViewHierarchy() {
            themeBackgroundColor = .clear
            
            iconImageView.image = action.icon?
                .resized(to: CGSize(width: ActionView.iconSize, height: ActionView.iconSize))?
                .withRenderingMode(.alwaysTemplate)
            titleLabel.text = action.title
            setUpSubtitle()
            
            // Stack view
            let stackView: UIStackView = UIStackView(arrangedSubviews: [ iconImageView, labelContainer ])
            stackView.axis = .horizontal
            stackView.spacing = Values.smallSpacing
            stackView.alignment = .center
            stackView.isLayoutMarginsRelativeArrangement = true
            
            let smallSpacing = Values.smallSpacing
            stackView.layoutMargins = UIEdgeInsets(
                top: smallSpacing,
                leading: smallSpacing,
                bottom: smallSpacing,
                trailing: Values.mediumSpacing
            )
            addSubview(stackView)
            stackView.pin(to: self)
            
            // Tap gesture recognizer
            let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            addGestureRecognizer(tapGestureRecognizer)
        }
        
        private func setUpSubtitle() {
            guard 
                let expiresInSeconds = self.action.expirationInfo?.expiresInSeconds,
                let expiresStartedAtMs = self.action.expirationInfo?.expiresStartedAtMs
            else {
                subtitleLabel.isHidden = true
                subtitleWidthConstraint.isActive = false
                return
            }
            
            subtitleLabel.isHidden = false
            subtitleWidthConstraint.isActive = true
            // To prevent a negative timer
            let timeToExpireInSeconds: TimeInterval =  max(0, (expiresStartedAtMs + expiresInSeconds * 1000 - dependencies[cache: .snodeAPI].currentOffsetTimestampMs()) / 1000)
            subtitleLabel.text = String(format: "DISAPPEARING_MESSAGES_AUTO_DELETES_COUNT_DOWN".localized(), timeToExpireInSeconds.formatted(format: .twoUnits))
            
            timer = Timer.scheduledTimerOnMainThread(withTimeInterval: 1, repeats: true, using: dependencies, block: { [weak self, dependencies] _ in
                let timeToExpireInSeconds: TimeInterval =  (expiresStartedAtMs + expiresInSeconds * 1000 - dependencies[cache: .snodeAPI].currentOffsetTimestampMs()) / 1000
                if timeToExpireInSeconds <= 0 {
                    self?.dismissWithTimerInvalidationIfNeeded()
                } else {
                    self?.subtitleLabel.text = String(format: "DISAPPEARING_MESSAGES_AUTO_DELETES_COUNT_DOWN".localized(), timeToExpireInSeconds.formatted(format: .twoUnits))
                }
            })
        }
        
        override func removeFromSuperview() {
            self.timer?.invalidate()
            super.removeFromSuperview()
        }
        
        // MARK: - Interaction
        
        private func dismissWithTimerInvalidationIfNeeded() {
            self.timer?.invalidate()
            dismiss()
        }
        
        @objc private func handleTap() {
            action.work()
            dismissWithTimerInvalidationIfNeeded()
        }
        
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard
                isUserInteractionEnabled,
                let location: CGPoint = touches.first?.location(in: self),
                bounds.contains(location)
            else { return }
            
            didTouchDownInside = true
            themeBackgroundColor = .contextMenu_highlight
            iconImageView.themeTintColor = .contextMenu_textHighlight
            titleLabel.themeTextColor = .contextMenu_textHighlight
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard
                isUserInteractionEnabled,
                let location: CGPoint = touches.first?.location(in: self),
                bounds.contains(location),
                didTouchDownInside
            else {
                if didTouchDownInside {
                    themeBackgroundColor = .clear
                    iconImageView.themeTintColor = .contextMenu_text
                    titleLabel.themeTextColor = .contextMenu_text
                }
                return
            }
            
            themeBackgroundColor = .contextMenu_highlight
            iconImageView.themeTintColor = .contextMenu_textHighlight
            titleLabel.themeTextColor = .contextMenu_textHighlight
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            if didTouchDownInside {
                themeBackgroundColor = .clear
                iconImageView.themeTintColor = .contextMenu_text
                titleLabel.themeTextColor = .contextMenu_text
            }
            
            didTouchDownInside = false
        }
        
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            if didTouchDownInside {
                themeBackgroundColor = .clear
                iconImageView.themeTintColor = .contextMenu_text
                titleLabel.themeTextColor = .contextMenu_text
            }
            
            didTouchDownInside = false
        }
    }
}
