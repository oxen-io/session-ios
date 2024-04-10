import UIKit
import SwiftUI

@objc(LKFonts)
public final class Fonts : NSObject {
    
    @objc public static func spaceMono(ofSize size: CGFloat) -> UIFont {
        return UIFont(name: "SpaceMono-Regular", size: size)!
    }
    
    @objc public static func boldSpaceMono(ofSize size: CGFloat) -> UIFont {
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
