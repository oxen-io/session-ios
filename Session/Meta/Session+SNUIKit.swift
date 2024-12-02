// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - SessionSNUIKitConfig

internal struct SessionSNUIKitConfig: SNUIKit.ConfigType {
    private let dependencies: Dependencies
    
    var maxFileSize: UInt { Network.maxFileSize }
    var isStorageValid: Bool { dependencies[singleton: .storage].isValid }
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Functions
    
    func themeChanged(_ theme: Theme, _ primaryColor: Theme.PrimaryColor, _ matchSystemNightModeSetting: Bool) {
        dependencies[singleton: .storage].write { db in
            db[.theme] = theme
            db[.themePrimaryColor] = primaryColor
            db[.themeMatchSystemDayNightCycle] = matchSystemNightModeSetting
        }
    }
    
    func persistentTopBannerChanged(warningKey: String?) {
        dependencies[defaults: .appGroup, key: .topBannerWarningToShow] = warningKey
    }
    
    func cachedContextualActionInfo(tableViewHash: Int, sideKey: String) -> [Int: Any]? {
        dependencies[cache: .general].contextualActionLookupMap
            .getting(tableViewHash)?
            .getting(sideKey)
    }
    
    func cacheContextualActionInfo(tableViewHash: Int, sideKey: String, actionIndex: Int, actionInfo: Any) {
        dependencies.mutate(cache: .general) { cache in
            let updatedLookup = (cache.contextualActionLookupMap[tableViewHash] ?? [:])
                .setting(
                    sideKey,
                    ((cache.contextualActionLookupMap[tableViewHash] ?? [:]).getting(sideKey) ?? [:])
                        .setting(actionIndex, actionInfo)
                )
            
            cache.contextualActionLookupMap[tableViewHash] = updatedLookup
        }
    }
    
    func removeCachedContextualActionInfo(tableViewHash: Int, keys: [String]) {
        dependencies.mutate(cache: .general) { cache in
            keys.forEach { key in
                cache.contextualActionLookupMap[tableViewHash]?[key] = nil
            }
            
            if cache.contextualActionLookupMap[tableViewHash]?.isEmpty == true {
                cache.contextualActionLookupMap[tableViewHash] = nil
            }
        }
    }
    
    func placeholderIconCacher(cacheKey: String, generator: @escaping () -> UIImage) -> UIImage {
        if let cachedIcon: UIImage = dependencies[cache: .general].placeholderCache.object(forKey: cacheKey as NSString) {
            return cachedIcon
        }
        
        let generatedImage: UIImage = generator()
        dependencies.mutate(cache: .general) {
            $0.placeholderCache.setObject(generatedImage, forKey: cacheKey as NSString)
        }
        
        return generatedImage
    }
    
    func localizedString(for key: String) -> String {
        return key.localized()
    }
    
    public static func localizedFormatted(_ helper: LocalizationHelper, _ baseFont: UIFont) -> NSAttributedString {
        return NSAttributedString(stringWithHTMLTags: helper.localized(), font: baseFont)
    }
    
    public static func localizedDeformatted(_ helper: LocalizationHelper) -> String {
        return NSAttributedString(stringWithHTMLTags: helper.localized(), font: .systemFont(ofSize: 14)).string
    }
}

// MARK: - SNUIKit Localization

public extension LocalizationHelper {
    func localizedFormatted(in view: FontAccessible) -> NSAttributedString {
        return localizedFormatted(baseFont: (view.fontValue ?? .systemFont(ofSize: 14)))
    }    
}

public extension String {
    func localizedFormatted(in view: FontAccessible) -> NSAttributedString {
        return LocalizationHelper(template: self).localizedFormatted(in: view)
    }
}
