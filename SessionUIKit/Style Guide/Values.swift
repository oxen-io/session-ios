import UIKit

public enum Values {
    
    // MARK: - Alpha Values
    public static let veryLowOpacity = CGFloat(0.12)
    public static let lowOpacity = CGFloat(0.4)
    public static let mediumOpacity = CGFloat(0.6)
    public static let highOpacity = CGFloat(0.75)
    
    // MARK: - Font Sizes
    public static let miniFontSize = isIPhone5OrSmaller ? CGFloat(8) : CGFloat(10)
    public static let verySmallFontSize = isIPhone5OrSmaller ? CGFloat(10) : CGFloat(12)
    public static let smallFontSize = isIPhone5OrSmaller ? CGFloat(13) : CGFloat(15)
    public static let mediumFontSize = isIPhone5OrSmaller ? CGFloat(15) : CGFloat(17)
    public static let largeFontSize = isIPhone5OrSmaller ? CGFloat(17) : CGFloat(19)
    public static let veryLargeFontSize = isIPhone5OrSmaller ? CGFloat(22) : CGFloat(24)
    public static let massiveFontSize = CGFloat(50)
    
    // MARK: - Element Sizes
    public static let smallButtonHeight = isIPhone5OrSmaller ? CGFloat(24) : CGFloat(28)
    public static let mediumButtonHeight = isIPhone5OrSmaller ? CGFloat(30) : CGFloat(34)
    public static let largeButtonHeight = isIPhone5OrSmaller ? CGFloat(40) : CGFloat(45)
    public static let alertButtonHeight: CGFloat = 51 // 19px tall font with 16px margins
    
    public static let accentLineThickness = CGFloat(4)
    
    public static let searchBarHeight = CGFloat(36)

    public static var separatorThickness: CGFloat { return 1 / UIScreen.main.scale }
    
    public static func footerGradientHeight(window: UIWindow?) -> CGFloat {
        return (
            Values.veryLargeSpacing +
            Values.largeButtonHeight +
            Values.smallSpacing +
            (window?.safeAreaInsets.bottom ?? 0)
        )
    }
    
    // MARK: - Distances
    public static let verySmallSpacing = CGFloat(4)
    public static let smallSpacing = CGFloat(8)
    public static let mediumSpacing = CGFloat(16)
    public static let largeSpacing = CGFloat(24)
    public static let veryLargeSpacing = CGFloat(35)
    public static let massiveSpacing = CGFloat(64)
    public static let onboardingButtonBottomOffset = isIPhone5OrSmaller ? CGFloat(52) : CGFloat(72)
    
    // MARK: - iPad Sizes
    public static let iPadModalWidth = UIScreen.main.bounds.width / 2
    public static let iPadButtonWidth = CGFloat(240)
    public static let iPadButtonSpacing = CGFloat(32)
    public static let iPadUserSessionIdContainerWidth = iPadButtonWidth * 2 + iPadButtonSpacing
    
    // MARK: - Auto Scaling
    
    static let iPhone5ScreenWidth: CGFloat = 320
    static let iPhone7PlusScreenWidth: CGFloat = 414
    
    static var screenShortDimension: CGFloat {
        return min(UIScreen.main.bounds.size.width, UIScreen.main.bounds.size.height)
    }
    
    public static func scaleFromIPhone5To7Plus(_ iPhone5Value: CGFloat, _ iPhone7PlusValue: CGFloat) -> CGFloat {
        return screenShortDimension
            .inverseLerp(iPhone5ScreenWidth, iPhone7PlusScreenWidth)
            .clamp01()
            .lerp(iPhone5Value, iPhone7PlusValue)
            .rounded()
    }
    
    public static func scaleFromIPhone5(_ iPhone5Value: CGFloat) -> CGFloat {
        round(iPhone5Value * screenShortDimension / iPhone5ScreenWidth)
    }
}

/// These extensions are duplicate here from `SessionUtilitiesKit.CGFloat+Utilities` to avoid creating a
/// dependency on `SessionUtilitiesKit`
private extension CGFloat {
    func clamp(_ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
        return Swift.max(minValue, Swift.min(maxValue, self))
    }
    
    func clamp01() -> CGFloat {
        return clamp(0, 1)
    }
    
    func lerp(_ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
        return (minValue * (1 - self)) + (maxValue * self)
    }
    
    func inverseLerp(_ minValue: CGFloat, _ maxValue: CGFloat, shouldClamp: Bool = false) -> CGFloat {
        let result: CGFloat = ((self - minValue) / (maxValue - minValue))
        
        return (shouldClamp ? result.clamp01() : result)
    }
}
