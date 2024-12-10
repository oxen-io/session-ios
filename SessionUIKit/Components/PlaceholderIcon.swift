// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import CryptoKit

public class PlaceholderIcon {
    private let seed: Int
    
    // Color palette
    private var colors: [UIColor] = Theme.PrimaryColor.allCases.map { $0.color }
    
    // MARK: - Initialization
    
    init(seed: Int, colors: [UIColor]? = nil) {
        self.seed = seed
        if let colors = colors { self.colors = colors }
    }
    
    // stringlint:ignore_contents
    convenience init(seed: String, colors: [UIColor]? = nil) {
        // Ensure we have a correct hash
        var hash = seed
        
        if (hash.matches("^[0-9A-Fa-f]+$") && hash.count >= 12) {
            // This is the same as the `SessionUtilitiesKit` `toHexString` function
            hash = Data(SHA512.hash(data: Data(Array(seed.utf8))).makeIterator())
                .map { String(format: "%02x", $0) }.joined()
        }
        
        guard let number = Int(String(hash.prefix(12)), radix: 16) else {
            self.init(seed: 0, colors: colors)
            return
        }
        
        self.init(seed: number, colors: colors)
    }
    
    // MARK: - Convenience
    
    // stringlint:ignore_contents
    public static func generate(seed: String, text: String, size: CGFloat) -> UIImage {
        let icon = PlaceholderIcon(seed: seed)
        
        var content: String = {
            guard text.hasSuffix("\(String(seed.suffix(4))))") else {
                guard let result: String = text.split(separator: "(").first.map({ String($0) }) else {
                    return text
                }
                
                return result
            }
            
            return text
        }()

        if ValidSessionIdPrefixes.hasValidPrefix(content) {
            content.removeFirst(2)
        }
        
        let initials: String = content
            .split(separator: " ")
            .compactMap { word in word.first.map { String($0) } }
            .joined()
        
        return SNUIKit.placeholderIconCacher(cacheKey: "\(content)-\(Int(floor(size)))") {
            let layer = icon.generateLayer(
                with: size,
                text: (initials.count >= 2 ?
                    String(initials.prefix(2)).uppercased() :
                    String(content.prefix(2)).uppercased()
                )
            )
            
            let rect = CGRect(origin: CGPoint.zero, size: layer.frame.size)
            let renderer = UIGraphicsImageRenderer(size: rect.size)
            
            return renderer.image { layer.render(in: $0.cgContext) }
        }
    }
    
    // MARK: - Internal
    
    private func generateLayer(with diameter: CGFloat, text: String) -> CALayer {
        let color: UIColor = self.colors[seed % self.colors.count]
        let base: CALayer = getTextLayer(with: diameter, color: color, text: text)
        base.masksToBounds = true
        
        return base
    }
    
    private func getTextLayer(with diameter: CGFloat, color: UIColor, text: String) -> CALayer {
        let font = UIFont.boldSystemFont(ofSize: diameter / 2)
        let height = NSString(string: text).boundingRect(with: CGSize(width: diameter, height: CGFloat.greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin, attributes: [ NSAttributedString.Key.font : font ], context: nil).height
        let frame = CGRect(x: 0, y: (diameter - height) / 2, width: diameter, height: height)
        
        let layer = CATextLayer()
        layer.frame = frame
        layer.themeForegroundColorForced = .color(.white)
        layer.contentsScale = UIScreen.main.scale
        
        let fontName = font.fontName
        let fontRef = CGFont(fontName as CFString)
        layer.font = fontRef
        layer.fontSize = font.pointSize
        layer.alignmentMode = .center
        layer.string = text
        
        let base = CALayer()
        base.frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        base.themeBackgroundColorForced = .color(color)
        base.addSublayer(layer)
        
        return base
    }
}

private extension String {
    func matches(_ regex: String) -> Bool {
        return self.range(of: regex, options: .regularExpression, range: nil, locale: nil) != nil
    }
}

/// These enums should always match the `SessionUtilitiesKit.SessionId.Prefix` cases
private enum ValidSessionIdPrefixes: String, CaseIterable {
    case standard = "05"
    case blinded15 = "15"
    case blinded25 = "25"
    case unblinded = "00"
    case group = "03"
    
    static func hasValidPrefix(_ value: String) -> Bool {
        return value.count >= 2 && allCases.map({ $0.rawValue }).contains(String(value.prefix(2)))
    }
}
