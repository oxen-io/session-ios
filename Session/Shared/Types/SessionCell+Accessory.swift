// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

public extension SessionCell {
    enum AccessoryConfig {}
    
    class Accessory: Hashable, Equatable {
        public let accessibility: Accessibility?
        public var shouldFitToEdge: Bool { false }
        public var currentBoolValue: Bool { false }
        
        fileprivate init(accessibility: Accessibility?) {
            self.accessibility = accessibility
        }
        
        public func hash(into hasher: inout Hasher) {}
        fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool { return false }
        
        public static func == (lhs: SessionCell.Accessory, rhs: SessionCell.Accessory) -> Bool {
            return lhs.isEqual(to: rhs)
        }
    }
}

// MARK: - DSL

public extension SessionCell.Accessory {
    static func icon(
        _ image: UIImage?,
        size: IconSize = .medium,
        customTint: ThemeValue? = nil,
        shouldFill: Bool = false,
        accessibility: Accessibility? = nil
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.Icon(
            image: image,
            iconSize: size,
            customTint: customTint,
            shouldFill: shouldFill,
            accessibility: accessibility
        )
    }
    
    static func iconAsync(
        size: IconSize = .medium,
        customTint: ThemeValue? = nil,
        shouldFill: Bool = false,
        accessibility: Accessibility? = nil,
        setter: @escaping (UIImageView) -> Void
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.IconAsync(
            iconSize: size,
            customTint: customTint,
            shouldFill: shouldFill,
            setter: setter,
            accessibility: accessibility
        )
    }
        
    static func toggle(
        _ value: Bool,
        oldValue: Bool?,
        accessibility: Accessibility? = nil
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.Toggle(
            value: value,
            oldValue: (oldValue ?? value),
            accessibility: accessibility
        )
    }
    
    static func dropDown(
        _ dynamicString: @escaping () -> String?,
        accessibility: Accessibility? = nil
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.DropDown(
            dynamicString: dynamicString,
            accessibility: accessibility
        )
    }
    
    static func radio(
        _ size: SessionCell.AccessoryConfig.Radio.Size = .medium,
        isSelected: Bool? = nil,
        liveIsSelected: (() -> Bool)? = nil,
        wasSavedSelection: Bool = false,
        accessibility: Accessibility? = nil
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.Radio(
            size: size,
            initialIsSelected: ((isSelected ?? liveIsSelected?()) ?? false),
            liveIsSelected: (liveIsSelected ?? { (isSelected ?? false) }),
            wasSavedSelection: wasSavedSelection,
            accessibility: accessibility
        )
    }
    
    static func highlightingBackgroundLabel(
        title: String,
        accessibility: Accessibility? = nil
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.HighlightingBackgroundLabel(
            title: title,
            accessibility: accessibility
        )
    }
    
    static func profile(
        id: String,
        size: ProfilePictureView.Size = .list,
        threadVariant: SessionThread.Variant = .contact,
        displayPictureFilename: String? = nil,
        profile: Profile? = nil,
        profileIcon: ProfilePictureView.ProfileIcon = .none,
        additionalProfile: Profile? = nil,
        additionalProfileIcon: ProfilePictureView.ProfileIcon = .none,
        accessibility: Accessibility? = nil
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.DisplayPicture(
            id: id,
            size: size,
            threadVariant: threadVariant,
            displayPictureFilename: displayPictureFilename,
            profile: profile,
            profileIcon: profileIcon,
            additionalProfile: additionalProfile,
            additionalProfileIcon: additionalProfileIcon,
            accessibility: accessibility
        )
    }
    
    static func search(
        placeholder: String,
        accessibility: Accessibility? = nil,
        searchTermChanged: @escaping (String?) -> Void
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.Search(
            placeholder: placeholder,
            searchTermChanged: searchTermChanged,
            accessibility: accessibility
        )
    }
    
    static func button(
        style: SessionButton.Style,
        title: String,
        accessibility: Accessibility? = nil,
        run: @escaping (SessionButton?) -> Void
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.Button(
            style: style,
            title: title,
            run: run,
            accessibility: accessibility
        )
    }
    
    static func customView(
        uniqueId: AnyHashable,
        accessibility: Accessibility? = nil,
        viewGenerator: @escaping () -> UIView
    ) -> SessionCell.Accessory {
        return SessionCell.AccessoryConfig.CustomView(
            uniqueId: uniqueId,
            viewGenerator: viewGenerator,
            accessibility: accessibility
        )
    }
}

// MARK: Structs

public extension SessionCell.AccessoryConfig {
    // MARK: - Icon
    
    class Icon: SessionCell.Accessory {
        public let image: UIImage?
        public let iconSize: IconSize
        public let customTint: ThemeValue?
        public let shouldFill: Bool
        
        override public var shouldFitToEdge: Bool { shouldFill }
        
        fileprivate init(
            image: UIImage?,
            iconSize: IconSize,
            customTint: ThemeValue?,
            shouldFill: Bool,
            accessibility: Accessibility?
        ) {
            self.image = image
            self.iconSize = iconSize
            self.customTint = customTint
            self.shouldFill = shouldFill
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            image.hash(into: &hasher)
            iconSize.hash(into: &hasher)
            customTint.hash(into: &hasher)
            shouldFill.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            guard let rhs: Icon = other as? Icon else { return false }
            
            return (
                image == rhs.image &&
                iconSize == rhs.iconSize &&
                customTint == rhs.customTint &&
                shouldFill == rhs.shouldFill &&
                accessibility == rhs.accessibility
            )
        }
    }
    
    // MARK: - IconAsync
    
    class IconAsync: SessionCell.Accessory {
        public let iconSize: IconSize
        public let customTint: ThemeValue?
        public let shouldFill: Bool
        public let setter: (UIImageView) -> Void
        
        override public var shouldFitToEdge: Bool { shouldFill }
        
        fileprivate init(
            iconSize: IconSize,
            customTint: ThemeValue?,
            shouldFill: Bool,
            setter: @escaping (UIImageView) -> Void,
            accessibility: Accessibility?
        ) {
            self.iconSize = iconSize
            self.customTint = customTint
            self.shouldFill = shouldFill
            self.setter = setter
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            iconSize.hash(into: &hasher)
            customTint.hash(into: &hasher)
            shouldFill.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            guard let rhs: IconAsync = other as? IconAsync else { return false }
            
            return (
                iconSize == rhs.iconSize &&
                customTint == rhs.customTint &&
                shouldFill == rhs.shouldFill &&
                accessibility == rhs.accessibility
            )
        }
    }
    
    // MARK: - Toggle
    
    class Toggle: SessionCell.Accessory {
        public let value: Bool
        public let oldValue: Bool
        
        override public var currentBoolValue: Bool { value }
        
        fileprivate init(
            value: Bool,
            oldValue: Bool,
            accessibility: Accessibility?
        ) {
            self.value = value
            self.oldValue = oldValue
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            value.hash(into: &hasher)
            oldValue.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            guard let rhs: Toggle = other as? Toggle else { return false }
            
            return (
                value == rhs.value &&
                oldValue == rhs.oldValue &&
                accessibility == rhs.accessibility
            )
        }
    }
    
    // MARK: - DropDown
    
    class DropDown: SessionCell.Accessory {
        public let dynamicString: () -> String?
        
        fileprivate init(
            dynamicString: @escaping () -> String?,
            accessibility: Accessibility?
        ) {
            self.dynamicString = dynamicString
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            dynamicString().hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            guard let rhs: DropDown = other as? DropDown else { return false }
            
            return (
                dynamicString() == rhs.dynamicString() &&
                accessibility == rhs.accessibility
            )
        }
    }
    
    // MARK: - Radio
    
    class Radio: SessionCell.Accessory {
        public enum Size: Hashable, Equatable {
            case small
            case medium
            
            var borderSize: CGFloat {
                switch self {
                    case .small: return 20
                    case .medium: return 26
                }
            }
            
            var selectionSize: CGFloat {
                switch self {
                    case .small: return 15
                    case .medium: return 20
                }
            }
        }
        
        public let size: Size
        public let initialIsSelected: Bool
        public let liveIsSelected: () -> Bool
        public let wasSavedSelection: Bool
        
        override public var currentBoolValue: Bool { liveIsSelected() }
        
        fileprivate init(
            size: Size,
            initialIsSelected: Bool,
            liveIsSelected: @escaping () -> Bool,
            wasSavedSelection: Bool,
            accessibility: Accessibility?
        ) {
            self.size = size
            self.initialIsSelected = initialIsSelected
            self.liveIsSelected = liveIsSelected
            self.wasSavedSelection = wasSavedSelection
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            size.hash(into: &hasher)
            initialIsSelected.hash(into: &hasher)
            wasSavedSelection.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            guard let rhs: Radio = other as? Radio else { return false }
            
            return (
                size == rhs.size &&
                initialIsSelected == rhs.initialIsSelected &&
                wasSavedSelection == rhs.wasSavedSelection &&
                accessibility == rhs.accessibility
            )
        }
    }
    
    // MARK: - HighlightingBackgroundLabel
    
    class HighlightingBackgroundLabel: SessionCell.Accessory {
        public let title: String
        
        init(
            title: String,
            accessibility: Accessibility?
        ) {
            self.title = title
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            title.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            guard let rhs: HighlightingBackgroundLabel = other as? HighlightingBackgroundLabel else {
                return false
            }
            
            return (
                title == rhs.title &&
                accessibility == rhs.accessibility
            )
        }
    }
    
    // MARK: - DisplayPicture
    
    class DisplayPicture: SessionCell.Accessory {
        public let id: String
        public let size: ProfilePictureView.Size
        public let threadVariant: SessionThread.Variant
        public let displayPictureFilename: String?
        public let profile: Profile?
        public let profileIcon: ProfilePictureView.ProfileIcon
        public let additionalProfile: Profile?
        public let additionalProfileIcon: ProfilePictureView.ProfileIcon
        
        fileprivate init(
            id: String,
            size: ProfilePictureView.Size,
            threadVariant: SessionThread.Variant,
            displayPictureFilename: String?,
            profile: Profile?,
            profileIcon: ProfilePictureView.ProfileIcon,
            additionalProfile: Profile?,
            additionalProfileIcon: ProfilePictureView.ProfileIcon,
            accessibility: Accessibility?
        ) {
            self.id = id
            self.size = size
            self.threadVariant = threadVariant
            self.displayPictureFilename = displayPictureFilename
            self.profile = profile
            self.profileIcon = profileIcon
            self.additionalProfile = additionalProfile
            self.additionalProfileIcon = additionalProfileIcon
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            id.hash(into: &hasher)
            size.hash(into: &hasher)
            threadVariant.hash(into: &hasher)
            displayPictureFilename.hash(into: &hasher)
            profile.hash(into: &hasher)
            profileIcon.hash(into: &hasher)
            additionalProfile.hash(into: &hasher)
            additionalProfileIcon.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            guard let rhs: DisplayPicture = other as? DisplayPicture else { return false }
            
            return (
                id == rhs.id &&
                size == rhs.size &&
                threadVariant == rhs.threadVariant &&
                displayPictureFilename == rhs.displayPictureFilename &&
                profile == rhs.profile &&
                profileIcon == rhs.profileIcon &&
                additionalProfile == rhs.additionalProfile &&
                additionalProfileIcon == rhs.additionalProfileIcon &&
                accessibility == rhs.accessibility
            )
        }
    }
    
    class Search: SessionCell.Accessory {
        public let placeholder: String
        public let searchTermChanged: (String?) -> Void
        
        fileprivate init(
            placeholder: String,
            searchTermChanged: @escaping (String?) -> Void,
            accessibility: Accessibility?
        ) {
            self.placeholder = placeholder
            self.searchTermChanged = searchTermChanged
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            placeholder.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            return (
                other is Search &&
                placeholder == (other as? Search)?.placeholder &&
                accessibility == (other as? Search)?.accessibility
            )
        }
    }
    
    class Button: SessionCell.Accessory {
        public let style: SessionButton.Style
        public let title: String
        public let run: (SessionButton?) -> Void
        
        fileprivate init(
            style: SessionButton.Style,
            title: String,
            run: @escaping (SessionButton?) -> Void,
            accessibility: Accessibility?
        ) {
            self.style = style
            self.title = title
            self.run = run
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            style.hash(into: &hasher)
            title.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            return (
                other is Button &&
                style == (other as? Button)?.style &&
                title == (other as? Button)?.title &&
                accessibility == (other as? Button)?.accessibility
            )
        }
    }
    
    class CustomView: SessionCell.Accessory {
        public let uniqueId: AnyHashable
        public let viewGenerator: () -> UIView
        
        fileprivate init(
            uniqueId: AnyHashable,
            viewGenerator: @escaping () -> UIView,
            accessibility: Accessibility?
        ) {
            self.uniqueId = uniqueId
            self.viewGenerator = viewGenerator
            
            super.init(accessibility: accessibility)
        }
        
        // MARK: - Conformance
        
        override public func hash(into hasher: inout Hasher) {
            uniqueId.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        override fileprivate func isEqual(to other: SessionCell.Accessory) -> Bool {
            return (
                other is CustomView &&
                uniqueId == (other as? CustomView)?.uniqueId &&
                accessibility == (other as? CustomView)?.accessibility
            )
        }
    }
}
