// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public extension View {
    func foregroundColor(themeColor: ThemeValue) -> some View {
        return self.foregroundColor(
            ThemeManager.currentTheme.colorSwiftUI(for: themeColor)
        )
    }
    
    func backgroundColor(themeColor: ThemeValue) -> some View {
        if #available(iOSApplicationExtension 14.0, *) {
            return self.background(
                ThemeManager.currentTheme.colorSwiftUI(for: themeColor)?.ignoresSafeArea()
            )
        } else {
            return self.background(
                ThemeManager.currentTheme.colorSwiftUI(for: themeColor)
            )
        }
    }
    
    func shadow(themeColor: ThemeValue, opacity: CGFloat, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View {
        return self.shadow(
            color: ThemeManager.currentTheme.colorSwiftUI(for: themeColor)?.opacity(opacity) ?? Color(.sRGBLinear, white: 0, opacity: opacity),
            radius: radius,
            x: x,
            y: y
        )
    }
}

public extension Shape {
    func fill(themeColor: ThemeValue) -> some View {
        return self.fill(
            ThemeManager.currentTheme.colorSwiftUI(for: themeColor) ?? Color.primary
        )
    }
    
    func stroke(themeColor: ThemeValue, lineWidth: CGFloat = 1) -> some View {
        return self.stroke(
            ThemeManager.currentTheme.colorSwiftUI(for: themeColor) ?? Color.primary,
            lineWidth: lineWidth
        )
    }
    
    func stroke(themeColor: ThemeValue, style: StrokeStyle) -> some View {
        return self.stroke(
            ThemeManager.currentTheme.colorSwiftUI(for: themeColor) ?? Color.primary,
            style: style
        )
    }
}
