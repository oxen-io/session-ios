// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

// MARK: - Main Types

public extension SessionCell {
    struct TextInfo: Hashable, Equatable {
        public enum Interaction: Hashable, Equatable {
            case none
            case editable
            case copy
            case alwaysEditing
        }
        
        let text: String?
        let textAlignment: NSTextAlignment
        let editingPlaceholder: String?
        let interaction: Interaction
        let accessibility: Accessibility?
        let extraViewGenerator: (() -> UIView)?
        
        private let fontStyle: FontStyle
        var font: UIFont { fontStyle.font }
        
        init(
            _ text: String?,
            font: FontStyle,
            alignment: NSTextAlignment = .left,
            editingPlaceholder: String? = nil,
            interaction: Interaction = .none,
            accessibility: Accessibility? = nil,
            extraViewGenerator: (() -> UIView)? = nil
        ) {
            self.text = text
            self.fontStyle = font
            self.textAlignment = alignment
            self.editingPlaceholder = editingPlaceholder
            self.interaction = interaction
            self.accessibility = accessibility
            self.extraViewGenerator = extraViewGenerator
        }
        
        // MARK: - Conformance
        
        public func hash(into hasher: inout Hasher) {
            text.hash(into: &hasher)
            fontStyle.hash(into: &hasher)
            textAlignment.hash(into: &hasher)
            interaction.hash(into: &hasher)
            editingPlaceholder.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        public static func == (lhs: TextInfo, rhs: TextInfo) -> Bool {
            return (
                lhs.text == rhs.text &&
                lhs.fontStyle == rhs.fontStyle &&
                lhs.textAlignment == rhs.textAlignment &&
                lhs.interaction == rhs.interaction &&
                lhs.editingPlaceholder == rhs.editingPlaceholder &&
                lhs.accessibility == rhs.accessibility
            )
        }
    }
    
    struct StyleInfo: Equatable, Hashable {
        let tintColor: ThemeValue
        let subtitleTintColor: ThemeValue
        let alignment: SessionCell.Alignment
        let allowedSeparators: Separators
        let customPadding: Padding?
        let backgroundStyle: SessionCell.BackgroundStyle
        
        public init(
            tintColor: ThemeValue = .textPrimary,
            subtitleTintColor: ThemeValue? = nil,
            alignment: SessionCell.Alignment = .leading,
            allowedSeparators: Separators = [.top, .bottom],
            customPadding: Padding? = nil,
            backgroundStyle: SessionCell.BackgroundStyle = .rounded
        ) {
            self.tintColor = tintColor
            self.subtitleTintColor = (subtitleTintColor ?? tintColor)
            self.alignment = alignment
            self.allowedSeparators = allowedSeparators
            self.customPadding = customPadding
            self.backgroundStyle = backgroundStyle
        }
    }
}

// MARK: - Child Types

public extension SessionCell {
    enum FontStyle: Hashable, Equatable {
        case title
        case titleLarge
        
        case subtitle
        case subtitleBold
        
        case monoSmall
        case monoLarge
        
        var font: UIFont {
            switch self {
                case .title: return .boldSystemFont(ofSize: 16)
                case .titleLarge: return .systemFont(ofSize: Values.veryLargeFontSize, weight: .medium)
                    
                case .subtitle: return .systemFont(ofSize: 14)
                case .subtitleBold: return .boldSystemFont(ofSize: 14)
                
                case .monoSmall: return Fonts.spaceMono(ofSize: Values.smallFontSize)
                case .monoLarge: return Fonts.spaceMono(
                    ofSize: (isIPhone5OrSmaller ? Values.mediumFontSize : Values.largeFontSize)
                )
            }
        }
    }
    
    enum Alignment: Equatable, Hashable {
        case leading
        case centerHugging
    }
    
    enum BackgroundStyle: Equatable, Hashable {
        case rounded
        case edgeToEdge
        case noBackground
        case noBackgroundEdgeToEdge
    }
    
    struct Separators: OptionSet, Equatable, Hashable {
        public let rawValue: Int8
        
        public init(rawValue: Int8) {
            self.rawValue = rawValue
        }
        
        public static let top: Separators = Separators(rawValue: 1 << 0)
        public static let bottom: Separators = Separators(rawValue: 1 << 1)
    }
    
    struct Padding: Equatable, Hashable {
        let top: CGFloat?
        let leading: CGFloat?
        let trailing: CGFloat?
        let bottom: CGFloat?
        let interItem: CGFloat?
        
        init(
            top: CGFloat? = nil,
            leading: CGFloat? = nil,
            trailing: CGFloat? = nil,
            bottom: CGFloat? = nil,
            interItem: CGFloat? = nil
        ) {
            self.top = top
            self.leading = leading
            self.trailing = trailing
            self.bottom = bottom
            self.interItem = interItem
        }
    }
}

// MARK: - ExpressibleByStringLiteral

extension SessionCell.TextInfo: ExpressibleByStringLiteral, ExpressibleByExtendedGraphemeClusterLiteral, ExpressibleByUnicodeScalarLiteral {
    public init(stringLiteral value: String) {
        self = SessionCell.TextInfo(value, font: .title)
    }
    
    public init(unicodeScalarLiteral value: Character) {
        self = SessionCell.TextInfo(String(value), font: .title)
    }
}
