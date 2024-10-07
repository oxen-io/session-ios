// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public extension UIButton {
    func withConfiguration(_ configuration: UIButton.Configuration) -> UIButton {
        self.configuration = configuration
        return self
    }
    
    func withConfigurationUpdateHandler(_ configurationUpdateHandler: UIButton.ConfigurationUpdateHandler?) -> UIButton {
        self.configurationUpdateHandler = configurationUpdateHandler
        return self
    }
    
    func withAccessibility(identifier: String? = nil, label: String? = nil) -> UIButton {
        self.isAccessibilityElement = (identifier != nil || label != nil)
        self.accessibilityIdentifier = identifier
        self.accessibilityLabel = label
        return self
    }
    
    func withImageViewContentMode(_ contentMode: UIView.ContentMode) -> UIButton {
        self.imageView?.contentMode = contentMode
        return self
    }
    
    func withThemeTintColor(_ tintColor: ThemeValue?) -> UIButton {
        self.themeTintColor = tintColor
        return self
    }
    
    func withThemeBackgroundColor(_ backgroundColor: ThemeValue?) -> UIButton {
        self.themeBackgroundColor = backgroundColor
        return self
    }
    
    func withHidden(_ hidden: Bool) -> UIButton {
        self.isHidden = hidden
        return self
    }
    
    func withCornerRadius(_ cornerRadius: CGFloat) -> UIButton {
        self.layer.cornerRadius = cornerRadius
        return self
    }
    
    func with(_ dimension: Dimension, of size: CGFloat) -> UIButton {
        self.set(dimension, to: size)
        return self
    }
}

public extension UIButton.Configuration {
    func withImage(_ image: UIImage?) -> UIButton.Configuration {
        var updatedConfig: UIButton.Configuration = self
        updatedConfig.image = image
        return updatedConfig
    }
    
    func withContentInsets(_ contentInsets: NSDirectionalEdgeInsets) -> UIButton.Configuration {
        var updatedConfig: UIButton.Configuration = self
        updatedConfig.contentInsets = contentInsets
        return updatedConfig
    }
    
    func withBaseForegroundColor(_ baseForegroundColor: UIColor) -> UIButton.Configuration {
        var updatedConfig: UIButton.Configuration = self
        updatedConfig.baseForegroundColor = baseForegroundColor
        return updatedConfig
    }
}
