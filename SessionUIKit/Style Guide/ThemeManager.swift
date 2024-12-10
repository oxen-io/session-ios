// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit

// MARK: - ThemeManager

public enum ThemeManager {
    private static var hasSetInitialSystemTrait: Bool = false
    
    /// **Note:** Using `weakToStrongObjects` means that the value types will continue to be maintained until the map table resizes
    /// itself (ie. until a new UI element is registered to the table)
    ///
    /// Unfortunately if we don't do this the `ThemeApplier` is immediately deallocated and we can't use it to update the theme
    private static var uiRegistry: NSMapTable<AnyObject, ThemeApplier> = NSMapTable.weakToStrongObjects()
    
    private static var _theme: Theme = .classicDark                 // Default to `classicDark`
    private static var _primaryColor: Theme.PrimaryColor = .green   // Default to `green`
    private static var _matchSystemNightModeSetting: Bool = false   // Default to `false`
    
    public static var currentTheme: Theme { _theme }
    public static var primaryColor: Theme.PrimaryColor { _primaryColor }
    public static var matchSystemNightModeSetting: Bool { _matchSystemNightModeSetting }
    
    // MARK: - Functions
    
    public static func updateThemeState(
        theme: Theme? = nil,
        primaryColor: Theme.PrimaryColor? = nil,
        matchSystemNightModeSetting: Bool? = nil
    ) {
        let targetTheme: Theme = (theme ?? _theme)
        let targetPrimaryColor: Theme.PrimaryColor = {
            switch (primaryColor, Theme.PrimaryColor(color: targetTheme.color(for: .defaultPrimary))) {
                case (.some(let primaryColor), _): return primaryColor
                case (.none, .some(let defaultPrimaryColor)): return defaultPrimaryColor
                default: return _primaryColor
            }
        }()
        let targetMatchSystemNightModeSetting: Bool = (matchSystemNightModeSetting ?? _matchSystemNightModeSetting)
        let themeChanged: Bool = (_theme != targetTheme || _primaryColor != targetPrimaryColor)
        _theme = targetTheme
        _primaryColor = targetPrimaryColor
        
        if !hasSetInitialSystemTrait || themeChanged {
            updateAllUI()
        }
        
        if _matchSystemNightModeSetting != targetMatchSystemNightModeSetting {
            _matchSystemNightModeSetting = targetMatchSystemNightModeSetting
            
            // Note: We need to set this to 'unspecified' to force the UI to properly update as the
            // 'TraitObservingWindow' won't actually trigger the trait change otherwise
            DispatchQueue.main.async {
                SNUIKit.mainWindow?.overrideUserInterfaceStyle = .unspecified
            }
        }
        
        // If the theme was changed then trigger the callback for the theme settings change (so it gets persisted)
        guard themeChanged || _matchSystemNightModeSetting != targetMatchSystemNightModeSetting else { return }
        
        SNUIKit.themeSettingsChanged(targetTheme, targetPrimaryColor, targetMatchSystemNightModeSetting)
    }
    
    public static func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        let currentUserInterfaceStyle: UIUserInterfaceStyle = UITraitCollection.current.userInterfaceStyle
        
        // Only trigger updates if the style changed and the device is set to match the system style
        guard
            currentUserInterfaceStyle != ThemeManager.currentTheme.interfaceStyle,
            _matchSystemNightModeSetting
        else { return }
        
        // Swap to the appropriate light/dark mode
        switch (currentUserInterfaceStyle, ThemeManager.currentTheme) {
            case (.light, .classicDark): updateThemeState(theme: .classicLight)
            case (.light, .oceanDark): updateThemeState(theme: .oceanLight)
            case (.dark, .classicLight): updateThemeState(theme: .classicDark)
            case (.dark, .oceanLight): updateThemeState(theme: .oceanDark)
            default: break
        }
    }
    
    public static func applyNavigationStyling() {
        guard Thread.isMainThread else {
            return DispatchQueue.main.async { applyNavigationStyling() }
        }
        
        let textPrimary: UIColor = (ThemeManager.currentTheme.color(for: .textPrimary) ?? .white)
        
        // Set the `mainWindow.tintColor` for system screens to use the right color for text
        SNUIKit.mainWindow?.tintColor = textPrimary
        SNUIKit.mainWindow?.rootViewController?.setNeedsStatusBarAppearanceUpdate()
        
        // Update toolbars to use the right colours
        UIToolbar.appearance().barTintColor = ThemeManager.currentTheme.color(for: .backgroundPrimary)
        UIToolbar.appearance().isTranslucent = false
        UIToolbar.appearance().tintColor = textPrimary
        
        // Update the nav bars to use the right colours
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = ThemeManager.currentTheme.color(for: .backgroundPrimary)
        appearance.shadowImage = ThemeManager.currentTheme.color(for: .backgroundPrimary)?.toImage()
        appearance.titleTextAttributes = [
            NSAttributedString.Key.foregroundColor: textPrimary
        ]
        appearance.largeTitleTextAttributes = [
            NSAttributedString.Key.foregroundColor: textPrimary
        ]
        
        // Apply the button item appearance as well
        let barButtonItemAppearance = UIBarButtonItemAppearance(style: .plain)
        barButtonItemAppearance.normal.titleTextAttributes = [ .foregroundColor: textPrimary ]
        barButtonItemAppearance.disabled.titleTextAttributes = [ .foregroundColor: textPrimary ]
        barButtonItemAppearance.highlighted.titleTextAttributes = [ .foregroundColor: textPrimary ]
        barButtonItemAppearance.focused.titleTextAttributes = [ .foregroundColor: textPrimary ]
        appearance.buttonAppearance = barButtonItemAppearance
        appearance.backButtonAppearance = barButtonItemAppearance
        appearance.doneButtonAppearance = barButtonItemAppearance
        
        UINavigationBar.appearance().isTranslucent = false
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        
        // Note: 'UINavigationBar.appearance' only affects newly created nav bars so we need
        // to force-update any current navigation bar (unfortunately the only way to do this
        // is to remove the nav controller from the view hierarchy and then re-add it)
        func updateIfNeeded(viewController: UIViewController?) {
            guard let viewController: UIViewController = viewController else { return }
            guard
                let navController: UINavigationController = retrieveNavigationController(from: viewController),
                let superview: UIView = navController.view.superview,
                !navController.isNavigationBarHidden
            else {
                updateIfNeeded(viewController:
                    viewController.presentedViewController ??
                    viewController.navigationController?.presentedViewController
                )
                return
            }
            
            // Apply non-primary styling if needed
            applyNavigationStylingIfNeeded(to: viewController)
            
            // Re-attach to the UI
            let wasFirstResponder: Bool = (navController.topViewController?.isFirstResponder == true)
            
            switch navController.parent {
                case let topBannerController as TopBannerController:
                    navController.view.removeFromSuperview()
                    topBannerController.attachChild()
                    
                default:
                    navController.view.removeFromSuperview()
                    superview.addSubview(navController.view)
            }
            navController.topViewController?.setNeedsStatusBarAppearanceUpdate()
            if wasFirstResponder { navController.topViewController?.becomeFirstResponder() }
            
            // Recurse through the rest of the UI
            updateIfNeeded(viewController:
                viewController.presentedViewController ??
                viewController.navigationController?.presentedViewController
            )
        }
        
        updateIfNeeded(viewController: SNUIKit.mainWindow?.rootViewController)
    }
    
    public static func applyNavigationStylingIfNeeded(to viewController: UIViewController) {
        // Will use the 'primary' style for all other cases
        guard
            let navController: UINavigationController = ((viewController as? UINavigationController) ?? viewController.navigationController),
            let navigationBackground: ThemeValue = (navController.viewControllers.first as? ThemedNavigation)?.navigationBackground
        else { return }
        
        navController.navigationBar.barTintColor = ThemeManager.currentTheme.color(for: navigationBackground)
        navController.navigationBar.shadowImage = ThemeManager.currentTheme.color(for: navigationBackground)?.toImage()
        
        let textPrimary: UIColor = (ThemeManager.currentTheme.color(for: .textPrimary) ?? .white)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = ThemeManager.currentTheme.color(for: navigationBackground)
        appearance.shadowImage = ThemeManager.currentTheme.color(for: navigationBackground)?.toImage()
        appearance.titleTextAttributes = [
            NSAttributedString.Key.foregroundColor: textPrimary
        ]
        appearance.largeTitleTextAttributes = [
            NSAttributedString.Key.foregroundColor: textPrimary
        ]
        
        navController.navigationBar.standardAppearance = appearance
        navController.navigationBar.scrollEdgeAppearance = appearance
    }
    
    private static func retrieveNavigationController(from viewController: UIViewController) -> UINavigationController? {
        switch viewController {
            case let navController as UINavigationController: return navController
            case let topBannerController as TopBannerController:
                return (topBannerController.children.first as? UINavigationController)
                
            default: return viewController.navigationController
        }
    }
    
    public static func applyWindowStyling() {
        guard Thread.isMainThread else {
            return DispatchQueue.main.async { applyWindowStyling() }
        }
        
        SNUIKit.mainWindow?.overrideUserInterfaceStyle = {
            guard !ThemeManager.matchSystemNightModeSetting else { return .unspecified }
            
            switch ThemeManager.currentTheme.interfaceStyle {
                case .light: return .light
                case .dark, .unspecified: return .dark
                @unknown default: return .dark
            }
        }()
        SNUIKit.mainWindow?.backgroundColor = ThemeManager.currentTheme.color(for: .backgroundPrimary)
    }
    
    public static func onThemeChange(observer: AnyObject, callback: @escaping (Theme, Theme.PrimaryColor) -> ()) {
        ThemeManager.uiRegistry.setObject(
            ThemeApplier(
                existingApplier: ThemeManager.get(for: observer),
                info: []
            ) { theme in callback(theme, ThemeManager.primaryColor) },
            forKey: observer
        )
    }
    
    private static func updateAllUI() {
        guard Thread.isMainThread else {
            return DispatchQueue.main.async { updateAllUI() }
        }
        
        ThemeManager.uiRegistry.objectEnumerator()?.forEach { applier in
            (applier as? ThemeApplier)?.apply(theme: currentTheme)
        }
        
        applyNavigationStyling()
        applyWindowStyling()
        
        if !hasSetInitialSystemTrait {
            traitCollectionDidChange(nil)
            hasSetInitialSystemTrait = true
        }
    }
    
    internal static func set<T: AnyObject>(
        _ view: T,
        keyPath: ReferenceWritableKeyPath<T, UIColor?>,
        to value: ThemeValue?
    ) {
        ThemeManager.uiRegistry.setObject(
            ThemeApplier(
                existingApplier: ThemeManager.get(for: view),
                info: [ keyPath ]
            ) { [weak view] theme in
                guard let value: ThemeValue = value else {
                    view?[keyPath: keyPath] = nil
                    return
                }

                view?[keyPath: keyPath] = ThemeManager.resolvedColor(theme.color(for: value))
            },
            forKey: view
        )
    }
    
    internal static func remove<T: AnyObject>(
        _ view: T,
        keyPath: ReferenceWritableKeyPath<T, UIColor?>
    ) {
        // Note: Need to explicitly remove (setting to 'nil' won't actually remove it)
        guard let updatedApplier: ThemeApplier = ThemeManager.get(for: view)?.removing(allWith: keyPath) else {
            ThemeManager.uiRegistry.removeObject(forKey: view)
            return
        }
        
        ThemeManager.uiRegistry.setObject(updatedApplier, forKey: view)
    }
    
    internal static func set<T: AnyObject>(
        _ view: T,
        keyPath: ReferenceWritableKeyPath<T, CGColor?>,
        to value: ThemeValue?
    ) {
        ThemeManager.uiRegistry.setObject(
            ThemeApplier(
                existingApplier: ThemeManager.get(for: view),
                info: [ keyPath ]
            ) { [weak view] theme in
                guard let value: ThemeValue = value else {
                    view?[keyPath: keyPath] = nil
                    return
                }
                
                view?[keyPath: keyPath] = ThemeManager.resolvedColor(theme.color(for: value))?.cgColor
            },
            forKey: view
        )
    }
    
    internal static func remove<T: AnyObject>(
        _ view: T,
        keyPath: ReferenceWritableKeyPath<T, CGColor?>
    ) {
        ThemeManager.uiRegistry.setObject(
            ThemeManager.get(for: view)?
                .removing(allWith: keyPath),
            forKey: view
        )
    }
    
    internal static func set<T: AnyObject>(
        _ view: T,
        to applier: ThemeApplier?
    ) {
        ThemeManager.uiRegistry.setObject(applier, forKey: view)
    }
    
    /// Using a `UIColor(dynamicProvider:)` unfortunately doesn't seem to work properly for some controls (eg. UISwitch) so
    /// since we are already explicitly updating all UI when changing colors & states we just force-resolve the primary color to avoid
    /// running into these glitches
    internal static func resolvedColor(_ color: UIColor?) -> UIColor? {
        return color?.resolvedColor(with: UITraitCollection())
    }
    
    internal static func get(for view: AnyObject) -> ThemeApplier? {
        return ThemeManager.uiRegistry.object(forKey: view)
    }
}

// MARK: - ThemeApplier

internal class ThemeApplier {
    enum InfoKey: String {
        case keyPath
        case controlState
    }
    
    private let applyTheme: (Theme) -> ()
    private let info: [AnyHashable]
    private var otherAppliers: [ThemeApplier]?
    
    init(
        existingApplier: ThemeApplier?,
        info: [AnyHashable],
        applyTheme: @escaping (Theme) -> ()
    ) {
        self.applyTheme = applyTheme
        self.info = info
        
        // Store any existing "appliers" (removing their 'otherApplier' references to prevent
        // loops and excluding any which match the current "info" as they should be replaced
        // by this applier)
        self.otherAppliers = [existingApplier]
            .appending(contentsOf: existingApplier?.otherAppliers)
            .compactMap { $0?.clearingOtherAppliers() }
            .filter { $0.info != info }
        
        // Automatically apply the theme immediately (if the database has been setup)
        if SNUIKit.config?.isStorageValid == true {
            self.apply(theme: ThemeManager.currentTheme, isInitialApplication: true)
        }
    }
    
    // MARK: - Functions
    
    public func removing(allWith info: AnyHashable) -> ThemeApplier? {
        let remainingAppliers: [ThemeApplier] = [self]
            .appending(contentsOf: self.otherAppliers)
            .filter { applier in !applier.info.contains(info) }
        
        guard !remainingAppliers.isEmpty else { return nil }
        guard remainingAppliers.count != ((self.otherAppliers ?? []).count + 1) else { return self }
        
        // Remove the 'otherAppliers' references on self
        self.otherAppliers = nil
        
        // Attach the 'otherAppliers' to the new first remaining applier (just in case self
        // was removed)
        let firstApplier: ThemeApplier? = remainingAppliers.first
        firstApplier?.otherAppliers = Array(remainingAppliers.suffix(from: 1))
        
        return firstApplier
    }
    
    private func clearingOtherAppliers() -> ThemeApplier {
        self.otherAppliers = nil
        
        return self
    }
    
    fileprivate func apply(theme: Theme, isInitialApplication: Bool = false) {
        self.applyTheme(theme)
        
        // For the initial application of a ThemeApplier we don't want to apply the other
        // appliers (they should have already been applied so doing so is redundant
        guard !isInitialApplication else { return }
        
        // If there are otherAppliers stored against this one then trigger those as well
        self.otherAppliers?.forEach { applier in
            applier.applyTheme(theme)
        }
    }
}

// MARK: - Convenience Extensions

extension Array {
    fileprivate func appending(contentsOf other: [Element]?) -> [Element] {
        guard let other: [Element] = other else { return self }
        
        var updatedArray: [Element] = self
        updatedArray.append(contentsOf: other)
        return updatedArray
    }
}
