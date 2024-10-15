// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit.UIColor
import SwiftUI

// MARK: - Primary Colors

public extension Theme {
    enum PrimaryColor: String, Codable, CaseIterable {
        case green
        case blue
        case yellow
        case pink
        case purple
        case orange
        case red
        
        internal init?(color: UIColor?) {
            guard
                let color: UIColor = color,
                let primaryColor: PrimaryColor = PrimaryColor.allCases.first(where: { $0.color == color })
            else { return nil }
            
            self = primaryColor
        }
        
        internal init?(color: Color?) {
            guard
                let color: Color = color,
                let primaryColor: PrimaryColor = PrimaryColor.allCases.first(where: { $0.colorSwiftUI == color })
            else { return nil }
            
            self = primaryColor
        }
        
        public var color: UIColor {
            switch self {
                case .green:  return #colorLiteral(red: 0.1921568627, green: 0.9450980392, blue: 0.5882352941, alpha: 1)         // #31F196
                case .blue:   return #colorLiteral(red: 0.3411764706, green: 0.7882352941, blue: 0.9803921569, alpha: 1)         // #57C9FA
                case .yellow: return #colorLiteral(red: 0.9803921569, green: 0.8392156863, blue: 0.3411764706, alpha: 1)         // #FAD657
                case .pink:   return #colorLiteral(red: 1, green: 0.5843137255, blue: 0.937254902, alpha: 1)         // #FF95EF
                case .purple: return #colorLiteral(red: 0.7882352941, green: 0.5764705882, blue: 1, alpha: 1)         // #C993FF
                case .orange: return #colorLiteral(red: 0.9882352941, green: 0.6941176471, blue: 0.3490196078, alpha: 1)         // #FCB159
                case .red:    return #colorLiteral(red: 1, green: 0.6117647059, blue: 0.5568627451, alpha: 1)         // #FF9C8E
            }
        }
        
        // FIXME: Clean it when Xcode can show the color panel in "return Color(#colorLiteral())"
        public var colorSwiftUI: Color {
            switch self {
                case .green:
                    let color: Color = Color(#colorLiteral(red: 0.1921568627, green: 0.9450980392, blue: 0.5882352941, alpha: 1))         // #31F196
                    return color
                case .blue:
                    let color: Color = Color(#colorLiteral(red: 0.3411764706, green: 0.7882352941, blue: 0.9803921569, alpha: 1))         // #57C9FA
                    return color
                case .yellow:
                    let color: Color = Color(#colorLiteral(red: 0.9803921569, green: 0.8392156863, blue: 0.3411764706, alpha: 1))         // #FAD657
                    return color
                case .pink:
                    let color: Color = Color(#colorLiteral(red: 1, green: 0.5843137255, blue: 0.937254902, alpha: 1))         // #FF95EF
                    return color
                case .purple:
                    let color: Color = Color(#colorLiteral(red: 0.7882352941, green: 0.5764705882, blue: 1, alpha: 1))         // #C993FF
                    return color
                case .orange:
                    let color: Color = Color(#colorLiteral(red: 0.9882352941, green: 0.6941176471, blue: 0.3490196078, alpha: 1))         // #FCB159
                    return color
                case .red:
                    let color: Color = Color(#colorLiteral(red: 1, green: 0.6117647059, blue: 0.5568627451, alpha: 1))         // #FF9C8E
                    return color
            }
        }
    }
}

// MARK: - Standard Theme Colors

internal extension UIColor {
    static let warning: UIColor = #colorLiteral(red: 0.9882352941, green: 0.6941176471, blue: 0.3490196078, alpha: 1)            // #FCB159
    static let dangerDark: UIColor = #colorLiteral(red: 1, green: 0.2274509804, blue: 0.2274509804, alpha: 1)         // #FF3A3A
    static let dangerLight: UIColor = #colorLiteral(red: 0.8823529412, green: 0.1764705882, blue: 0.09803921569, alpha: 1)        // #E12D19
    static let disabledDark: UIColor = #colorLiteral(red: 0.4274509804, green: 0.4274509804, blue: 0.4274509804, alpha: 1 )       // #6D6D6D
    static let disabledLight: UIColor = #colorLiteral(red: 0.631372549, green: 0.6352941176, blue: 0.631372549, alpha: 1)      // #A1A2A1
    static let black_06: UIColor = #colorLiteral(red: 0, green: 0, blue: 0, alpha: 0.06)           // #000000
    
    static let pathConnected: UIColor = #colorLiteral(red: 0.1921568627, green: 0.9450980392, blue: 0.5882352941, alpha: 1)      // #31F196
    static let pathConnecting: UIColor = #colorLiteral(red: 0.9882352941, green: 0.6941176471, blue: 0.3490196078, alpha: 1)     // #FCB159
    static let pathError: UIColor = #colorLiteral(red: 0.9176470588, green: 0.3333333333, blue: 0.2705882353, alpha: 1)          // #EA5545
    
    static let classicDark0: UIColor = #colorLiteral(red: 0, green: 0, blue: 0, alpha: 1)       // #000000
    static let classicDark1: UIColor = #colorLiteral(red: 0.1058823529, green: 0.1058823529, blue: 0.1058823529, alpha: 1)       // #1B1B1B
    static let classicDark2: UIColor = #colorLiteral(red: 0.1764705882, green: 0.1764705882, blue: 0.1764705882, alpha: 1)       // #2D2D2D
    static let classicDark3: UIColor = #colorLiteral(red: 0.2549019608, green: 0.2549019608, blue: 0.2549019608, alpha: 1)       // #414141
    static let classicDark4: UIColor = #colorLiteral(red: 0.462745098, green: 0.462745098, blue: 0.462745098, alpha: 1)       // #767676
    static let classicDark5: UIColor = #colorLiteral(red: 0.631372549, green: 0.6352941176, blue: 0.631372549, alpha: 1)       // #A1A2A1
    static let classicDark6: UIColor = #colorLiteral(red: 1, green: 1, blue: 1, alpha: 1)       // #FFFFFF
    
    static let classicLight0: UIColor = #colorLiteral(red: 0, green: 0, blue: 0, alpha: 1)      // #000000
    static let classicLight1: UIColor = #colorLiteral(red: 0.4274509804, green: 0.4274509804, blue: 0.4274509804, alpha: 1)      // #6D6D6D
    static let classicLight2: UIColor = #colorLiteral(red: 0.631372549, green: 0.6352941176, blue: 0.631372549, alpha: 1)      // #A1A2A1
    static let classicLight3: UIColor = #colorLiteral(red: 0.8745098039, green: 0.8745098039, blue: 0.8745098039, alpha: 1)      // #DFDFDF
    static let classicLight4: UIColor = #colorLiteral(red: 0.9411764706, green: 0.9411764706, blue: 0.9411764706, alpha: 1)      // #F0F0F0
    static let classicLight5: UIColor = #colorLiteral(red: 0.9764705882, green: 0.9764705882, blue: 0.9764705882, alpha: 1)      // #F9F9F9
    static let classicLight6: UIColor = #colorLiteral(red: 1, green: 1, blue: 1, alpha: 1)      // #FFFFFF
    
    static let oceanDark0: UIColor = #colorLiteral(red: 0, green: 0, blue: 0, alpha: 1)         // #000000
    static let oceanDark1: UIColor = #colorLiteral(red: 0.1019607843, green: 0.1098039216, blue: 0.1568627451, alpha: 1)         // #1A1C28
    static let oceanDark2: UIColor = #colorLiteral(red: 0.1450980392, green: 0.1529411765, blue: 0.2078431373, alpha: 1)         // #252735
    static let oceanDark3: UIColor = #colorLiteral(red: 0.168627451, green: 0.1764705882, blue: 0.2509803922, alpha: 1)         // #2B2D40
    static let oceanDark4: UIColor = #colorLiteral(red: 0.2392156863, green: 0.2901960784, blue: 0.3647058824, alpha: 1)         // #3D4A5D
    static let oceanDark5: UIColor = #colorLiteral(red: 0.6509803922, green: 0.662745098, blue: 0.8078431373, alpha: 1)         // #A6A9CE
    static let oceanDark6: UIColor = #colorLiteral(red: 0.3607843137, green: 0.6666666667, blue: 0.8, alpha: 1)         // #5CAACC
    static let oceanDark7: UIColor = #colorLiteral(red: 1, green: 1, blue: 1, alpha: 1)         // #FFFFFF
    
    static let oceanLight0: UIColor = #colorLiteral(red: 0, green: 0, blue: 0, alpha: 1)        // #000000
    static let oceanLight1: UIColor = #colorLiteral(red: 0.09803921569, green: 0.2039215686, blue: 0.3647058824, alpha: 1)        // #19345D
    static let oceanLight2: UIColor = #colorLiteral(red: 0.4156862745, green: 0.431372549, blue: 0.5647058824, alpha: 1)        // #6A6E90
    static let oceanLight3: UIColor = #colorLiteral(red: 0.3607843137, green: 0.6666666667, blue: 0.8, alpha: 1)        // #5CAACC
    static let oceanLight4: UIColor = #colorLiteral(red: 0.7019607843, green: 0.9294117647, blue: 0.9490196078, alpha: 1)        // #B3EDF2
    static let oceanLight5: UIColor = #colorLiteral(red: 0.9058823529, green: 0.9529411765, blue: 0.9568627451, alpha: 1)        // #E7F3F4
    static let oceanLight6: UIColor = #colorLiteral(red: 0.9254901961, green: 0.9803921569, blue: 0.9843137255, alpha: 1)        // #ECFAFB
    static let oceanLight7: UIColor = #colorLiteral(red: 0.9882352941, green: 1, blue: 1, alpha: 1)        // #FCFFFF
}

public extension UIColor {
    static let primary: UIColor = UIColor(dynamicProvider: { _ in
        return ThemeManager.primaryColor.color
    })
}

internal extension Color {
    static let warning: Color = Color(#colorLiteral(red: 0.9882352941, green: 0.6941176471, blue: 0.3490196078, alpha: 1))            // #FCB159
    static let dangerDark: Color = Color(#colorLiteral(red: 1, green: 0.2274509804, blue: 0.2274509804, alpha: 1))         // #FF3A3A
    static let dangerLight: Color = Color(#colorLiteral(red: 0.8823529412, green: 0.1764705882, blue: 0.09803921569, alpha: 1))        // #E12D19
    static let disabledDark: Color = Color(#colorLiteral(red: 0.4274509804, green: 0.4274509804, blue: 0.4274509804, alpha: 1 ))       // #6D6D6D
    static let disabledLight: Color = Color(#colorLiteral(red: 0.631372549, green: 0.6352941176, blue: 0.631372549, alpha: 1))      // #A1A2A1
    static let black_06: Color = Color(#colorLiteral(red: 0, green: 0, blue: 0, alpha: 0.06))           // #000000
    
    static let pathConnected: Color = Color(#colorLiteral(red: 0.1921568627, green: 0.9450980392, blue: 0.5882352941, alpha: 1))      // #31F196
    static let pathConnecting: Color = Color(#colorLiteral(red: 0.9882352941, green: 0.6941176471, blue: 0.3490196078, alpha: 1))     // #FCB159
    static let pathError: Color = Color(#colorLiteral(red: 0.9176470588, green: 0.3333333333, blue: 0.2705882353, alpha: 1))          // #EA5545
    
    static let classicDark0: Color = Color(#colorLiteral(red: 0, green: 0, blue: 0, alpha: 1))       // #000000
    static let classicDark1: Color = Color(#colorLiteral(red: 0.1058823529, green: 0.1058823529, blue: 0.1058823529, alpha: 1))       // #1B1B1B
    static let classicDark2: Color = Color(#colorLiteral(red: 0.1764705882, green: 0.1764705882, blue: 0.1764705882, alpha: 1))       // #2D2D2D
    static let classicDark3: Color = Color(#colorLiteral(red: 0.2549019608, green: 0.2549019608, blue: 0.2549019608, alpha: 1))       // #414141
    static let classicDark4: Color = Color(#colorLiteral(red: 0.462745098, green: 0.462745098, blue: 0.462745098, alpha: 1))       // #767676
    static let classicDark5: Color = Color(#colorLiteral(red: 0.631372549, green: 0.6352941176, blue: 0.631372549, alpha: 1))       // #A1A2A1
    static let classicDark6: Color = Color(#colorLiteral(red: 1, green: 1, blue: 1, alpha: 1))       // #FFFFFF
    
    static let classicLight0: Color = Color(#colorLiteral(red: 0, green: 0, blue: 0, alpha: 1))      // #000000
    static let classicLight1: Color = Color(#colorLiteral(red: 0.4274509804, green: 0.4274509804, blue: 0.4274509804, alpha: 1))      // #6D6D6D
    static let classicLight2: Color = Color(#colorLiteral(red: 0.631372549, green: 0.6352941176, blue: 0.631372549, alpha: 1))      // #A1A2A1
    static let classicLight3: Color = Color(#colorLiteral(red: 0.8745098039, green: 0.8745098039, blue: 0.8745098039, alpha: 1))      // #DFDFDF
    static let classicLight4: Color = Color(#colorLiteral(red: 0.9411764706, green: 0.9411764706, blue: 0.9411764706, alpha: 1))      // #F0F0F0
    static let classicLight5: Color = Color(#colorLiteral(red: 0.9764705882, green: 0.9764705882, blue: 0.9764705882, alpha: 1))      // #F9F9F9
    static let classicLight6: Color = Color(#colorLiteral(red: 1, green: 1, blue: 1, alpha: 1))      // #FFFFFF
    
    static let oceanDark0: Color = Color(#colorLiteral(red: 0, green: 0, blue: 0, alpha: 1))         // #000000
    static let oceanDark1: Color = Color(#colorLiteral(red: 0.1019607843, green: 0.1098039216, blue: 0.1568627451, alpha: 1))         // #1A1C28
    static let oceanDark2: Color = Color(#colorLiteral(red: 0.1450980392, green: 0.1529411765, blue: 0.2078431373, alpha: 1))         // #252735
    static let oceanDark3: Color = Color(#colorLiteral(red: 0.168627451, green: 0.1764705882, blue: 0.2509803922, alpha: 1))         // #2B2D40
    static let oceanDark4: Color = Color(#colorLiteral(red: 0.2392156863, green: 0.2901960784, blue: 0.3647058824, alpha: 1))         // #3D4A5D
    static let oceanDark5: Color = Color(#colorLiteral(red: 0.6509803922, green: 0.662745098, blue: 0.8078431373, alpha: 1))         // #A6A9CE
    static let oceanDark6: Color = Color(#colorLiteral(red: 0.3607843137, green: 0.6666666667, blue: 0.8, alpha: 1))         // #5CAACC
    static let oceanDark7: Color = Color(#colorLiteral(red: 1, green: 1, blue: 1, alpha: 1))         // #FFFFFF
    
    static let oceanLight0: Color = Color(#colorLiteral(red: 0, green: 0, blue: 0, alpha: 1))        // #000000
    static let oceanLight1: Color = Color(#colorLiteral(red: 0.09803921569, green: 0.2039215686, blue: 0.3647058824, alpha: 1))        // #19345D
    static let oceanLight2: Color = Color(#colorLiteral(red: 0.4156862745, green: 0.431372549, blue: 0.5647058824, alpha: 1))        // #6A6E90
    static let oceanLight3: Color = Color(#colorLiteral(red: 0.3607843137, green: 0.6666666667, blue: 0.8, alpha: 1))        // #5CAACC
    static let oceanLight4: Color = Color(#colorLiteral(red: 0.7019607843, green: 0.9294117647, blue: 0.9490196078, alpha: 1))        // #B3EDF2
    static let oceanLight5: Color = Color(#colorLiteral(red: 0.9058823529, green: 0.9529411765, blue: 0.9568627451, alpha: 1))        // #E7F3F4
    static let oceanLight6: Color = Color(#colorLiteral(red: 0.9254901961, green: 0.9803921569, blue: 0.9843137255, alpha: 1))        // #ECFAFB
    static let oceanLight7: Color = Color(#colorLiteral(red: 0.9882352941, green: 1, blue: 1, alpha: 1))        // #FCFFFF
}

public extension Color {
    static var primary: Color {
        return Color(UIColor.primary)
    }
}
