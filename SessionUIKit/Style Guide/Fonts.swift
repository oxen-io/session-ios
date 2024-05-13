// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit
import SwiftUI

public enum Fonts {
    public static func spaceMono(ofSize size: CGFloat) -> UIFont {
        return UIFont(name: "SpaceMono-Regular", size: size)!
    }
    
    public static func boldSpaceMono(ofSize size: CGFloat) -> UIFont {
        return UIFont(name: "SpaceMono-Bold", size: size)!
    }
}

public extension Font {
    static func spaceMono(size: CGFloat) -> Font {
        return Font.custom("SpaceMono-Regular", size: size)
    }
    
    static func boldSpaceMono(size: CGFloat) -> Font {
        return Font.custom("SpaceMono-Bold", size: size)
    }
}
