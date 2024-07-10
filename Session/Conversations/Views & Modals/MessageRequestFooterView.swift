// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

class MessageRequestFooterView: UIView {
    private var onBlock: (() -> ())?
    private var onAccept: (() -> ())?
    private var onDecline: (() -> ())?
    
    // MARK: - UI
    
    var messageRequestDescriptionLabelBottomConstraint: NSLayoutConstraint?
    
    lazy var stackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.axis = .vertical
        result.alignment = .fill
        result.distribution = .fill

        return result
    }()
    
    private lazy var descriptionContainerView: UIView = {
        let result: UIView = UIView()
        result.translatesAutoresizingMaskIntoConstraints = false
        
        return result
    }()

    private lazy var descriptionLabel: UILabel = {
        let result: UILabel = UILabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setContentCompressionResistancePriority(.required, for: .vertical)
        result.font = UIFont.systemFont(ofSize: 12)
        result.themeTextColor = .textSecondary
        result.textAlignment = .center
        result.numberOfLines = 0
        result.accessibilityIdentifier = "Control message"
        result.isAccessibilityElement = true

        return result
    }()
    
    private lazy var actionStackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.axis = .horizontal
        result.alignment = .fill
        result.distribution = .fill
        result.spacing = (UIDevice.current.isIPad ? Values.iPadButtonSpacing : 20)

        return result
    }()
    
    private lazy var blockButton: UIButton = {
        let result: UIButton = UIButton()
        result.setCompressionResistance(to: .defaultHigh)
        result.accessibilityLabel = "Block message request"
        result.translatesAutoresizingMaskIntoConstraints = false
        result.clipsToBounds = true
        result.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        result.setTitle("TXT_BLOCK_USER_TITLE".localized(), for: .normal)
        result.setThemeTitleColor(.danger, for: .normal)
        result.addTarget(self, action: #selector(block), for: .touchUpInside)

        return result
    }()

    private lazy var acceptButton: UIButton = {
        let result: SessionButton = SessionButton(style: .bordered, size: .medium)
        result.accessibilityLabel = "Accept message request"
        result.isAccessibilityElement = true
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setTitle("TXT_DELETE_ACCEPT".localized(), for: .normal)
        result.addTarget(self, action: #selector(accept), for: .touchUpInside)

        return result
    }()

    private lazy var declineButton: UIButton = {
        let result: SessionButton = SessionButton(style: .destructive, size: .medium)
        result.accessibilityLabel = "Delete message request"
        result.isAccessibilityElement = true
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setTitle("TXT_DELETE_TITLE".localized(), for: .normal)
        result.addTarget(self, action: #selector(decline), for: .touchUpInside)

        return result
    }()
    
    // MARK: - Initialization
    
    init(
        threadVariant: SessionThread.Variant,
        canWrite: Bool,
        threadIsMessageRequest: Bool,
        threadRequiresApproval: Bool,
        onBlock: @escaping () -> (),
        onAccept: @escaping () -> (),
        onDecline: @escaping () -> ()
    ) {
        super.init(frame: .zero)
        
        self.onBlock = onBlock
        self.onAccept = onAccept
        self.onDecline = onDecline
        self.themeBackgroundColor = .backgroundPrimary
        
        update(
            threadVariant: threadVariant,
            canWrite: canWrite,
            threadIsMessageRequest: threadIsMessageRequest,
            threadRequiresApproval: threadRequiresApproval
        )
        setupLayout()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Layout
    
    private func setupLayout() {
        addSubview(stackView)
        stackView.addArrangedSubview(blockButton)
        stackView.addArrangedSubview(descriptionContainerView)
        stackView.addArrangedSubview(actionStackView)
        
        descriptionContainerView.addSubview(descriptionLabel)
        actionStackView.addArrangedSubview(acceptButton)
        actionStackView.addArrangedSubview(declineButton)
        
        stackView.pin(.top, to: .top, of: self, withInset: 16)
        stackView.pin(.leading, to: .leading, of: self, withInset: 16)
        stackView.pin(.trailing, to: .trailing, of: self, withInset: -16)
        stackView.pin(.bottom, to: .bottom, of: self, withInset: -16)
        
        descriptionLabel.pin(.top, to: .top, of: descriptionContainerView, withInset: 4)
        descriptionLabel.pin(.leading, to: .leading, of: descriptionContainerView, withInset: 20)
        descriptionLabel.pin(.trailing, to: .trailing, of: descriptionContainerView, withInset: -20)
        messageRequestDescriptionLabelBottomConstraint = descriptionLabel.pin(.bottom, to: .bottom, of: descriptionContainerView, withInset: -20)
        actionStackView.pin(.top, to: .bottom, of: descriptionContainerView)

        declineButton.set(.width, to: .width, of: acceptButton)
    }
    
    // MARK: - Content
    
    func update(
        threadVariant: SessionThread.Variant,
        canWrite: Bool,
        threadIsMessageRequest: Bool,
        threadRequiresApproval: Bool
    ) {
        self.isHidden = (!canWrite || (!threadIsMessageRequest && !threadRequiresApproval))
        self.blockButton.isHidden = (
            threadVariant != .contact ||
            threadRequiresApproval
        )
        self.descriptionLabel.text = (threadRequiresApproval ?
            "MESSAGE_REQUEST_PENDING_APPROVAL_INFO".localized() :
            "MESSAGE_REQUESTS_INFO".localized()
        )
        self.actionStackView.isHidden = threadRequiresApproval
        self.messageRequestDescriptionLabelBottomConstraint?.constant = (threadRequiresApproval ? -4 : -20)
    }
    
    // MARK: - Actions
    
    @objc private func block() { onBlock?() }
    @objc private func accept() { onAccept?() }
    @objc private func decline() { onDecline?() }
}
