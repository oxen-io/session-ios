// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public extension View {
    func foregroundColor(themeColor: ThemeValue) -> some View {
        return self.foregroundColor(
            ThemeManager.currentTheme.colorSwiftUI(for: themeColor)
        )
    }
    
    func background(themeColor: ThemeValue) -> some View {
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
}

public extension Shape {
    func fill(themeColor: ThemeValue) -> some View {
        return self.fill(
            ThemeManager.currentTheme.colorSwiftUI(for: themeColor) ?? Color.primary
        )
    }
    
    func stroke(themeColor: ThemeValue, style: StrokeStyle) -> some View {
        return self.stroke(
            ThemeManager.currentTheme.colorSwiftUI(for: themeColor) ?? Color.primary,
            style: style
        )
    }
}
