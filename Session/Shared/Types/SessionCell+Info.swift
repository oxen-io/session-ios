// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import DifferenceKit
import SessionUIKit
import SessionMessagingKit

extension SessionCell {
    public struct Info<ID: Hashable & Differentiable>: Equatable, Hashable, Differentiable {
        let id: ID
        let position: Position
        let leadingAccessory: SessionCell.Accessory?
        let title: TextInfo?
        let subtitle: TextInfo?
        let trailingAccessory: SessionCell.Accessory?
        let styling: StyleInfo
        let isEnabled: Bool
        let accessibility: Accessibility?
        let confirmationInfo: ConfirmationModal.Info?
        let onTap: (() -> Void)?
        let onTapView: ((UIView?) -> Void)?
        
        var currentBoolValue: Bool {
            return (
                (leadingAccessory?.currentBoolValue ?? false) ||
                (trailingAccessory?.currentBoolValue ?? false)
            )
        }
        
        // MARK: - Initialization
        
        init(
            id: ID,
            position: Position = .individual,
            leadingAccessory: SessionCell.Accessory? = nil,
            title: SessionCell.TextInfo? = nil,
            subtitle: SessionCell.TextInfo? = nil,
            trailingAccessory: SessionCell.Accessory? = nil,
            styling: StyleInfo = StyleInfo(),
            isEnabled: Bool = true,
            accessibility: Accessibility? = nil,
            confirmationInfo: ConfirmationModal.Info? = nil,
            onTap: (() -> Void)? = nil,
            onTapView: ((UIView?) -> Void)? = nil
        ) {
            self.id = id
            self.position = position
            self.leadingAccessory = leadingAccessory
            self.title = title
            self.subtitle = subtitle
            self.trailingAccessory = trailingAccessory
            self.styling = styling
            self.isEnabled = isEnabled
            self.accessibility = accessibility
            self.confirmationInfo = confirmationInfo
            self.onTap = onTap
            self.onTapView = onTapView
        }
        
        // MARK: - Conformance
        
        public var differenceIdentifier: ID { id }
        
        public func hash(into hasher: inout Hasher) {
            id.hash(into: &hasher)
            position.hash(into: &hasher)
            leadingAccessory.hash(into: &hasher)
            title.hash(into: &hasher)
            subtitle.hash(into: &hasher)
            trailingAccessory.hash(into: &hasher)
            styling.hash(into: &hasher)
            isEnabled.hash(into: &hasher)
            accessibility.hash(into: &hasher)
            confirmationInfo.hash(into: &hasher)
        }
        
        public static func == (lhs: Info<ID>, rhs: Info<ID>) -> Bool {
            return (
                lhs.id == rhs.id &&
                lhs.position == rhs.position &&
                lhs.leadingAccessory == rhs.leadingAccessory &&
                lhs.title == rhs.title &&
                lhs.subtitle == rhs.subtitle &&
                lhs.trailingAccessory == rhs.trailingAccessory &&
                lhs.styling == rhs.styling &&
                lhs.isEnabled == rhs.isEnabled &&
                lhs.accessibility == rhs.accessibility
            )
        }
        
        // MARK: - Convenience
        
        public func updatedPosition(for index: Int, count: Int) -> Info {
            return Info(
                id: id,
                position: Position.with(index, count: count),
                leadingAccessory: leadingAccessory,
                title: title,
                subtitle: subtitle,
                trailingAccessory: trailingAccessory,
                styling: styling,
                isEnabled: isEnabled,
                accessibility: accessibility,
                confirmationInfo: confirmationInfo,
                onTap: onTap,
                onTapView: onTapView
            )
        }
    }
}

// MARK: - Convenience Initializers

public extension SessionCell.Info {
    // Accessory, () -> Void

    init(
        id: ID,
        position: Position = .individual,
        accessory: SessionCell.Accessory,
        styling: SessionCell.StyleInfo = SessionCell.StyleInfo(),
        isEnabled: Bool = true,
        accessibility: Accessibility? = nil,
        confirmationInfo: ConfirmationModal.Info? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.id = id
        self.position = position
        self.leadingAccessory = accessory
        self.title = nil
        self.subtitle = nil
        self.trailingAccessory = nil
        self.styling = styling
        self.isEnabled = isEnabled
        self.accessibility = accessibility
        self.confirmationInfo = confirmationInfo
        self.onTap = onTap
        self.onTapView = nil
    }

    // leadingAccessory, trailingAccessory

    init(
        id: ID,
        position: Position = .individual,
        leadingAccessory: SessionCell.Accessory,
        trailingAccessory: SessionCell.Accessory,
        styling: SessionCell.StyleInfo = SessionCell.StyleInfo(),
        isEnabled: Bool = true,
        accessibility: Accessibility? = nil,
        confirmationInfo: ConfirmationModal.Info? = nil
    ) {
        self.id = id
        self.position = position
        self.leadingAccessory = leadingAccessory
        self.title = nil
        self.subtitle = nil
        self.trailingAccessory = trailingAccessory
        self.styling = styling
        self.isEnabled = isEnabled
        self.accessibility = accessibility
        self.confirmationInfo = confirmationInfo
        self.onTap = nil
        self.onTapView = nil
    }

    // String, () -> Void

    init(
        id: ID,
        position: Position = .individual,
        leadingAccessory: SessionCell.Accessory? = nil,
        title: String,
        trailingAccessory: SessionCell.Accessory? = nil,
        styling: SessionCell.StyleInfo = SessionCell.StyleInfo(),
        isEnabled: Bool = true,
        accessibility: Accessibility? = nil,
        confirmationInfo: ConfirmationModal.Info? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.id = id
        self.position = position
        self.leadingAccessory = leadingAccessory
        self.title = SessionCell.TextInfo(title, font: .title)
        self.subtitle = nil
        self.trailingAccessory = trailingAccessory
        self.styling = styling
        self.isEnabled = isEnabled
        self.accessibility = accessibility
        self.confirmationInfo = confirmationInfo
        self.onTap = onTap
        self.onTapView = nil
    }

    // TextInfo, () -> Void

    init(
        id: ID,
        position: Position = .individual,
        leadingAccessory: SessionCell.Accessory? = nil,
        title: SessionCell.TextInfo,
        trailingAccessory: SessionCell.Accessory? = nil,
        styling: SessionCell.StyleInfo = SessionCell.StyleInfo(),
        isEnabled: Bool = true,
        accessibility: Accessibility? = nil,
        confirmationInfo: ConfirmationModal.Info? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.id = id
        self.position = position
        self.leadingAccessory = leadingAccessory
        self.title = title
        self.subtitle = nil
        self.trailingAccessory = trailingAccessory
        self.styling = styling
        self.isEnabled = isEnabled
        self.accessibility = accessibility
        self.confirmationInfo = confirmationInfo
        self.onTap = onTap
        self.onTapView = nil
    }

    // String, String?, () -> Void

    init(
        id: ID,
        position: Position = .individual,
        leadingAccessory: SessionCell.Accessory? = nil,
        title: String,
        subtitle: String?,
        trailingAccessory: SessionCell.Accessory? = nil,
        styling: SessionCell.StyleInfo = SessionCell.StyleInfo(),
        isEnabled: Bool = true,
        accessibility: Accessibility? = nil,
        confirmationInfo: ConfirmationModal.Info? = nil,
        onTap: (() -> Void)? = nil,
        onTapView: ((UIView?) -> Void)? = nil
    ) {
        self.id = id
        self.position = position
        self.leadingAccessory = leadingAccessory
        self.title = SessionCell.TextInfo(title, font: .title)
        self.subtitle = SessionCell.TextInfo(subtitle, font: .subtitle)
        self.trailingAccessory = trailingAccessory
        self.styling = styling
        self.isEnabled = isEnabled
        self.accessibility = accessibility
        self.confirmationInfo = confirmationInfo
        self.onTap = onTap
        self.onTapView = onTapView
    }
}
