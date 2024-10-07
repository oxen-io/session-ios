// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

// FIXME: Refactor as part of the Groups Rebuild
public class ConfirmationModal: Modal, UITextFieldDelegate, UITextViewDelegate {
    public static let explanationFont: UIFont = .systemFont(ofSize: Values.smallFontSize)
    private static let closeSize: CGFloat = 24
    
    public private(set) var info: Info
    private var internalOnConfirm: ((ConfirmationModal) -> ())? = nil
    private var internalOnCancel: ((ConfirmationModal) -> ())? = nil
    private var internalOnBodyTap: ((@escaping (ValueUpdate) -> Void) -> Void)? = nil
    private var internalOnTextChanged: ((String, String) -> ())? = nil
    
    // MARK: - Components
    
    private lazy var contentTapGestureRecognizer: UITapGestureRecognizer = {
        let result: UITapGestureRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(contentViewTapped)
        )
        contentView.addGestureRecognizer(result)
        result.isEnabled = false
        
        return result
    }()
    
    private lazy var imageViewTapGestureRecognizer: UITapGestureRecognizer = {
        let result: UITapGestureRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(imageViewTapped)
        )
        imageViewContainer.addGestureRecognizer(result)
        result.isEnabled = false
        
        return result
    }()
    
    private lazy var titleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .alert_text
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        
        return result
    }()
    
    private lazy var explanationLabel: ScrollableLabel = {
        let result: ScrollableLabel = ScrollableLabel()
        result.font = ConfirmationModal.explanationFont
        result.themeTextColor = .alert_text
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        
        return result
    }()
    
    private lazy var textFieldContainer: UIView = {
        let result: UIView = UIView()
        result.themeBorderColor = .borderSeparator
        result.layer.cornerRadius = 11
        result.layer.borderWidth = 1
        result.isHidden = true
        result.set(.height, to: 40)
        
        return result
    }()
    
    private lazy var textField: UITextField = {
        let result: UITextField = UITextField()
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.themeTextColor = .textPrimary
        result.delegate = self
        
        return result
    }()
    
    private lazy var textViewContainer: UIView = {
        let result: UIView = UIView()
        result.themeBorderColor = .borderSeparator
        result.layer.cornerRadius = 11
        result.layer.borderWidth = 1
        result.isHidden = true
        result.set(.height, to: 75)
        
        return result
    }()
    
    private lazy var textView: UITextView = {
        let result: UITextView = UITextView()
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.themeTextColor = .textPrimary
        result.themeBackgroundColor = .clear
        result.textContainerInset = .zero
        result.textContainer.lineFragmentPadding = 0
        result.delegate = self
        
        return result
    }()
    
    private lazy var textViewPlaceholder: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.themeTextColor = .textSecondary
        result.alpha = 0.5
        
        return result
    }()
    
    private lazy var imageViewContainer: UIView = {
        let result: UIView = UIView()
        result.isHidden = true
        
        return result
    }()
    
    private lazy var profileView: ProfilePictureView = ProfilePictureView(size: .hero)
    
    private lazy var confirmButton: UIButton = {
        let result: UIButton = Modal.createButton(
            title: "",
            titleColor: .danger
        )
        result.addTarget(self, action: #selector(confirmationPressed), for: .touchUpInside)
        
        return result
    }()
    
    private lazy var buttonStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ confirmButton, cancelButton ])
        result.axis = .horizontal
        result.distribution = .fillEqually
        
        return result
    }()
    
    private lazy var contentStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ titleLabel, explanationLabel, textFieldContainer, textViewContainer, imageViewContainer ])
        result.axis = .vertical
        result.spacing = Values.smallSpacing
        result.isLayoutMarginsRelativeArrangement = true
        result.layoutMargins = UIEdgeInsets(
            top: Values.largeSpacing,
            left: Values.veryLargeSpacing,
            bottom: Values.verySmallSpacing,
            right: Values.veryLargeSpacing
        )
        
        return result
    }()
    
    private lazy var mainStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ contentStackView, buttonStackView ])
        result.axis = .vertical
        
        return result
    }()
    
    private lazy var closeButton: UIButton = UIButton(primaryAction: UIAction { [weak self] _ in self?.close() })
        .withConfiguration(
            UIButton.Configuration
                .plain()
                .withImage(UIImage(named: "X")?.withRenderingMode(.alwaysTemplate))
                .withContentInsets(NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
        )
        .withConfigurationUpdateHandler { button in
            switch button.state {
                case .highlighted: button.imageView?.tintAdjustmentMode = .dimmed
                default: button.imageView?.tintAdjustmentMode = .normal
            }
        }
        .withImageViewContentMode(.scaleAspectFit)
        .withThemeTintColor(.textPrimary)
        .withAccessibility(
            identifier: "Close button",
            label: "Close button"
        )
        .with(.width, of: ConfirmationModal.closeSize)
        .with(.height, of: ConfirmationModal.closeSize)
        .withHidden(true)
    
    // MARK: - Lifecycle
    
    public init(targetView: UIView? = nil, info: Info) {
        self.info = info
        
        super.init(targetView: targetView, dismissType: info.dismissType, afterClosed: info.afterClosed)
        
        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
        self.updateContent(with: info)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func populateContentView() {
        let gestureRecogniser: UITapGestureRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(contentViewTapped)
        )
        contentView.addGestureRecognizer(gestureRecogniser)
        
        contentView.addSubview(mainStackView)
        contentView.addSubview(closeButton)
        
        textFieldContainer.addSubview(textField)
        textField.pin(to: textFieldContainer, withInset: 12)
        
        textViewContainer.addSubview(textView)
        textViewContainer.addSubview(textViewPlaceholder)
        textView.pin(to: textViewContainer, withInset: 12)
        textViewPlaceholder.pin(.top, to: .top, of: textViewContainer, withInset: 12)
        textViewPlaceholder.pin(.leading, to: .leading, of: textViewContainer, withInset: 12)
        textViewPlaceholder.pin(.trailing, to: .trailing, of: textViewContainer, withInset: -12)
        
        imageViewContainer.addSubview(profileView)
        profileView.center(.horizontal, in: imageViewContainer)
        profileView.pin(.top, to: .top, of: imageViewContainer)
        profileView.pin(.bottom, to: .bottom, of: imageViewContainer)
        
        mainStackView.pin(to: contentView)
        closeButton.pin(.top, to: .top, of: contentView, withInset: 8)
        closeButton.pin(.right, to: .right, of: contentView, withInset: -8)
    }
    
    // MARK: - Content
    
    public func updateContent(with info: Info) {
        self.info = info
        internalOnBodyTap = nil
        internalOnTextChanged = nil
        internalOnConfirm = { modal in
            if info.dismissOnConfirm {
                modal.close()
            }
            
            info.onConfirm?(modal)
        }
        internalOnCancel = { modal in
            guard info.onCancel != nil else { return modal.close() }
            
            info.onCancel?(modal)
        }
        contentTapGestureRecognizer.isEnabled = true
        imageViewTapGestureRecognizer.isEnabled = false
        
        // Set the content based on the provided info
        titleLabel.text = info.title
        
        switch info.body {
            case .none:
                mainStackView.spacing = Values.smallSpacing
                
            case .text(let text, let canScroll):
                mainStackView.spacing = Values.smallSpacing
                explanationLabel.text = text
                explanationLabel.canScroll = canScroll
                explanationLabel.isHidden = false
                
            case .attributedText(let attributedText, let canScroll):
                mainStackView.spacing = Values.smallSpacing
                explanationLabel.attributedText = attributedText
                explanationLabel.canScroll = canScroll
                explanationLabel.isHidden = false
                
            case .input(let explanation, let inputInfo, let onTextChanged):
                explanationLabel.attributedText = explanation
                explanationLabel.canScroll = false
                explanationLabel.isHidden = (explanation == nil)
                textField.placeholder = inputInfo.placeholder
                textField.text = (inputInfo.initialValue ?? "")
                textField.clearButtonMode = (inputInfo.clearButton ? .always : .never)
                textFieldContainer.isHidden = false
                internalOnTextChanged = { [weak confirmButton, weak cancelButton] text, _ in
                    onTextChanged(text)
                    confirmButton?.isEnabled = info.confirmEnabled.isValid(with: info)
                    cancelButton?.isEnabled = info.cancelEnabled.isValid(with: info)
                }
                
            case .dualInput(let explanation, let firstInputInfo, let secondInputInfo, let onTextChanged):
                explanationLabel.attributedText = explanation
                explanationLabel.canScroll = false
                explanationLabel.isHidden = (explanation == nil)
                textField.placeholder = firstInputInfo.placeholder
                textField.text = (firstInputInfo.initialValue ?? "")
                textField.clearButtonMode = (firstInputInfo.clearButton ? .always : .never)
                textFieldContainer.isHidden = false
                textView.text = (secondInputInfo.initialValue ?? "")
                textViewPlaceholder.text = secondInputInfo.placeholder
                textViewPlaceholder.isHidden = !textView.text.isEmpty
                textViewContainer.isHidden = false
                internalOnTextChanged = { [weak confirmButton, weak cancelButton] firstText, secondText in
                    onTextChanged(firstText, secondText)
                    confirmButton?.isEnabled = info.confirmEnabled.isValid(with: info)
                    cancelButton?.isEnabled = info.cancelEnabled.isValid(with: info)
                }
                
            case .radio(let explanation, let options):
                mainStackView.spacing = 0
                explanationLabel.attributedText = explanation
                explanationLabel.canScroll = false
                explanationLabel.isHidden = (explanation == nil)
                contentStackView.subviews.forEach { subview in
                    guard subview is RadioButton else { return }
                    
                    subview.removeFromSuperview()
                }
                
                // Add the options
                options.enumerated().forEach { index, optionInfo in
                    let radioButton: RadioButton = RadioButton(size: .medium) { [weak self] button in
                        guard !button.isSelected else { return }
                        
                        // If an option is selected then update the modal to show that one as selected
                        self?.updateContent(
                            with: info.with(
                                body: .radio(
                                    explanation: explanation,
                                    options: options.enumerated().map { otherIndex, otherInfo in
                                        (otherInfo.title, (index == otherIndex), otherInfo.accessibility)
                                    }
                                )
                            )
                        )
                    }
                    radioButton.text = optionInfo.title
                    radioButton.accessibilityLabel = optionInfo.accessibility?.label
                    radioButton.accessibilityIdentifier = optionInfo.accessibility?.identifier
                    radioButton.update(isSelected: optionInfo.selected)
                    contentStackView.addArrangedSubview(radioButton)
                }
                
            case .image(let placeholder, let value, let icon, let style, let accessibility, let onClick):
                imageViewContainer.isAccessibilityElement = (accessibility != nil)
                imageViewContainer.accessibilityIdentifier = accessibility?.identifier
                imageViewContainer.accessibilityLabel = accessibility?.label
                mainStackView.spacing = 0
                imageViewContainer.isHidden = false
                profileView.clipsToBounds = (style == .circular)
                profileView.update(
                    ProfilePictureView.Info(
                        imageData: (value ?? placeholder),
                        icon: icon
                    )
                )
                internalOnBodyTap = onClick
                contentTapGestureRecognizer.isEnabled = false
                imageViewTapGestureRecognizer.isEnabled = true
        }
        
        confirmButton.accessibilityLabel = info.confirmAccessibility?.label
        confirmButton.accessibilityIdentifier = info.confirmAccessibility?.identifier
        confirmButton.isAccessibilityElement = true
        confirmButton.setTitle(info.confirmTitle, for: .normal)
        confirmButton.setThemeTitleColor(info.confirmStyle, for: .normal)
        confirmButton.setThemeTitleColor(.disabled, for: .disabled)
        confirmButton.isHidden = (info.confirmTitle == nil)
        confirmButton.isEnabled = info.confirmEnabled.isValid(with: info)
        cancelButton.accessibilityLabel = info.cancelAccessibility?.label
        cancelButton.accessibilityIdentifier = info.cancelAccessibility?.identifier
        cancelButton.isAccessibilityElement = true
        cancelButton.setTitle(info.cancelTitle, for: .normal)
        cancelButton.setThemeTitleColor(info.cancelStyle, for: .normal)
        cancelButton.setThemeTitleColor(.disabled, for: .disabled)
        cancelButton.isEnabled = info.cancelEnabled.isValid(with: info)
        closeButton.isHidden = !info.hasCloseButton
        
        contentView.accessibilityLabel = info.accessibility?.label
        contentView.accessibilityIdentifier = info.accessibility?.identifier
    }
    
    // MARK: - UITextFieldDelegate
        
    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
    
    public func textFieldShouldClear(_ textField: UITextField) -> Bool {
        internalOnTextChanged?("", textView.text)
        return true
    }
    
    public func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        if let text: String = textField.text, let textRange: Range = Range(range, in: text) {
            let updatedText = text.replacingCharacters(in: textRange, with: string)
            
            internalOnTextChanged?(updatedText, textView.text)
        }
        
        return true
    }
    
    // MARK: - UITextViewDelegate
    
    public func textViewDidChange(_ textView: UITextView) {
        textViewPlaceholder.isHidden = !textView.text.isEmpty
        internalOnTextChanged?((textField.text ?? ""), textView.text)
    }
    
    // MARK: - Interaction
    
    @objc private func contentViewTapped() {
        if textField.isFirstResponder {
            textField.resignFirstResponder()
        }
        if textView.isFirstResponder {
            textView.resignFirstResponder()
        }
        
        internalOnBodyTap?({ _ in })
    }
    
    @objc private func imageViewTapped() {
        internalOnBodyTap?({ [weak self, info = self.info] valueUpdate in
            switch (valueUpdate, info.body) {
                case (.image(let updatedValueData), .image(let placeholderData, _, let icon, let style, let accessibility, let onClick)):
                    self?.updateContent(
                        with: info.with(
                            body: .image(
                                placeholderData: placeholderData,
                                valueData: updatedValueData,
                                icon: icon,
                                style: style,
                                accessibility: accessibility,
                                onClick: onClick
                            )
                        )
                    )
                    
                default: break
            }
        })
    }
    
    @objc internal func confirmationPressed() {
        internalOnConfirm?(self)
    }
    
    override public func cancel() {
        internalOnCancel?(self)
    }
}

// MARK: - Types

public extension ConfirmationModal {
    enum ValueUpdate {
        case input(String)
        case image(Data?)
    }
    
    struct Info: Equatable, Hashable {
        internal let title: String
        public let body: Body
        let accessibility: Accessibility?
        public let showCondition: ShowCondition
        internal let confirmTitle: String?
        let confirmAccessibility: Accessibility?
        let confirmStyle: ThemeValue
        let confirmEnabled: ButtonValidator
        internal let cancelTitle: String
        let cancelAccessibility: Accessibility?
        let cancelStyle: ThemeValue
        let cancelEnabled: ButtonValidator
        let hasCloseButton: Bool
        let dismissOnConfirm: Bool
        let dismissType: Modal.DismissType
        let onConfirm: ((ConfirmationModal) -> ())?
        let onCancel: ((ConfirmationModal) -> ())?
        let afterClosed: (() -> ())?
        
        // MARK: - Initialization
        
        public init(
            title: String,
            body: Body = .none,
            accessibility: Accessibility? = nil,
            showCondition: ShowCondition = .none,
            confirmTitle: String? = nil,
            confirmAccessibility: Accessibility? = nil,
            confirmStyle: ThemeValue = .alert_text,
            confirmEnabled: ButtonValidator = true,
            cancelTitle: String = SNUIKit.localizedString(for: "cancel"),
            cancelAccessibility: Accessibility? = Accessibility(
                identifier: "Cancel button"
            ),
            cancelStyle: ThemeValue = .danger,
            cancelEnabled: ButtonValidator = true,
            hasCloseButton: Bool = false,
            dismissOnConfirm: Bool = true,
            dismissType: Modal.DismissType = .recursive,
            onConfirm: ((ConfirmationModal) -> ())? = nil,
            onCancel: ((ConfirmationModal) -> ())? = nil,
            afterClosed: (() -> ())? = nil
        ) {
            self.title = title
            self.body = body
            self.accessibility = accessibility
            self.showCondition = showCondition
            self.confirmTitle = confirmTitle
            self.confirmAccessibility = confirmAccessibility
            self.confirmStyle = confirmStyle
            self.confirmEnabled = confirmEnabled
            self.cancelTitle = cancelTitle
            self.cancelAccessibility = cancelAccessibility
            self.cancelStyle = cancelStyle
            self.cancelEnabled = cancelEnabled
            self.hasCloseButton = hasCloseButton
            self.dismissOnConfirm = dismissOnConfirm
            self.dismissType = dismissType
            self.onConfirm = onConfirm
            self.onCancel = onCancel
            self.afterClosed = afterClosed
        }
        
        // MARK: - Mutation
        
        public func with(
            body: Body? = nil,
            onConfirm: ((ConfirmationModal) -> ())? = nil,
            onCancel: ((ConfirmationModal) -> ())? = nil,
            afterClosed: (() -> ())? = nil
        ) -> Info {
            return Info(
                title: self.title,
                body: (body ?? self.body),
                accessibility: self.accessibility,
                showCondition: self.showCondition,
                confirmTitle: self.confirmTitle,
                confirmAccessibility: self.confirmAccessibility,
                confirmStyle: self.confirmStyle,
                confirmEnabled: self.confirmEnabled,
                cancelTitle: self.cancelTitle,
                cancelAccessibility: self.cancelAccessibility,
                cancelStyle: self.cancelStyle,
                cancelEnabled: self.cancelEnabled,
                hasCloseButton: self.hasCloseButton,
                dismissOnConfirm: self.dismissOnConfirm,
                dismissType: self.dismissType,
                onConfirm: (onConfirm ?? self.onConfirm),
                onCancel: (onCancel ?? self.onCancel),
                afterClosed: (afterClosed ?? self.afterClosed)
            )
        }
        
        // MARK: - Confirmance
        
        public static func == (lhs: ConfirmationModal.Info, rhs: ConfirmationModal.Info) -> Bool {
            return (
                lhs.title == rhs.title &&
                lhs.body == rhs.body &&
                lhs.accessibility == rhs.accessibility &&
                lhs.showCondition == rhs.showCondition &&
                lhs.confirmTitle == rhs.confirmTitle &&
                lhs.confirmAccessibility == rhs.confirmAccessibility &&
                lhs.confirmStyle == rhs.confirmStyle &&
                lhs.confirmEnabled.isValid(with: lhs) == rhs.confirmEnabled.isValid(with: rhs) &&
                lhs.cancelTitle == rhs.cancelTitle &&
                lhs.cancelAccessibility == rhs.cancelAccessibility &&
                lhs.cancelStyle == rhs.cancelStyle &&
                lhs.cancelEnabled.isValid(with: lhs) == rhs.cancelEnabled.isValid(with: rhs) &&
                lhs.hasCloseButton == rhs.hasCloseButton &&
                lhs.dismissOnConfirm == rhs.dismissOnConfirm &&
                lhs.dismissType == rhs.dismissType
            )
        }
        
        public func hash(into hasher: inout Hasher) {
            title.hash(into: &hasher)
            body.hash(into: &hasher)
            accessibility.hash(into: &hasher)
            showCondition.hash(into: &hasher)
            confirmTitle.hash(into: &hasher)
            confirmAccessibility.hash(into: &hasher)
            confirmStyle.hash(into: &hasher)
            confirmEnabled.isValid(with: self).hash(into: &hasher)
            cancelTitle.hash(into: &hasher)
            cancelAccessibility.hash(into: &hasher)
            cancelStyle.hash(into: &hasher)
            cancelEnabled.isValid(with: self).hash(into: &hasher)
            hasCloseButton.hash(into: &hasher)
            dismissOnConfirm.hash(into: &hasher)
            dismissType.hash(into: &hasher)
        }
    }
}

public extension ConfirmationModal.Info {
    // MARK: - ButtonValidator
    
    class ButtonValidator: ExpressibleByBooleanLiteral {
        public typealias BooleanLiteralType = Bool
        
        /// Storage for the bool literal - should only ever access this via the `isValid` function which allows us to
        /// override the result for other validator types
        private let boolValue: Bool
        
        required public init(booleanLiteral value: BooleanLiteralType) {
            boolValue = value
        }
        
        func isValid(with info: ConfirmationModal.Info) -> Bool { boolValue }
    }
    
    class AfterChangeValidator: ButtonValidator {
        let isValid: (ConfirmationModal.Info) -> Bool
        
        required public init(booleanLiteral value: BooleanLiteralType) {
            isValid = { _ in value }
            
            super.init(booleanLiteral: value)
        }
        
        public init(isValid: @escaping (ConfirmationModal.Info) -> Bool) {
            self.isValid = isValid
            
            /// Default this value to false (we won't use it directly anywhere
            super.init(booleanLiteral: false)
        }
        
        public override func isValid(with info: ConfirmationModal.Info) -> Bool { return self.isValid(info) }
    }
        
    // MARK: - ShowCondition
    
    enum ShowCondition {
        case none
        case enabled
        case disabled
        
        public func shouldShow(for value: Bool) -> Bool {
            switch self {
                case .none: return true
                case .enabled: return (value == true)
                case .disabled: return (value == false)
            }
        }
    }
    
    // MARK: - Body
    
    enum Body: Equatable, Hashable {
        public struct InputInfo: Equatable, Hashable {
            public let placeholder: String
            public let initialValue: String?
            public let clearButton: Bool
            
            public init(
                placeholder: String,
                initialValue: String? = nil,
                clearButton: Bool = false
            ) {
                self.placeholder = placeholder
                self.initialValue = initialValue
                self.clearButton = clearButton
            }
        }
        public enum ImageStyle: Equatable, Hashable {
            case inherit
            case circular
        }
        
        case none
        case text(
            _ text: String,
            canScroll: Bool = false
        )
        case attributedText(
            _ attributedText: NSAttributedString,
            canScroll: Bool = false
        )
        case input(
            explanation: NSAttributedString?,
            info: InputInfo,
            onChange: (String) -> ()
        )
        case dualInput(
            explanation: NSAttributedString?,
            firstInfo: InputInfo,
            secondInfo: InputInfo,
            onChange: (String, String) -> ()
        )
        case radio(
            explanation: NSAttributedString?,
            options: [(
                title: String,
                selected: Bool,
                accessibility: Accessibility?
            )]
        )
        case image(
            placeholderData: Data?,
            valueData: Data?,
            icon: ProfilePictureView.ProfileIcon = .none,
            style: ImageStyle,
            accessibility: Accessibility?,
            onClick: ((@escaping (ConfirmationModal.ValueUpdate) -> Void) -> Void)
        )
        
        public static func == (lhs: ConfirmationModal.Info.Body, rhs: ConfirmationModal.Info.Body) -> Bool {
            switch (lhs, rhs) {
                case (.none, .none): return true
                case (.text(let lhsText, _), .text(let rhsText, _)): return (lhsText == rhsText)
                case (.attributedText(let lhsText, _), .attributedText(let rhsText, _)): return (lhsText == rhsText)
                
                case (.input(let lhsExplanation, let lhsInfo, _), .input(let rhsExplanation, let rhsInfo, _)):
                   return (
                       lhsExplanation == rhsExplanation &&
                       lhsInfo == rhsInfo
                   )
                    
                case (.dualInput(let lhsExplanation, let lhsFirstInfo, let lhsSecondInfo, _), .dualInput(let rhsExplanation, let rhsFirstInfo, let rhsSecondInfo, _)):
                   return (
                       lhsExplanation == rhsExplanation &&
                       lhsFirstInfo == rhsFirstInfo &&
                       lhsSecondInfo == rhsSecondInfo
                   )
                
                case (.radio(let lhsExplanation, let lhsOptions), .radio(let rhsExplanation, let rhsOptions)):
                    return (
                        lhsExplanation == rhsExplanation &&
                        lhsOptions.map { "\($0.0)-\($0.1)" } == rhsOptions.map { "\($0.0)-\($0.1)" }
                    )
                    
                case (.image(let lhsPlaceholder, let lhsValue, let lhsIcon, let lhsStyle, let lhsAccessibility, _), .image(let rhsPlaceholder, let rhsValue, let rhsIcon, let rhsStyle, let rhsAccessibility, _)):
                    return (
                        lhsPlaceholder == rhsPlaceholder &&
                        lhsValue == rhsValue &&
                        lhsIcon == rhsIcon &&
                        lhsStyle == rhsStyle &&
                        lhsAccessibility == rhsAccessibility
                    )
                    
                default: return false
            }
        }
        
        public func hash(into hasher: inout Hasher) {
            switch self {
                case .none: break
                case .text(let text, _): text.hash(into: &hasher)
                case .attributedText(let text, _): text.hash(into: &hasher)
                    
                case .input(let explanation, let info, _):
                    explanation.hash(into: &hasher)
                    info.hash(into: &hasher)
                    
                case .dualInput(let explanation, let firstInfo, let secondInfo, _):
                    explanation.hash(into: &hasher)
                    firstInfo.hash(into: &hasher)
                    secondInfo.hash(into: &hasher)
                    
                case .radio(let explanation, let options):
                    explanation.hash(into: &hasher)
                    options.map { "\($0.0)-\($0.1)" }.hash(into: &hasher)
                
                case .image(let placeholder, let value, let icon, let style, let accessibility, _):
                    placeholder.hash(into: &hasher)
                    value.hash(into: &hasher)
                    icon.hash(into: &hasher)
                    style.hash(into: &hasher)
                    accessibility.hash(into: &hasher)
            }
        }
    }
}

// MARK: - DSL

public extension ConfirmationModal.Info.ButtonValidator {
    static func bool(_ isValid: Bool) -> ConfirmationModal.Info.ButtonValidator {
        return ConfirmationModal.Info.ButtonValidator(booleanLiteral: isValid)
    }
    
    static func afterChange(isValid: @escaping (ConfirmationModal.Info) -> Bool) -> ConfirmationModal.Info.AfterChangeValidator {
        return ConfirmationModal.Info.AfterChangeValidator(isValid: isValid)
    }
}
