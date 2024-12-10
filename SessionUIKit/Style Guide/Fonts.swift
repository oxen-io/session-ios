// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit
import SwiftUI

// MARK: - UIKit

public enum Fonts {
    public static func spaceMono(ofSize size: CGFloat) -> UIFont {
        return UIFont(name: "SpaceMono-Regular", size: size)!
    }
    
    public static func boldSpaceMono(ofSize size: CGFloat) -> UIFont {
        return UIFont(name: "SpaceMono-Bold", size: size)!
    }
}

public extension Fonts {
    enum Headings {
        public static let H1: UIFont = .boldSystemFont(ofSize: CGFloat(36))
        public static let H2: UIFont = .boldSystemFont(ofSize: CGFloat(32))
        public static let H3: UIFont = .boldSystemFont(ofSize: CGFloat(29))
        public static let H4: UIFont = .boldSystemFont(ofSize: CGFloat(26))
        public static let H5: UIFont = .boldSystemFont(ofSize: CGFloat(23))
        public static let H6: UIFont = .boldSystemFont(ofSize: CGFloat(20))
        public static let H7: UIFont = .boldSystemFont(ofSize: CGFloat(18))
        public static let H8: UIFont = .boldSystemFont(ofSize: CGFloat(16))
        public static let H9: UIFont = .boldSystemFont(ofSize: CGFloat(14))
        
        public static func custom(_ size: CGFloat) -> UIFont {
            return .boldSystemFont(ofSize: size)
        }
    }
    
    enum Body {
        public static let extraLargeRegular: UIFont = .systemFont(ofSize: CGFloat(18))
        public static let largeRegular: UIFont = .systemFont(ofSize: CGFloat(16))
        public static let baseRegular: UIFont = .systemFont(ofSize: CGFloat(14))
        public static let smallRegular: UIFont = .systemFont(ofSize: CGFloat(12))
        public static let extraSmallRegular: UIFont = .systemFont(ofSize: CGFloat(11))
        public static let finePrintRegular: UIFont = .systemFont(ofSize: CGFloat(9))
        public static let extraLargeBold: UIFont = .boldSystemFont(ofSize: CGFloat(18))
        public static let largeBold: UIFont = .boldSystemFont(ofSize: CGFloat(16))
        public static let baseBold: UIFont = .boldSystemFont(ofSize: CGFloat(14))
        public static let smallBold: UIFont = .boldSystemFont(ofSize: CGFloat(12))
        public static let extraSmallBold: UIFont = .boldSystemFont(ofSize: CGFloat(11))
        public static let finePrintBold: UIFont = .boldSystemFont(ofSize: CGFloat(9))
        
        public static func custom(_ size: CGFloat, bold: Bool = false) -> UIFont {
            switch bold {
                case true: return .boldSystemFont(ofSize: size)
                case false: return .systemFont(ofSize: size)
            }
        }
    }
    
    enum Display {
        public static let extraLarge: UIFont = Fonts.spaceMono(ofSize: CGFloat(18))
        public static let large: UIFont = Fonts.spaceMono(ofSize: CGFloat(16))
        public static let base: UIFont = Fonts.spaceMono(ofSize: CGFloat(14))
        public static let small: UIFont = Fonts.spaceMono(ofSize: CGFloat(12))
        public static let extraSmall: UIFont = Fonts.spaceMono(ofSize: CGFloat(11))
        public static let finePrint: UIFont = Fonts.spaceMono(ofSize: CGFloat(9))
        
        public static func custom(_ size: CGFloat) -> UIFont {
            return Fonts.spaceMono(ofSize: size)
        }
    }
}

// MARK: - SwiftUI

public extension Font {
    static func spaceMono(size: CGFloat) -> Font {
        return Font.custom("SpaceMono-Regular", size: size)
    }
    
    static func boldSpaceMono(size: CGFloat) -> Font {
        return Font.custom("SpaceMono-Bold", size: size)
    }
}

public extension Font {
    enum Headings {
        public static let H1: Font = .system(size: CGFloat(36)).bold()
        public static let H2: Font = .system(size: CGFloat(32)).bold()
        public static let H3: Font = .system(size: CGFloat(29)).bold()
        public static let H4: Font = .system(size: CGFloat(26)).bold()
        public static let H5: Font = .system(size: CGFloat(23)).bold()
        public static let H6: Font = .system(size: CGFloat(20)).bold()
        public static let H7: Font = .system(size: CGFloat(18)).bold()
        public static let H8: Font = .system(size: CGFloat(16)).bold()
        public static let H9: Font = .system(size: CGFloat(14)).bold()
        
        public static func custom(_ size: CGFloat) -> Font {
            return .system(size: size).bold()
        }
    }
    
    enum Body {
        public static let extraLargeRegular: Font = .system(size: CGFloat(18))
        public static let largeRegular: Font = .system(size: CGFloat(16))
        public static let baseRegular: Font = .system(size: CGFloat(14))
        public static let smallRegular: Font = .system(size: CGFloat(12))
        public static let extraSmallRegular: Font = .system(size: CGFloat(11))
        public static let finePrintRegular: Font = .system(size: CGFloat(9))
        public static let extraLargeBold: Font = .system(size: CGFloat(18)).bold()
        public static let largeBold: Font = .system(size: CGFloat(16)).bold()
        public static let baseBold: Font = .system(size: CGFloat(14)).bold()
        public static let smallBold: Font = .system(size: CGFloat(12)).bold()
        public static let extraSmallBold: Font = .system(size: CGFloat(11)).bold()
        public static let finePrintBold: Font = .system(size: CGFloat(9)).bold()
        
        public static func custom(_ size: CGFloat, bold: Bool = false) -> Font {
            return .system(size: size, weight: (bold ? .bold : .regular))
        }
    }
    
    enum Display {
        public static let extraLarge: Font = .spaceMono(size: CGFloat(18))
        public static let large: Font = .spaceMono(size: CGFloat(16))
        public static let base: Font = .spaceMono(size: CGFloat(14))
        public static let small: Font = .spaceMono(size: CGFloat(12))
        public static let extraSmall: Font = .spaceMono(size: CGFloat(11))
        public static let finePrint: Font = .spaceMono(size: CGFloat(9))
        
        public static func custom(_ size: CGFloat) -> Font {
            return .spaceMono(size: size)
        }
    }
}
