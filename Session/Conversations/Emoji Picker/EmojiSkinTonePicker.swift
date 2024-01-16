// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SignalCoreKit
import SignalUtilitiesKit

class EmojiSkinTonePicker: UIView {
    let emoji: Emoji
    let preferredSkinTonePermutation: [Emoji.SkinTone]?
    let completion: (EmojiWithSkinTones?) -> Void

    private let referenceOverlay = UIView()
    private let containerView = UIView()

    class func present(
        referenceView: UIView,
        emoji: EmojiWithSkinTones,
        completion: @escaping (EmojiWithSkinTones?) -> Void
    ) -> EmojiSkinTonePicker? {
        guard let baseEmoji = emoji.baseEmoji, baseEmoji.hasSkinTones else { return nil }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let picker = EmojiSkinTonePicker(emoji: emoji, completion: completion)

        guard let superview = referenceView.superview else {
            owsFailDebug("reference is missing superview")
            return nil
        }

        superview.addSubview(picker)

        picker.referenceOverlay.set(.width, to: .width, of: referenceView)
        picker.referenceOverlay.set(.height, to: .height, of: referenceView, withOffset: 30)
        picker.referenceOverlay.pin(.leading, to: .leading, of: referenceView)

        let leadingConstraint = picker.pin(.leading, to: .leading, of: superview)

        picker.layoutIfNeeded()
        
        let halfWidth = picker.bounds.width / 2
        let margin: CGFloat = 8

        if (halfWidth + margin) > referenceView.center.x {
            leadingConstraint.constant = margin
        } else if (halfWidth + margin) > (superview.bounds.width - referenceView.center.x) {
            leadingConstraint.constant = superview.bounds.width - picker.bounds.width - margin
        } else {
            leadingConstraint.constant = referenceView.center.x - halfWidth
        }

        let distanceFromTop = referenceView.frame.minY - superview.bounds.minY
        if distanceFromTop > picker.containerView.bounds.height {
            picker.containerView.pin(.top, to: .top, of: picker)
            picker.referenceOverlay.pin(.top, to: .bottom, of: picker.containerView, withInset: -20)
            picker.referenceOverlay.pin(.bottom, to: .bottom, of: picker)
            picker.pin(.bottom, to: .bottom, of: referenceView)
        } else {
            picker.containerView.pin(.bottom, to: .bottom, of: picker)
            picker.referenceOverlay.pin(.bottom, to: .top, of: picker.containerView, withInset: 20)
            picker.referenceOverlay.pin(.top, to: .top, of: picker)
            picker.pin(.top, to: .top, of: referenceView)
        }

        picker.alpha = 0
        UIView.animate(withDuration: 0.12) { picker.alpha = 1 }

        return picker
    }

    func dismiss() {
        UIView.animate(withDuration: 0.12, animations: { self.alpha = 0 }) { _ in
            self.removeFromSuperview()
        }
    }

    func didChangeLongPress(_ sender: UILongPressGestureRecognizer) {
        guard let singleSelectionButtons = singleSelectionButtons else { return }

        if referenceOverlay.frame.contains(sender.location(in: self)) {
            singleSelectionButtons.forEach { $0.isSelected = false }
        } else {
            let point = sender.location(in: containerView)
            let previouslySelectedButton = singleSelectionButtons.first { $0.isSelected }
            singleSelectionButtons.forEach { $0.isSelected = $0.frame.insetBy(dx: -3, dy: -80).contains(point) }
            let selectedButton = singleSelectionButtons.first { $0.isSelected }

            if let selectedButton = selectedButton, selectedButton != previouslySelectedButton {
                SelectionHapticFeedback().selectionChanged()
            }
        }
    }

    func didEndLongPress(_ sender: UILongPressGestureRecognizer) {
        guard let singleSelectionButtons = singleSelectionButtons else { return }

        let point = sender.location(in: containerView)
        if referenceOverlay.frame.contains(sender.location(in: self)) {
            // Do nothing.
        } else if let selectedButton = singleSelectionButtons.first(where: {
            $0.frame.insetBy(dx: -3, dy: -80).contains(point)
        }) {
            selectedButton.sendActions(for: .touchUpInside)
        } else {
            dismiss()
        }
    }

    init(emoji: EmojiWithSkinTones, completion: @escaping (EmojiWithSkinTones?) -> Void) {
        owsAssertDebug(emoji.baseEmoji!.hasSkinTones)

        self.emoji = emoji.baseEmoji!
        self.preferredSkinTonePermutation = emoji.skinTones
        self.completion = completion

        super.init(frame: .zero)

        layer.shadowOffset = .zero
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4

        referenceOverlay.themeBackgroundColor = .backgroundSecondary
        referenceOverlay.layer.cornerRadius = 9
        addSubview(referenceOverlay)

        containerView.layoutMargins = UIEdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16)
        containerView.themeBackgroundColor = .backgroundSecondary
        containerView.layer.cornerRadius = 11
        addSubview(containerView)
        containerView.set(.width, to: .width, of: self)
        containerView.setCompressionResistance(to: .required)

        if emoji.baseEmoji!.allowsMultipleSkinTones {
            prepareForMultipleSkinTones()
        }
        else {
            prepareForSingleSkinTone()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Single Skin Tone

    private lazy var yellowEmoji = EmojiWithSkinTones(baseEmoji: emoji, skinTones: nil)
    private lazy var yellowButton = button(for: yellowEmoji) { [weak self] emojiWithSkinTone in
        self?.completion(emojiWithSkinTone)
    }

    private var singleSelectionButtons: [UIButton]?
    private func prepareForSingleSkinTone() {
        let hStack = UIStackView()
        hStack.axis = .horizontal
        hStack.spacing = 8
        containerView.addSubview(hStack)
        hStack.pin(toMarginsOf: containerView)

        hStack.addArrangedSubview(yellowButton)

        hStack.addArrangedSubview(.spacer(withWidth: 2))

        let divider = UIView()
        divider.set(.width, to: 1)
        divider.themeBackgroundColor = .borderSeparator
        hStack.addArrangedSubview(divider)

        hStack.addArrangedSubview(.spacer(withWidth: 2))

        let skinToneButtons = self.skinToneButtons(for: emoji) { [weak self] emojiWithSkinTone in
            self?.completion(emojiWithSkinTone)
        }

        singleSelectionButtons = skinToneButtons.map { $0.button }
        singleSelectionButtons?.forEach { hStack.addArrangedSubview($0) }
        singleSelectionButtons?.append(yellowButton)
    }

    // MARK: - Multiple Skin Tones

    private lazy var skinToneComponentEmoji: [Emoji] = {
        guard let skinToneComponentEmoji = emoji.skinToneComponentEmoji else {
            owsFailDebug("missing skin tone component emoji \(emoji)")
            return []
        }
        return skinToneComponentEmoji
    }()

    private var buttonsPerComponentEmojiIndex = [Int: [(Emoji.SkinTone, UIButton)]]()
    private lazy var skinToneButton = button(for: EmojiWithSkinTones(
        baseEmoji: emoji,
        skinTones: .init(repeating: .medium, count: skinToneComponentEmoji.count)
    )) { [weak self] _ in
        guard let self = self else { return }
        guard self.selectedSkinTones.count == self.skinToneComponentEmoji.count else { return }
        self.completion(EmojiWithSkinTones(baseEmoji: self.emoji, skinTones: self.selectedSkinTones))
    }

    private var selectedSkinTones = [Emoji.SkinTone]() {
        didSet {
            if selectedSkinTones.count == skinToneComponentEmoji.count {
                skinToneButton.setTitle(
                    EmojiWithSkinTones(
                        baseEmoji: emoji,
                        skinTones: selectedSkinTones
                    ).rawValue,
                    for: .normal
                )
                skinToneButton.isEnabled = true
                skinToneButton.alpha = 1
            } else {
                skinToneButton.setTitle(
                    EmojiWithSkinTones(
                        baseEmoji: emoji,
                        skinTones: [.medium]
                    ).rawValue,
                    for: .normal
                )
                skinToneButton.isEnabled = false
                skinToneButton.alpha = 0.2
            }
        }
    }

    private var skinTonePerComponentEmojiIndex = [Int: Emoji.SkinTone]() {
        didSet {
            var selectedSkinTones = [Emoji.SkinTone]()
            for idx in skinToneComponentEmoji.indices {
                for (skinTone, button) in buttonsPerComponentEmojiIndex[idx] ?? [] {
                    if skinTonePerComponentEmojiIndex[idx] == skinTone {
                        selectedSkinTones.append(skinTone)
                        button.isSelected = true
                    } else {
                        button.isSelected = false
                    }
                }
            }
            self.selectedSkinTones = selectedSkinTones
        }
    }

    private func prepareForMultipleSkinTones() {
        let vStack = UIStackView()
        vStack.axis = .vertical
        vStack.spacing = 6
        containerView.addSubview(vStack)
        vStack.pin(toMarginsOf: containerView)

        for (idx, emoji) in skinToneComponentEmoji.enumerated() {
            let skinToneButtons = self.skinToneButtons(for: emoji) { [weak self] emojiWithSkinTone in
                self?.skinTonePerComponentEmojiIndex[idx] = emojiWithSkinTone.skinTones?.first
            }
            buttonsPerComponentEmojiIndex[idx] = skinToneButtons

            let hStack = UIStackView(arrangedSubviews: skinToneButtons.map { $0.button })
            hStack.axis = .horizontal
            hStack.spacing = 6
            vStack.addArrangedSubview(hStack)

            skinTonePerComponentEmojiIndex[idx] = preferredSkinTonePermutation?[safe: idx]

            // If there's only one preferred skin tone, all the component emoji use it.
            if preferredSkinTonePermutation?.count == 1 {
                skinTonePerComponentEmojiIndex[idx] = preferredSkinTonePermutation?.first
            } else {
                skinTonePerComponentEmojiIndex[idx] = preferredSkinTonePermutation?[safe: idx]
            }
        }

        let divider = UIView()
        divider.set(.height, to: 1)
        divider.themeBackgroundColor = .borderSeparator
        vStack.addArrangedSubview(divider)

        let leftSpacer = UIView.hStretchingSpacer()
        let middleSpacer = UIView.hStretchingSpacer()
        let rightSpacer = UIView.hStretchingSpacer()

        let hStack = UIStackView(arrangedSubviews: [leftSpacer, yellowButton, middleSpacer, skinToneButton, rightSpacer])
        hStack.axis = .horizontal
        vStack.addArrangedSubview(hStack)

        leftSpacer.set(.width, to: .width, of: rightSpacer)
        middleSpacer.set(.width, to: .width, of: rightSpacer)
    }

    // MARK: - Button Helpers

    func skinToneButtons(for emoji: Emoji, handler: @escaping (EmojiWithSkinTones) -> Void) -> [(skinTone: Emoji.SkinTone, button: UIButton)] {
        var buttons = [(Emoji.SkinTone, UIButton)]()
        for skinTone in Emoji.SkinTone.allCases {
            let emojiWithSkinTone = EmojiWithSkinTones(baseEmoji: emoji, skinTones: [skinTone])
            buttons.append((skinTone, button(for: emojiWithSkinTone, handler: handler)))
        }
        return buttons
    }

    func button(for emoji: EmojiWithSkinTones, handler: @escaping (EmojiWithSkinTones) -> Void) -> UIButton {
        let button = OWSButton { handler(emoji) }
        button.titleLabel?.font = .boldSystemFont(ofSize: 32)
        button.setTitle(emoji.rawValue, for: .normal)
        button.setThemeBackgroundColor(.backgroundPrimary, for: .selected)
        button.layer.cornerRadius = 6
        button.clipsToBounds = true
        button.set(.width, to: 38)
        button.set(.height, to: 38)
        return button
    }
}
