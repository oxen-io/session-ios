// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public extension Setting.EnumKey {
    /// Controls what theme should be used
    static let theme: Setting.EnumKey = "selectedTheme"
    
    /// Controls what primary color should be used for the theme
    static let themePrimaryColor: Setting.EnumKey = "selectedThemePrimaryColor"
}

public extension Setting.BoolKey {
    /// A flag indicating whether the app should match system day/night settings
    static let themeMatchSystemDayNightCycle: Setting.BoolKey = "themeMatchSystemDayNightCycle"
}
