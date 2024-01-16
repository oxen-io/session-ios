// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionUtilitiesKit

public class SessionCell: UITableViewCell {
    public static let cornerRadius: CGFloat = 17
    
    private var isEditingTitle = false
    public private(set) var interactionMode: SessionCell.TextInfo.Interaction = .none
    private var shouldHighlightTitle: Bool = true
    private var originalInputValue: String?
    private var titleExtraView: UIView?
    private var subtitleExtraView: UIView?
    var disposables: Set<AnyCancellable> = Set()
    
    // MARK: - UI
    
    private var backgroundLeftConstraint: NSLayoutConstraint = NSLayoutConstraint()
    private var backgroundRightConstraint: NSLayoutConstraint = NSLayoutConstraint()
    private var topSeparatorLeadingConstraint: NSLayoutConstraint = NSLayoutConstraint()
    private var topSeparatorTrailingConstraint: NSLayoutConstraint = NSLayoutConstraint()
    private var botSeparatorLeadingConstraint: NSLayoutConstraint = NSLayoutConstraint()
    private var botSeparatorTrailingConstraint: NSLayoutConstraint = NSLayoutConstraint()
    private lazy var contentStackViewTopConstraint: NSLayoutConstraint = contentStackView.pin(.top, to: .top, of: cellBackgroundView)
    private lazy var contentStackViewLeadingConstraint: NSLayoutConstraint = contentStackView.pin(.leading, to: .leading, of: cellBackgroundView)
    private lazy var contentStackViewTrailingConstraint: NSLayoutConstraint = contentStackView.pin(.trailing, to: .trailing, of: cellBackgroundView)
    private lazy var contentStackViewBottomConstraint: NSLayoutConstraint = contentStackView.pin(.bottom, to: .bottom, of: cellBackgroundView)
    private lazy var contentStackViewHorizontalCenterConstraint: NSLayoutConstraint = contentStackView.center(.horizontal, in: cellBackgroundView)
    private lazy var leadingAccessoryFillConstraint: NSLayoutConstraint = contentStackView.set(.height, to: .height, of: leadingAccessoryView)
    private lazy var titleTextFieldLeadingConstraint: NSLayoutConstraint = titleTextField.pin(.leading, to: .leading, of: cellBackgroundView)
    private lazy var titleTextFieldTrailingConstraint: NSLayoutConstraint = titleTextField.pin(.trailing, to: .trailing, of: cellBackgroundView)
    private lazy var titleMinHeightConstraint: NSLayoutConstraint = titleStackView.heightAnchor
        .constraint(greaterThanOrEqualTo: titleTextField.heightAnchor)
    private lazy var trailingAccessoryFillConstraint: NSLayoutConstraint = contentStackView.set(.height, to: .height, of: trailingAccessoryView)
    private lazy var accessoryWidthMatchConstraint: NSLayoutConstraint = leadingAccessoryView.set(.width, to: .width, of: trailingAccessoryView)
    
    private let cellBackgroundView: UIView = {
        let result: UIView = UIView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.clipsToBounds = true
        result.themeBackgroundColor = .settings_tabBackground
        
        return result
    }()
    
    private let cellSelectedBackgroundView: UIView = {
        let result: UIView = UIView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.themeBackgroundColor = .highlighted(.settings_tabBackground)
        result.alpha = 0
        
        return result
    }()
    
    private let topSeparator: UIView = {
        let result: UIView = UIView.separator()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.isHidden = true
        
        return result
    }()
    
    private let contentStackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.axis = .horizontal
        result.distribution = .fill
        result.alignment = .center
        result.spacing = Values.mediumSpacing
        
        return result
    }()
    
    public let leadingAccessoryView: AccessoryView = {
        let result: AccessoryView = AccessoryView()
        result.isHidden = true
        
        return result
    }()
    
    private let titleStackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.axis = .vertical
        result.distribution = .equalSpacing
        result.alignment = .fill
        result.setContentHugging(to: .defaultLow)
        result.setCompressionResistance(to: .defaultLow)
        
        return result
    }()
    
    fileprivate let titleLabel: SRCopyableLabel = {
        let result: SRCopyableLabel = SRCopyableLabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.isUserInteractionEnabled = false
        result.themeTextColor = .textPrimary
        result.numberOfLines = 0
        result.setContentHugging(to: .defaultLow)
        result.setCompressionResistance(to: .defaultLow)
        
        return result
    }()
    
    fileprivate let titleTextField: UITextField = {
        let textField: TextField = TextField(placeholder: "", usesDefaultHeight: false)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.textAlignment = .center
        textField.alpha = 0
        textField.isHidden = true
        textField.set(.height, to: Values.largeButtonHeight)
        
        return textField
    }()
    
    private let subtitleLabel: SRCopyableLabel = {
        let result: SRCopyableLabel = SRCopyableLabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.isUserInteractionEnabled = false
        result.font = .systemFont(ofSize: 12)
        result.themeTextColor = .textPrimary
        result.numberOfLines = 0
        result.isHidden = true
        result.setContentHugging(to: .defaultLow)
        result.setCompressionResistance(to: .defaultLow)
        
        return result
    }()
    
    public let trailingAccessoryView: AccessoryView = {
        let result: AccessoryView = AccessoryView()
        result.isHidden = true
        
        return result
    }()
    
    private let botSeparator: UIView = {
        let result: UIView = UIView.separator()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.isHidden = true
        
        return result
    }()
    
    // MARK: - Initialization
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        setupViewHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        setupViewHierarchy()
    }

    private func setupViewHierarchy() {
        self.themeBackgroundColor = .clear
        self.selectedBackgroundView = UIView()
        
        contentView.addSubview(cellBackgroundView)
        cellBackgroundView.addSubview(cellSelectedBackgroundView)
        cellBackgroundView.addSubview(topSeparator)
        cellBackgroundView.addSubview(contentStackView)
        cellBackgroundView.addSubview(botSeparator)
        
        contentStackView.addArrangedSubview(leadingAccessoryView)
        contentStackView.addArrangedSubview(titleStackView)
        contentStackView.addArrangedSubview(trailingAccessoryView)
        
        titleStackView.addArrangedSubview(titleLabel)
        titleStackView.addArrangedSubview(subtitleLabel)
        
        cellBackgroundView.addSubview(titleTextField)
        
        setupLayout()
    }
    
    private func setupLayout() {
        cellBackgroundView.pin(.top, to: .top, of: contentView)
        backgroundLeftConstraint = cellBackgroundView.pin(.leading, to: .leading, of: contentView)
        backgroundRightConstraint = cellBackgroundView.pin(.trailing, to: .trailing, of: contentView)
        cellBackgroundView.pin(.bottom, to: .bottom, of: contentView)
        
        cellSelectedBackgroundView.pin(to: cellBackgroundView)
        
        topSeparator.pin(.top, to: .top, of: cellBackgroundView)
        topSeparatorLeadingConstraint = topSeparator.pin(.leading, to: .leading, of: cellBackgroundView)
        topSeparatorTrailingConstraint = topSeparator.pin(.trailing, to: .trailing, of: cellBackgroundView)
        
        contentStackViewTopConstraint.isActive = true
        contentStackViewBottomConstraint.isActive = true
        
        titleTextField.center(.vertical, in: titleLabel)
        
        botSeparatorLeadingConstraint = botSeparator.pin(.leading, to: .leading, of: cellBackgroundView)
        botSeparatorTrailingConstraint = botSeparator.pin(.trailing, to: .trailing, of: cellBackgroundView)
        botSeparator.pin(.bottom, to: .bottom, of: cellBackgroundView)
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        
        // Need to force the contentStackView to layout if needed as it might not have updated it's
        // sizing yet
        self.contentStackView.layoutIfNeeded()
        repositionExtraView(titleExtraView, for: titleLabel)
        repositionExtraView(subtitleExtraView, for: subtitleLabel)
    }
    
    private func repositionExtraView(_ targetView: UIView?, for label: UILabel) {
        guard
            let targetView: UIView = targetView,
            let content: String = label.text,
            let font: UIFont = label.font
        else { return }
        
        // Position the 'targetView' at the end of the last line of text
        let layoutManager: NSLayoutManager = NSLayoutManager()
        let textStorage = NSTextStorage(
            attributedString: NSAttributedString(
                string: content,
                attributes: [ .font: font ]
            )
        )
        textStorage.addLayoutManager(layoutManager)
        
        let textContainer: NSTextContainer = NSTextContainer(
            size: CGSize(
                width: label.bounds.size.width,
                height: 999
            )
        )
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        
        var glyphRange: NSRange = NSRange()
        layoutManager.characterRange(
            forGlyphRange: NSRange(location: content.glyphCount - 1, length: 1),
            actualGlyphRange: &glyphRange
        )
        let lastGlyphRect: CGRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        
        // Remove and re-add the 'subtitleExtraView' to clear any old constraints
        targetView.removeFromSuperview()
        contentView.addSubview(targetView)
        
        targetView.pin(
            .top,
            to: .top,
            of: label,
            withInset: (lastGlyphRect.minY + ((lastGlyphRect.height / 2) - (targetView.bounds.height / 2)))
        )
        targetView.pin(
            .leading,
            to: .leading,
            of: label,
            withInset: lastGlyphRect.maxX
        )
    }
    
    // MARK: - Content
    
    public override func prepareForReuse() {
        super.prepareForReuse()
        
        isEditingTitle = false
        interactionMode = .none
        shouldHighlightTitle = true
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        isAccessibilityElement = false
        originalInputValue = nil
        titleExtraView?.removeFromSuperview()
        titleExtraView = nil
        subtitleExtraView?.removeFromSuperview()
        subtitleExtraView = nil
        disposables = Set()
        
        contentStackView.spacing = Values.mediumSpacing
        contentStackViewLeadingConstraint.isActive = false
        contentStackViewTrailingConstraint.isActive = false
        contentStackViewHorizontalCenterConstraint.isActive = false
        titleMinHeightConstraint.isActive = false
        leadingAccessoryView.prepareForReuse()
        leadingAccessoryView.alpha = 1
        leadingAccessoryFillConstraint.isActive = false
        titleLabel.text = ""
        titleLabel.textAlignment = .left
        titleLabel.themeTextColor = .textPrimary
        titleLabel.alpha = 1
        titleTextField.text = ""
        titleTextField.textAlignment = .center
        titleTextField.themeTextColor = .textPrimary
        titleTextField.isHidden = true
        titleTextField.alpha = 0
        subtitleLabel.isUserInteractionEnabled = false
        subtitleLabel.attributedText = nil
        subtitleLabel.themeTextColor = .textPrimary
        trailingAccessoryView.prepareForReuse()
        trailingAccessoryView.alpha = 1
        trailingAccessoryFillConstraint.isActive = false
        accessoryWidthMatchConstraint.isActive = false
        
        topSeparator.isHidden = true
        subtitleLabel.isHidden = true
        botSeparator.isHidden = true
    }
    
    public func update<ID: Hashable & Differentiable>(with info: Info<ID>, isManualReload: Bool = false) {
        interactionMode = (info.title?.interaction ?? .none)
        shouldHighlightTitle = (info.title?.interaction != .copy)
        titleExtraView = info.title?.extraViewGenerator?()
        subtitleExtraView = info.subtitle?.extraViewGenerator?()
        accessibilityIdentifier = info.accessibility?.identifier
        accessibilityLabel = info.accessibility?.label
        isAccessibilityElement = true
        originalInputValue = info.title?.text
        
        // Convenience Flags
        let leadingFitToEdge: Bool = (info.leadingAccessory?.shouldFitToEdge == true)
        let trailingFitToEdge: Bool = (!leadingFitToEdge && info.trailingAccessory?.shouldFitToEdge == true)
        
        // Content
        contentStackView.spacing = (info.styling.customPadding?.interItem ?? Values.mediumSpacing)
        leadingAccessoryView.update(
            with: info.leadingAccessory,
            tintColor: info.styling.tintColor,
            isEnabled: info.isEnabled,
            isManualReload: isManualReload
        )
        titleStackView.isHidden = (info.title == nil && info.subtitle == nil)
        titleLabel.isUserInteractionEnabled = (info.title?.interaction == .copy)
        titleLabel.font = info.title?.font
        titleLabel.text = info.title?.text
        titleLabel.themeTextColor = info.styling.tintColor
        titleLabel.textAlignment = (info.title?.textAlignment ?? .left)
        titleLabel.isHidden = (info.title == nil)
        titleTextField.text = info.title?.text
        titleTextField.textAlignment = (info.title?.textAlignment ?? .left)
        titleTextField.placeholder = info.title?.editingPlaceholder
        titleTextField.isHidden = (info.title == nil)
        titleTextField.accessibilityIdentifier = info.accessibility?.identifier
        titleTextField.accessibilityLabel = info.accessibility?.label
        subtitleLabel.isUserInteractionEnabled = (info.subtitle?.interaction == .copy)
        subtitleLabel.font = info.subtitle?.font
        subtitleLabel.attributedText = info.subtitle.map { subtitle -> NSAttributedString? in
            NSAttributedString(stringWithHTMLTags: subtitle.text, font: subtitle.font)
        }
        subtitleLabel.themeTextColor = info.styling.subtitleTintColor
        subtitleLabel.textAlignment = (info.subtitle?.textAlignment ?? .left)
        subtitleLabel.isHidden = (info.subtitle == nil)
        trailingAccessoryView.update(
            with: info.trailingAccessory,
            tintColor: info.styling.tintColor,
            isEnabled: info.isEnabled,
            isManualReload: isManualReload
        )
        
        contentStackViewLeadingConstraint.isActive = (info.styling.alignment == .leading)
        contentStackViewTrailingConstraint.isActive = (info.styling.alignment == .leading)
        contentStackViewHorizontalCenterConstraint.constant = ((info.styling.customPadding?.leading ?? 0) + (info.styling.customPadding?.trailing ?? 0))
        contentStackViewHorizontalCenterConstraint.isActive = (info.styling.alignment == .centerHugging)
        leadingAccessoryFillConstraint.isActive = leadingFitToEdge
        trailingAccessoryFillConstraint.isActive = trailingFitToEdge
        accessoryWidthMatchConstraint.isActive = {
            switch (info.leadingAccessory, info.trailingAccessory) {
                case is (SessionCell.AccessoryConfig.Button, SessionCell.AccessoryConfig.Button): return true
                default: return false
            }
        }()
        titleLabel.setContentHuggingPriority(
            (info.trailingAccessory != nil ? .defaultLow : .required),
            for: .horizontal
        )
        titleLabel.setContentCompressionResistancePriority(
            (info.trailingAccessory != nil ? .defaultLow : .required),
            for: .horizontal
        )
        contentStackViewTopConstraint.constant = {
            if let customPadding: CGFloat = info.styling.customPadding?.top {
                return customPadding
            }
            
            return (leadingFitToEdge || trailingFitToEdge ? 0 : Values.mediumSpacing)
        }()
        contentStackViewLeadingConstraint.constant = {
            if let customPadding: CGFloat = info.styling.customPadding?.leading {
                return customPadding
            }
            
            return (leadingFitToEdge ? 0 : Values.mediumSpacing)
        }()
        contentStackViewTrailingConstraint.constant = {
            if let customPadding: CGFloat = info.styling.customPadding?.trailing {
                return -customPadding
            }
            
            return -(trailingFitToEdge ? 0 : Values.mediumSpacing)
        }()
        contentStackViewBottomConstraint.constant = {
            if let customPadding: CGFloat = info.styling.customPadding?.bottom {
                return -customPadding
            }
            
            return -(leadingFitToEdge || trailingFitToEdge ? 0 : Values.mediumSpacing)
        }()
        titleTextFieldLeadingConstraint.constant = {
            guard info.styling.backgroundStyle != .noBackground else { return 0 }
            
            return (leadingFitToEdge ? 0 : Values.mediumSpacing)
        }()
        titleTextFieldTrailingConstraint.constant = {
            guard info.styling.backgroundStyle != .noBackground else { return 0 }
            
            return -(trailingFitToEdge ? 0 : Values.mediumSpacing)
        }()
        
        // Styling and positioning
        let defaultEdgePadding: CGFloat
        
        switch info.styling.backgroundStyle {
            case .rounded:
                cellBackgroundView.themeBackgroundColor = .settings_tabBackground
                cellSelectedBackgroundView.isHidden = !info.isEnabled
                
                defaultEdgePadding = Values.mediumSpacing
                backgroundLeftConstraint.constant = Values.largeSpacing
                backgroundRightConstraint.constant = -Values.largeSpacing
                cellBackgroundView.layer.cornerRadius = SessionCell.cornerRadius
                
            case .edgeToEdge:
                cellBackgroundView.themeBackgroundColor = .settings_tabBackground
                cellSelectedBackgroundView.isHidden = !info.isEnabled
                
                defaultEdgePadding = 0
                backgroundLeftConstraint.constant = 0
                backgroundRightConstraint.constant = 0
                cellBackgroundView.layer.cornerRadius = 0
                
            case .noBackground:
                defaultEdgePadding = Values.mediumSpacing
                backgroundLeftConstraint.constant = Values.largeSpacing
                backgroundRightConstraint.constant = -Values.largeSpacing
                cellBackgroundView.themeBackgroundColor = nil
                cellBackgroundView.layer.cornerRadius = 0
                cellSelectedBackgroundView.isHidden = true
                
            case .noBackgroundEdgeToEdge:
                defaultEdgePadding = 0
                backgroundLeftConstraint.constant = 0
                backgroundRightConstraint.constant = 0
                cellBackgroundView.themeBackgroundColor = nil
                cellBackgroundView.layer.cornerRadius = 0
                cellSelectedBackgroundView.isHidden = true
        }
        
        let fittedEdgePadding: CGFloat = {
            func targetSize(accessory: Accessory?) -> CGFloat {
                switch accessory {
                    case let accessory as SessionCell.AccessoryConfig.Icon: return accessory.iconSize.size
                    case let accessory as SessionCell.AccessoryConfig.IconAsync: return accessory.iconSize.size
                    default: return defaultEdgePadding
                }
            }
            
            guard leadingFitToEdge else {
                guard trailingFitToEdge else { return defaultEdgePadding }
                
                return targetSize(accessory: info.trailingAccessory)
            }
            
            return targetSize(accessory: info.leadingAccessory)
        }()
        topSeparatorLeadingConstraint.constant = (leadingFitToEdge ? fittedEdgePadding : defaultEdgePadding)
        topSeparatorTrailingConstraint.constant = (trailingFitToEdge ? -fittedEdgePadding : -defaultEdgePadding)
        botSeparatorLeadingConstraint.constant = (leadingFitToEdge ? fittedEdgePadding : defaultEdgePadding)
        botSeparatorTrailingConstraint.constant = (trailingFitToEdge ? -fittedEdgePadding : -defaultEdgePadding)
        
        switch info.position {
            case .top:
                cellBackgroundView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                topSeparator.isHidden = (
                    !info.styling.allowedSeparators.contains(.top) || (
                        info.styling.backgroundStyle != .edgeToEdge &&
                        info.styling.backgroundStyle != .noBackgroundEdgeToEdge
                    )
                )
                botSeparator.isHidden = (
                    !info.styling.allowedSeparators.contains(.bottom) || (
                        info.styling.backgroundStyle == .noBackground &&
                        info.styling.backgroundStyle != .noBackgroundEdgeToEdge
                    )
                )
                
            case .middle:
                cellBackgroundView.layer.maskedCorners = []
                topSeparator.isHidden = true
                botSeparator.isHidden = (
                    !info.styling.allowedSeparators.contains(.bottom) || (
                        info.styling.backgroundStyle == .noBackground &&
                        info.styling.backgroundStyle != .noBackgroundEdgeToEdge
                    )
                )
                
            case .bottom:
                cellBackgroundView.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                topSeparator.isHidden = true
                botSeparator.isHidden = (
                    !info.styling.allowedSeparators.contains(.bottom) || (
                        info.styling.backgroundStyle != .edgeToEdge &&
                        info.styling.backgroundStyle != .noBackgroundEdgeToEdge
                    )
                )
                
            case .individual:
                cellBackgroundView.layer.maskedCorners = [
                    .layerMinXMinYCorner, .layerMaxXMinYCorner,
                    .layerMinXMaxYCorner, .layerMaxXMaxYCorner
                ]
                topSeparator.isHidden = (
                    !info.styling.allowedSeparators.contains(.top) || (
                        info.styling.backgroundStyle != .edgeToEdge &&
                        info.styling.backgroundStyle != .noBackgroundEdgeToEdge
                    )
                )
                botSeparator.isHidden = (
                    !info.styling.allowedSeparators.contains(.bottom) || (
                        info.styling.backgroundStyle != .edgeToEdge &&
                        info.styling.backgroundStyle != .noBackgroundEdgeToEdge
                    )
                )
        }
    }
    
    public func update(isEditing: Bool, becomeFirstResponder: Bool, animated: Bool) {
        // Note: We set 'isUserInteractionEnabled' based on the 'info.isEditable' flag
        // so can use that to determine whether this element can become editable
        guard interactionMode == .editable || interactionMode == .alwaysEditing else { return }
        
        self.isEditingTitle = isEditing
        
        let changes = { [weak self] in
            self?.titleLabel.alpha = (isEditing ? 0 : 1)
            self?.titleTextField.alpha = (isEditing ? 1 : 0)
            self?.leadingAccessoryView.alpha = (isEditing ? 0 : 1)
            self?.trailingAccessoryView.alpha = (isEditing ? 0 : 1)
            self?.titleMinHeightConstraint.isActive = isEditing
        }
        let completion: (Bool) -> Void = { [weak self] complete in
            self?.titleTextField.text = self?.originalInputValue
        }

        if animated {
            UIView.animate(withDuration: 0.25, animations: changes, completion: completion)
        }
        else {
            changes()
            completion(true)
        }

        if isEditing && becomeFirstResponder {
            titleTextField.becomeFirstResponder()
        }
        else if !isEditing {
            titleTextField.resignFirstResponder()
        }
    }
    
    // MARK: - Interaction
    
    public override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        
        // When editing disable the highlighted state changes (would result in UI elements
        // reappearing otherwise)
        guard !self.isEditingTitle else { return }
        
        // If the 'cellSelectedBackgroundView' is hidden then there is no background so we
        // should update the titleLabel to indicate the highlighted state
        if cellSelectedBackgroundView.isHidden && shouldHighlightTitle {
            // Note: We delay the "unhighlight" of the titleLabel so that the transition doesn't
            // conflict with the transition into edit mode
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                guard self?.isEditingTitle == false else { return }
                
                self?.titleLabel.alpha = (highlighted ? 0.8 : 1)
            }
        }

        cellSelectedBackgroundView.alpha = (highlighted ? 1 : 0)
        leadingAccessoryView.setHighlighted(highlighted, animated: animated)
        trailingAccessoryView.setHighlighted(highlighted, animated: animated)
    }
    
    public override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        leadingAccessoryView.setSelected(selected, animated: animated)
        trailingAccessoryView.setSelected(selected, animated: animated)
    }
}

// MARK: - Compose

extension CombineCompatible where Self: SessionCell {
    var textPublisher: AnyPublisher<String, Never> {
        return self.titleTextField.publisher(for: [.editingChanged, .editingDidEnd])
            .handleEvents(
                receiveOutput: { [weak self] textField in
                    // When editing the text update the 'accessibilityLabel' of the cell to match
                    // the text
                    let targetText: String? = (textField.isEditing ? textField.text : self?.titleLabel.text)
                    self?.accessibilityLabel = (targetText ?? self?.accessibilityLabel)
                }
            )
            .filter { $0.isEditing }    // Don't bother sending events for 'editingDidEnd'
            .map { textField -> String in (textField.text ?? "") }
            .eraseToAnyPublisher()
    }
}
