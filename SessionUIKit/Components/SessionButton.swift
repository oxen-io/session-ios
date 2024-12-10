// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public final class SessionButton: UIButton {
    public enum Style {
        case bordered
        case borderless
        case destructive
        case destructiveBorderless
        case filled
    }
    
    public enum Size {
        case small
        case medium
        case large
    }
    
    public struct Info: Equatable {
        public let style: Style
        public let title: String
        public let isEnabled: Bool
        public let accessibility: Accessibility?
        public let minWidth: CGFloat
        public let onTap: () -> ()
        
        public init(
            style: Style,
            title: String,
            isEnabled: Bool,
            accessibility: Accessibility? = nil,
            minWidth: CGFloat = 0,
            onTap: @escaping () -> ()
        ) {
            self.style = style
            self.title = title
            self.isEnabled = isEnabled
            self.accessibility = accessibility
            self.onTap = onTap
            self.minWidth = minWidth
        }
        
        public static func == (lhs: SessionButton.Info, rhs: SessionButton.Info) -> Bool {
            return (
                lhs.style == rhs.style &&
                lhs.title == rhs.title &&
                lhs.isEnabled == rhs.isEnabled &&
                lhs.accessibility == rhs.accessibility &&
                lhs.minWidth == rhs.minWidth
            )
        }
    }
    
    public var style: Style {
        didSet {
            guard style != oldValue else { return }
            
            setup(style: style)
        }
    }
    
    public override var isEnabled: Bool {
        didSet {
            guard isEnabled else {
                setThemeTitleColor(
                    {
                        switch style {
                            case .bordered, .borderless, .destructive,
                                .destructiveBorderless:
                                return .disabled
                            
                            case .filled: return .white
                        }
                    }(),
                    for: .normal
                )
                setThemeBackgroundColor(
                    {
                        switch style {
                            case .bordered, .borderless, .destructive,
                                .destructiveBorderless:
                                return .clear
                            
                            case .filled: return .disabled
                        }
                    }(),
                    for: .normal
                )
                setThemeBackgroundColor(nil, for: .highlighted)
                
                themeBorderColor = {
                    switch style {
                        case .bordered, .destructive: return .disabled
                        case .filled, .borderless, .destructiveBorderless: return nil
                    }
                }()
                return
            }
            
            // If we enable the button they just re-apply the existing style
            setup(style: style)
        }
    }
    
    // MARK: - Initialization
    
    public init(style: Style, size: Size) {
        self.style = style
        
        super.init(frame: .zero)
        
        setup(size: size)
        setup(style: style)
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(style:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(style:) instead.")
    }
    
    private func setup(size: Size) {
        clipsToBounds = true
        let spacing: CGFloat = (size == .small ? Values.smallSpacing : Values.largeSpacing)
        contentEdgeInsets = UIEdgeInsets(
            top: 0,
            left: spacing,
            bottom: 0,
            right: spacing
        )
        titleLabel?.font = .boldSystemFont(ofSize: (size == .small ?
            Values.smallFontSize :
            Values.mediumFontSize
        ))
        
        let height: CGFloat = {
            switch size {
                case .small: return Values.smallButtonHeight
                case .medium: return Values.mediumButtonHeight
                case .large: return Values.largeButtonHeight
            }
        }()
        set(.height, to: height)
        layer.cornerRadius = {
            switch style {
                case .borderless, .destructiveBorderless: return 5
                default: return (height / 2)
            }
        }()
    }

    private func setup(style: Style) {
        setThemeTitleColor(
            {
                switch style {
                    case .bordered, .borderless: return .sessionButton_text
                    case .destructive, .destructiveBorderless: return .sessionButton_destructiveText
                    case .filled: return .sessionButton_filledText
                }
            }(),
            for: .normal
        )
        setThemeTitleColor(
            {
                switch style {
                    case .borderless: return .highlighted(.sessionButton_text)
                    case .destructiveBorderless: return .highlighted(.sessionButton_destructiveText)
                    case .bordered, .destructive, .filled: return nil
                }
            }(),
            for: .highlighted
        )
        
        setThemeBackgroundColor(
            {
                switch style {
                    case .bordered: return .sessionButton_background
                    case .destructive: return .sessionButton_destructiveBackground
                    case .borderless, .destructiveBorderless: return .clear
                    case .filled: return .sessionButton_filledBackground
                }
            }(),
            for: .normal
        )
        setThemeBackgroundColor(
            {
                switch style {
                    case .bordered: return .sessionButton_highlight
                    case .destructive: return .sessionButton_destructiveHighlight
                    case .borderless, .destructiveBorderless: return nil
                    case .filled: return .sessionButton_filledHighlight
                }
            }(),
            for: .highlighted
        )
        
        layer.borderWidth = {
            switch style {
                case .borderless, .destructiveBorderless: return 0
                default: return 1
            }
        }()
        themeBorderColor = {
            switch style {
                case .bordered: return .sessionButton_border
                case .destructive: return .sessionButton_destructiveBorder
                case .filled, .borderless, .destructiveBorderless: return nil
            }
        }()
    }
}
