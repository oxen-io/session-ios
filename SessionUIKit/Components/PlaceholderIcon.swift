// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import CryptoKit
import SessionUtilitiesKit

public class PlaceholderIcon {
    private static let placeholderCache: Atomic<NSCache<NSString, UIImage>> = {
        let result = NSCache<NSString, UIImage>()
        result.countLimit = 50
        
        return Atomic(result)
    }()
    
    private let seed: Int
    
    // Colour palette
    private var colors: [UIColor] = Theme.PrimaryColor.allCases.map { $0.color }
    
    // MARK: - Initialization
    
    init(seed: Int, colors: [UIColor]? = nil) {
        self.seed = seed
        if let colors = colors { self.colors = colors }
    }
    
    convenience init(seed: String, colors: [UIColor]? = nil) {
        // Ensure we have a correct hash
        var hash = seed
        
        if (hash.matches("^[0-9A-Fa-f]+$") && hash.count >= 12) {
            hash = Data(SHA512.hash(data: Data(Array(seed.utf8))).makeIterator()).toHexString()
        }
        
        guard let number = Int(hash.substring(to: 12), radix: 16) else {
            SNLog("Failed to generate number from seed string: \(seed).")
            self.init(seed: 0, colors: colors)
            return
        }
        
        self.init(seed: number, colors: colors)
    }
    
    // MARK: - Convenience
    
    public static func generate(seed: String, text: String, size: CGFloat) -> UIImage {
        let icon = PlaceholderIcon(seed: seed)
        
        var content: String = (text.hasSuffix("\(String(seed.suffix(4))))") ?
            (text.split(separator: "(")
                .first
                .map { String($0) })
                .defaulting(to: text) :
                text
        )

        if content.count > 2 && (try? SessionId.Prefix(from: content)) != nil {
            content.removeFirst(2)
        }
        
        let initials: String = content
            .split(separator: " ")
            .compactMap { word in word.first.map { String($0) } }
            .joined()
        let cacheKey: String = "\(content)-\(Int(floor(size)))"
        
        if let cachedIcon: UIImage = placeholderCache.wrappedValue.object(forKey: cacheKey as NSString) {
            return cachedIcon
        }
        
        let layer = icon.generateLayer(
            with: size,
            text: (initials.count >= 2 ?
                initials.substring(to: 2).uppercased() :
                content.substring(to: 2).uppercased()
            )
        )
        
        let rect = CGRect(origin: CGPoint.zero, size: layer.frame.size)
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        let result = renderer.image { layer.render(in: $0.cgContext) }
        
        placeholderCache.mutate { $0.setObject(result, forKey: cacheKey as NSString) }
        
        return result
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
