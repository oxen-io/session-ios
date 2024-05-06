// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import UIKit.UIFont

public extension NSAttributedString {
    enum FormattedValue {
        case plain(String)
        case font(String, UIFont)
    }
    
    convenience init(
        format: String,
        _ arguments: FormattedValue...
    ) {
        // FIXME: This styling approach breaks with RTL languages and should be replaced as part of the Strings project
        self.init(
            attributedString: zip(format.components(separatedBy: "%@"), arguments.appending(.plain("")))
                .map { text, value -> (text: String, value: FormattedValue) in (text, value) }
                .enumerated()
                .reduce(into: NSMutableAttributedString()) { result, next in
                    result.append(NSAttributedString(string: next.element.text))
                    
                    switch next.element.value {
                        case .plain(let value): result.append(NSAttributedString(string: value))
                            
                        case .font(let value, let font):
                            result.append(NSAttributedString(string: value, attributes: [.font: font]))
                    }
                }
        )
    }
    
    static func with(_ attrStrings: [NSAttributedString]) -> NSAttributedString {
        let mutableString: NSMutableAttributedString = NSMutableAttributedString()
        
        for attrString in attrStrings {
            mutableString.append(attrString)
        }
        
        return mutableString
    }
    
    func appending(_ attrString: NSAttributedString) -> NSAttributedString {
        let mutableString: NSMutableAttributedString = NSMutableAttributedString(attributedString: self)
        mutableString.append(attrString)

        return mutableString
    }
    
    func appending(string: String, attributes: [Key: Any]? = nil) -> NSAttributedString {
        return appending(NSAttributedString(string: string, attributes: attributes))
    }
    
    func adding(attributes: [Key: Any], range: NSRange) -> NSAttributedString {
        let mutableString: NSMutableAttributedString = NSMutableAttributedString(attributedString: self)
        mutableString.addAttributes(attributes, range: range)

        return mutableString
    }

    // The actual Swift implementation of 'uppercased' is pretty nuts (see
    // https://github.com/apple/swift/blob/main/stdlib/public/core/String.swift#L901)
    // this approach is definitely less efficient but is much simpler and less likely to break
    private enum CharacterCasing {
        static let map: [UTF16.CodeUnit: String.UTF16View] = [
            "a": "A", "b": "B", "c": "C", "d": "D", "e": "E", "f": "F", "g": "G",
            "h": "H", "i": "I", "j": "J", "k": "K", "l": "L", "m": "M", "n": "N",
            "o": "O", "p": "P", "q": "Q", "r": "R", "s": "S", "t": "T", "u": "U",
            "v": "V", "w": "W", "x": "X", "y": "Y", "z": "Z"
        ]
        .reduce(into: [:]) { prev, next in
            prev[next.key.utf16.first ?? UTF16.CodeUnit()] = next.value.utf16
        }
    }
    
    func uppercased() -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: self)
        let uppercasedCharacters = result.string.utf16.map { utf16Char in
            // Try convert the individual utf16 character to it's uppercase variant
            // or fallback to the original character
            (CharacterCasing.map[utf16Char]?.first ?? utf16Char)
        }
        
        result.replaceCharacters(
            in: NSRange(location: 0, length: length),
            with: String(utf16CodeUnits: uppercasedCharacters, count: length)
        )

        return result
    }
}

// MARK: - HTML Tag Styling

public extension NSAttributedString {
    /// These are the tags we current support formatting for
    enum HTMLTag: String {
        /// The regex to recognize an open or close tag
        ///
        /// **Note:** The `{1,X}` defines a minimum and maximum tag length and may need to be updated if we add support
        /// for longer tags that are currently supported
        static let regexPattern: String = #"<(?<closeTag>\/)?(?<tagName>[A-Za-z0-9]{1,1})>"#
        
        case bold = "b"
        case italic = "i"
        case underline = "u"
        case strikethrough = "s"
        
        // MARK: - Functions
        
        static func from(_ stringValue: String) -> (tag: HTMLTag, closeTag: Bool)? {
            let isCloseTag: Bool = stringValue.starts(with: "</")
            
            return HTMLTag(
                rawValue: stringValue
                    .replacingOccurrences(of: "</", with: "")
                    .replacingOccurrences(of: "<", with: "")
                    .replacingOccurrences(of: ">", with: "")
            ).map { ($0, isCloseTag) }
        }
        
        func format(with font: UIFont) -> [NSAttributedString.Key: Any] {
            /// **Note:** Constructing a `UIFont` with a `size`of `0` will preserve the textSize
            switch self {
                case .bold: return [
                    .font: UIFont(
                        descriptor: (font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor),
                        size: 0
                    )
                ]
                case .italic: return [
                    .font: UIFont(
                        descriptor: (font.fontDescriptor.withSymbolicTraits(.traitItalic) ?? font.fontDescriptor),
                        size: 0
                    )
                ]
                case .underline: return [.underlineStyle: NSUnderlineStyle.single.rawValue]
                case .strikethrough: return [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
            }
        }
    }
    
    convenience init(stringWithHTMLTags: String?, font: UIFont) {
        guard
            let targetString: String = stringWithHTMLTags,
            let expression: NSRegularExpression = try? NSRegularExpression(
                pattern: HTMLTag.regexPattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
        else {
            self.init(string: (stringWithHTMLTags ?? ""))
            return
        }
        
        /// Construct the needed types
        ///
        /// **Note:** We use an `NSAttributedString` for retrieving string ranges because if we don't then emoji characters
        /// can cause odd behaviours with accessing ranges so this simplifies the logic
        let attrString: NSAttributedString = NSAttributedString(string: targetString)
        let stringLength: Int = targetString.utf16.count
        var partsAndTags: [(part: String, tags: [HTMLTag])] = []
        var openTags: [HTMLTag: Int] = [:]
        var lastMatch: NSTextCheckingResult?
        
        /// Enumerate through the HTMLTag matches and build up a list of formats to apply
        expression.enumerateMatches(in: targetString, range: NSMakeRange(0, stringLength)) { match, _, _ in
            guard let currentMatch: NSTextCheckingResult = match else { return }
            
            /// Store the positions for readability
            let lastMatchEnd: Int = (lastMatch?.range.upperBound ?? 0)
            let currentMatchStart: Int = currentMatch.range.lowerBound
            let currentMatchEnd: Int = currentMatch.range.upperBound
            
            /// Ignore invalid ranges
            guard currentMatchStart > lastMatchEnd else { return }
            
            /// Retrieve the tag and content values, store the content and any tags which are currently applied so we can construct the
            /// formatted string at the end
            let tagMatch: String = attrString[currentMatchStart..<currentMatchEnd]
            let rawStringBetweenMatch: String = attrString[lastMatchEnd..<currentMatchStart]
            partsAndTags.append((rawStringBetweenMatch, Array(openTags.keys)))
            
            /// If it's a valid tag then store the location information so we can apply styling later
            if let tagInfo: (tag: HTMLTag, closeTag: Bool) = HTMLTag.from(tagMatch) {
                switch (tagInfo.closeTag, openTags[tagInfo.tag]) {
                    /// Add the new opening tag
                    case (false, .none): openTags[tagInfo.tag] = 1
                        
                    /// Increment the number of opening tags for the pending format so we can be sure to close them correctly
                    case (false, .some(let openCount)): openTags[tagInfo.tag] = (openCount + 1)
                    
                    /// If we had multiple open tags then just decrement the value
                    case (true, .some(let openCount)) where openCount > 1: openTags[tagInfo.tag] = (openCount - 1)
                        
                    /// Otherwise we have a valid format chunk so should collapse it
                    case (true, .some): openTags[tagInfo.tag] = nil
                    
                    /// Ignore close tags with no corresponding open tags
                    case (true, .none): break
                }
            }
            
            /// Store the the `lastMatch` value for appending the final part of the content
            lastMatch = currentMatch
        }
        
        /// If we don't have a `lastMatch` value then we weren't able to get a single valid tag match so just stop here are return the `targetString`
        guard let finalMatch: NSTextCheckingResult = lastMatch else {
            self.init(string: targetString)
            return
        }
        
        /// If the final regex match isn't at the end of the string then we need to append the final part of the string to avoid it getting truncated
        ///
        /// **Note:** When there is an opening tag but no closing tag browsers seem to apply the style from the opening tag to the end of
        /// the string so we should do the same here
        if stringLength > finalMatch.range.upperBound {
            partsAndTags.append((attrString[finalMatch.range.upperBound...], Array(openTags.keys)))
        }
        
        /// Lastly we should construct the attributed string, applying the desired formatting
        self.init(
            attributedString: partsAndTags.reduce(into: NSMutableAttributedString()) { result, next in
                result.append(NSAttributedString(string: next.part, attributes: next.tags.format(with: font)))
            }
        )
    }
    
    private subscript(range: Range<Int>) -> String {
        attributedSubstring(from: NSMakeRange(range.lowerBound, (range.upperBound - range.lowerBound))).string
    }
    
    private subscript(range: PartialRangeFrom<Int>) -> String {
        let upperBound: Int = self.string.utf16.count
        return attributedSubstring(from: NSMakeRange(range.lowerBound, (upperBound - range.lowerBound))).string
    }
    
    private subscript(range: PartialRangeThrough<Int>) -> String {
        attributedSubstring(from: NSMakeRange(0, range.upperBound)).string
    }
}

private extension Collection where Element == NSAttributedString.HTMLTag {
    func format(with font: UIFont) -> [NSAttributedString.Key: Any] {
        func fontWith(_ font: UIFont, traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
            /// **Note:** Constructing a `UIFont` with a `size`of `0` will preserve the textSize
            return UIFont(
                descriptor: (font.fontDescriptor.withSymbolicTraits(traits) ?? font.fontDescriptor),
                size: 0
            )
        }
        
        return self.reduce(into: [NSAttributedString.Key: Any]()) { result, tag in
            switch tag {
                case .bold where self.contains(.italic), .italic where self.contains(.bold):
                    result[.font] = fontWith(font, traits: [.traitBold, .traitItalic])
                    
                case .bold: result[.font] = fontWith(font, traits: [.traitBold])
                case .italic: result[.font] = fontWith(font, traits: [.traitItalic])
                case .underline: result[.underlineStyle] = NSUnderlineStyle.single.rawValue
                case .strikethrough: result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
        }
    }
}
