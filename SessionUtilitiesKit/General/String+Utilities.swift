// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CoreText

public extension String {
    var bytes: [UInt8] { Array(self.utf8) }
    
    var nullIfEmpty: String? {
        guard isEmpty else { return self }
        
        return nil
    }
    
    var glyphCount: Int {
        let richText = NSAttributedString(string: self)
        let line = CTLineCreateWithAttributedString(richText)
        
        return CTLineGetGlyphCount(line)
    }
    
    var isSingleAlphabet: Bool {
        return (glyphCount == 1 && isAlphabetic)
    }
    
    var isAlphabetic: Bool {
        return !isEmpty && range(of: "[^a-zA-Z]", options: .regularExpression) == nil
    }

    var isSingleEmoji: Bool {
        return (glyphCount == 1 && containsEmoji)
    }

    var containsEmoji: Bool {
        return unicodeScalars.contains { $0.isEmoji }
    }

    var containsOnlyEmoji: Bool {
        return (
            !isEmpty &&
            !unicodeScalars.contains(where: {
                !$0.isEmoji &&
                !$0.isZeroWidthJoiner
            })
        )
    }
    
    func localized() -> String {
        // If the localized string matches the key provided then the localisation failed
        let localizedString = NSLocalizedString(self, comment: "")
        Log.assert(localizedString != self, "Key \"\(self)\" is not set in Localizable.strings")

        return localizedString
    }
    
    func ranges(of substring: String, options: CompareOptions = [], locale: Locale? = nil) -> [Range<Index>] {
        var ranges: [Range<Index>] = []
        
        while
            (ranges.last.map({ $0.upperBound < self.endIndex }) ?? true),
            let range = self.range(
                of: substring,
                options: options,
                range: (ranges.last?.upperBound ?? self.startIndex)..<self.endIndex,
                locale: locale
            )
        {
            ranges.append(range)
        }
        
        return ranges
    }
    
    static func filterNotificationText(_ text: String?) -> String? {
        guard let text = text?.filteredForDisplay else { return nil }

        // iOS strips anything that looks like a printf formatting character from
        // the notification body, so if we want to dispay a literal "%" in a notification
        // it must be escaped.
        // see https://developer.apple.com/documentation/uikit/uilocalnotification/1616646-alertbody
        // for more details.
        return text.replacingOccurrences(of: "%", with: "%%")
    }
    
    func appending(_ other: String?) -> String {
        guard let value: String = other else { return self }
        
        return self.appending(value)
    }
}

// MARK: - Formatting

public extension String.StringInterpolation {
    mutating func appendInterpolation(plural value: Int) {
        appendInterpolation(value == 1 ? "" : "s") // stringlint:disable
    }
    
    mutating func appendInterpolation(pluralES value: Int) {
        appendInterpolation(value == 1 ? "" : "es") // stringlint:disable
    }
    
    mutating func appendInterpolation(_ value: String, number: Int, singular: String = "", plural: String = "s") {
        appendInterpolation("\(value)\(number == 1 ? singular : plural)") // stringlint:disable
    }
    
    mutating func appendInterpolation(_ value: TimeUnit, unit: TimeUnit.Unit, resolution: Int = 2) {
        appendLiteral("\(TimeUnit(value, unit: unit, resolution: resolution))") // stringlint:disable
    }
    
    mutating func appendInterpolation(_ value: Int, format: String) {
        let result: String = String(format: "%\(format)d", value)
        appendLiteral(result)
    }
    
    mutating func appendInterpolation(_ value: Double, format: String, omitZeroDecimal: Bool = false) {
        guard !omitZeroDecimal || Int(exactly: value) == nil else {
            appendLiteral("\(Int(exactly: value)!)")
            return
        }
        
        let result: String = String(format: "%\(format)f", value)
        appendLiteral(result)
    }
}

public extension String {
    static func formattedDuration(_ duration: TimeInterval, format: TimeInterval.DurationFormat = .short) -> String {
        let secondsPerMinute: TimeInterval = 60
        let secondsPerHour: TimeInterval = (secondsPerMinute * 60)
        let secondsPerDay: TimeInterval = (secondsPerHour * 24)
        let secondsPerWeek: TimeInterval = (secondsPerDay * 7)
        
        switch format {
            case .videoDuration:
                let seconds: Int = Int(duration.truncatingRemainder(dividingBy: 60))
                let minutes: Int = Int((duration / 60).truncatingRemainder(dividingBy: 60))
                let hours: Int = Int(duration / 3600)
                
                guard hours > 0 else { return String(format: "%02ld:%02ld", minutes, seconds) }
                
                return String(format: "%ld:%02ld:%02ld", hours, minutes, seconds)
            
            case .hoursMinutesSeconds:
                let seconds: Int = Int(duration.truncatingRemainder(dividingBy: 60))
                let minutes: Int = Int((duration / 60).truncatingRemainder(dividingBy: 60))
                let hours: Int = Int(duration / 3600)
                
                guard hours > 0 else { return String(format: "%ld:%02ld", minutes, seconds) }
                
                return String(format: "%ld:%02ld:%02ld", hours, minutes, seconds)
                
            case .short:
                switch duration {
                    case 0..<secondsPerMinute:  // Seconds
                        return String(
                            format: "TIME_AMOUNT_SECONDS_SHORT_FORMAT".localized(),
                            NumberFormatter.localizedString(
                                from: NSNumber(floatLiteral: floor(duration)),
                                number: .none
                            )
                        )
                    
                    case secondsPerMinute..<secondsPerHour:   // Minutes
                        return String(
                            format: "TIME_AMOUNT_MINUTES_SHORT_FORMAT".localized(),
                            NumberFormatter.localizedString(
                                from: NSNumber(floatLiteral: floor(duration / secondsPerMinute)),
                                number: .none
                            )
                        )
                        
                    case secondsPerHour..<secondsPerDay:   // Hours
                        return String(
                            format: "TIME_AMOUNT_HOURS_SHORT_FORMAT".localized(),
                            NumberFormatter.localizedString(
                                from: NSNumber(floatLiteral: floor(duration / secondsPerHour)),
                                number: .none
                            )
                        )
                        
                    case secondsPerDay..<secondsPerWeek:   // Days
                        return String(
                            format: "TIME_AMOUNT_DAYS_SHORT_FORMAT".localized(),
                            NumberFormatter.localizedString(
                                from: NSNumber(floatLiteral: floor(duration / secondsPerDay)),
                                number: .none
                            )
                        )
                        
                    default:   // Weeks
                        return String(
                            format: "TIME_AMOUNT_WEEKS_SHORT_FORMAT".localized(),
                            NumberFormatter.localizedString(
                                from: NSNumber(floatLiteral: floor(duration / secondsPerWeek)),
                                number: .none
                            )
                        )
                }
                
            case .long:
                switch duration {
                    case 0..<secondsPerMinute:  // XX Seconds
                        return String(
                            format: "TIME_AMOUNT_SECONDS".localized(),
                            NumberFormatter.localizedString(
                                from: NSNumber(floatLiteral: floor(duration)),
                                number: .none
                            )
                        )
                    
                    case secondsPerMinute..<(secondsPerMinute * 1.5):   // 1 Minute
                        return String(
                            format: "TIME_AMOUNT_SINGLE_MINUTE".localized(),
                            NumberFormatter.localizedString(
                                from: NSNumber(floatLiteral: floor(duration / secondsPerMinute)),
                                number: .none
                            )
                        )
                        
                    case (secondsPerMinute * 1.5)..<secondsPerHour:   // Multiple Minutes
                        return String(
                            format: "TIME_AMOUNT_MINUTES".localized(),
                            NumberFormatter.localizedString(
                                from: NSNumber(floatLiteral: floor(duration / secondsPerMinute)),
                                number: .none
                            )
                        )
                        
                    case secondsPerHour..<(secondsPerHour * 1.5):   // 1 Hour
                        return String(
                            format: "TIME_AMOUNT_SINGLE_HOUR".localized(),
                            NumberFormatter.localizedString(
                                from: NSNumber(floatLiteral: floor(duration / secondsPerHour)),
                                number: .none
                            )
                        )
                        
                    case (secondsPerHour * 1.5)..<secondsPerDay:   // Multiple Hours
                        return String(
                            format: "TIME_AMOUNT_HOURS".localized(),
                            NumberFormatter.localizedString(
                                from: NSNumber(floatLiteral: floor(duration / secondsPerHour)),
                                number: .none
                            )
                        )
                        
                    case secondsPerDay..<(secondsPerDay * 1.5):   // 1 Day
                        return String(
                            format: "TIME_AMOUNT_SINGLE_DAY".localized(),
                            NumberFormatter.localizedString(
                                from: NSNumber(floatLiteral: floor(duration / secondsPerDay)),
                                number: .none
                            )
                        )
                        
                    case (secondsPerDay * 1.5)..<secondsPerWeek:   // Multiple Days
                        return String(
                            format: "TIME_AMOUNT_DAYS".localized(),
                            NumberFormatter.localizedString(
                                from: NSNumber(floatLiteral: floor(duration / secondsPerDay)),
                                number: .none
                            )
                        )
                        
                    case secondsPerWeek..<(secondsPerWeek * 1.5):   // 1 Week
                        return String(
                            format: "TIME_AMOUNT_SINGLE_WEEK".localized(),
                            NumberFormatter.localizedString(
                                from: NSNumber(floatLiteral: floor(duration / secondsPerWeek)),
                                number: .none
                            )
                        )
                        
                    default:   // Multiple Weeks
                        return String(
                            format: "TIME_AMOUNT_WEEKS".localized(),
                            NumberFormatter.localizedString(
                                from: NSNumber(floatLiteral: floor(duration / secondsPerWeek)),
                                number: .none
                            )
                        )
                }
            case .twoUnits:
                let seconds: Int = Int(duration.truncatingRemainder(dividingBy: 60))
                let minutes: Int = Int((duration / 60).truncatingRemainder(dividingBy: 60))
                let hours: Int = Int((duration / 3600).truncatingRemainder(dividingBy: 24))
                let days: Int = Int((duration / 3600 / 24).truncatingRemainder(dividingBy: 7))
                let weeks: Int = Int(duration / 3600 / 24 / 7)
            
                guard weeks == 0 else {
                    return String(
                        format: "TIME_AMOUNT_WEEKS_SHORT_FORMAT".localized(),
                        NumberFormatter.localizedString(
                            from: NSNumber(integerLiteral: weeks),
                            number: .none
                        )
                    ) + " " + String(
                        format: "TIME_AMOUNT_DAYS_SHORT_FORMAT".localized(),
                        NumberFormatter.localizedString(
                            from: NSNumber(integerLiteral: days),
                            number: .none
                        )
                    )
                }
                
                guard days == 0 else {
                    return String(
                        format: "TIME_AMOUNT_DAYS_SHORT_FORMAT".localized(),
                        NumberFormatter.localizedString(
                            from: NSNumber(integerLiteral: days),
                            number: .none
                        )
                    ) + " " + String(
                        format: "TIME_AMOUNT_HOURS_SHORT_FORMAT".localized(),
                        NumberFormatter.localizedString(
                            from: NSNumber(integerLiteral: hours),
                            number: .none
                        )
                    )
                }
            
                guard hours == 0 else {
                    return String(
                        format: "TIME_AMOUNT_HOURS_SHORT_FORMAT".localized(),
                        NumberFormatter.localizedString(
                            from: NSNumber(integerLiteral: hours),
                            number: .none
                        )
                    ) + " " + String(
                        format: "TIME_AMOUNT_MINUTES_SHORT_FORMAT".localized(),
                        NumberFormatter.localizedString(
                            from: NSNumber(integerLiteral: minutes),
                            number: .none
                        )
                    )
                }
            
                guard minutes == 0 else {
                    return String(
                        format: "TIME_AMOUNT_MINUTES_SHORT_FORMAT".localized(),
                        NumberFormatter.localizedString(
                            from: NSNumber(integerLiteral: minutes),
                            number: .none
                        )
                    ) + " " + String(
                        format: "TIME_AMOUNT_SECONDS_SHORT_FORMAT".localized(),
                        NumberFormatter.localizedString(
                            from: NSNumber(integerLiteral: seconds),
                            number: .none
                        )
                    )
                }
            
                return String(
                    format: "TIME_AMOUNT_SECONDS_SHORT_FORMAT".localized(), 
                    NumberFormatter.localizedString(
                        from: NSNumber(integerLiteral: seconds),
                        number: .none
                    )
                )
            }
    }
}

// MARK: - Unicode Handling

private extension CharacterSet {
    static let bidiLeftToRightIsolate: String.UTF16View.Element = 0x2066
    static let bidiRightToLeftIsolate: String.UTF16View.Element = 0x2067
    static let bidiFirstStrongIsolate: String.UTF16View.Element = 0x2068
    static let bidiLeftToRightEmbedding: String.UTF16View.Element = 0x202A
    static let bidiRightToLeftEmbedding: String.UTF16View.Element = 0x202B
    static let bidiLeftToRightOverride: String.UTF16View.Element = 0x202D
    static let bidiRightToLeftOverride: String.UTF16View.Element = 0x202E
    static let bidiPopDirectionalFormatting: String.UTF16View.Element = 0x202C
    static let bidiPopDirectionalIsolate: String.UTF16View.Element = 0x2069
    
    static let bidiControlCharacterSet: CharacterSet = {
        return CharacterSet(charactersIn: "\(bidiLeftToRightIsolate)\(bidiRightToLeftIsolate)\(bidiFirstStrongIsolate)\(bidiLeftToRightEmbedding)\(bidiRightToLeftEmbedding)\(bidiLeftToRightOverride)\(bidiRightToLeftOverride)\(bidiPopDirectionalFormatting)\(bidiPopDirectionalIsolate)")
    }()
    
    static let unsafeFilenameCharacterSet: CharacterSet = CharacterSet(charactersIn: "\u{202D}\u{202E}")

    static let nonPrintingCharacterSet: CharacterSet = {
        var result: CharacterSet = .whitespacesAndNewlines
        result.formUnion(.controlCharacters)
        result.formUnion(bidiControlCharacterSet)
        // Left-to-right and Right-to-left marks.
        result.formUnion(CharacterSet(charactersIn: "\u{200E}\u{200f}"))
        return result;
    }()
}

public extension String {
    var filteredForDisplay: String {
        self.stripped
            .filterForExcessiveDiacriticals
            .ensureBalancedBidiControlCharacters
    }
    
    var filteredFilename: String {
        self.stripped
            .filterForExcessiveDiacriticals
            .filterUnsafeFilenameCharacters
    }
    
    var stripped: String {
        // If string has no printing characters, consider it empty
        guard self.trimmingCharacters(in: .nonPrintingCharacterSet).count > 0 else {
            return ""
        }
        
        return self.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var hasExcessiveDiacriticals: Bool {
        for char in self.enumerated() {
            let scalarCount = String(char.element).unicodeScalars.count
            if scalarCount > 8 {
                return true
            }
        }

        return false
    }
    
    private var filterForExcessiveDiacriticals: String {
        guard hasExcessiveDiacriticals else { return self }
        
        return self.folding(options: .diacriticInsensitive, locale: .current)
    }
    
    private var ensureBalancedBidiControlCharacters: String {
        var isolateStartsCount: Int = 0
        var isolatePopCount: Int = 0
        var formattingStartsCount: Int = 0
        var formattingPopCount: Int = 0

        self.utf16.forEach { char in
            switch char {
                case CharacterSet.bidiLeftToRightIsolate, CharacterSet.bidiRightToLeftIsolate,
                    CharacterSet.bidiFirstStrongIsolate:
                    isolateStartsCount += 1
                    
                case CharacterSet.bidiPopDirectionalIsolate: isolatePopCount += 1

                case CharacterSet.bidiLeftToRightEmbedding, CharacterSet.bidiRightToLeftEmbedding,
                    CharacterSet.bidiLeftToRightOverride, CharacterSet.bidiRightToLeftOverride:
                    formattingStartsCount += 1
                
                case CharacterSet.bidiPopDirectionalFormatting: formattingPopCount += 1
                
                default: break
            }
        }
        
        var balancedString: String = ""
        
        // If we have too many isolate pops, prepend FSI to balance
        while isolatePopCount > isolateStartsCount {
            balancedString.append("\(CharacterSet.bidiFirstStrongIsolate)")
            isolateStartsCount += 1
        }
        
        // If we have too many formatting pops, prepend LRE to balance
        while formattingPopCount > formattingStartsCount {
            balancedString.append("\(CharacterSet.bidiLeftToRightEmbedding)")
            formattingStartsCount += 1
        }
        
        balancedString.append(self)
        
        // If we have too many formatting starts, append PDF to balance
        while formattingStartsCount > formattingPopCount {
            balancedString.append("\(CharacterSet.bidiPopDirectionalFormatting)")
            formattingPopCount += 1
        }
        
        // If we have too many isolate starts, append PDI to balance
        while isolateStartsCount > isolatePopCount {
            balancedString.append("\(CharacterSet.bidiPopDirectionalIsolate)")
            isolatePopCount += 1
        }
        
        return balancedString
    }
    
    private var filterUnsafeFilenameCharacters: String {
        let unsafeCharacterSet: CharacterSet = CharacterSet.unsafeFilenameCharacterSet
        
        guard self.rangeOfCharacter(from: unsafeCharacterSet) != nil else { return self }
        
        var filtered = ""
        var remainder = self
        
        while let range = remainder.rangeOfCharacter(from: unsafeCharacterSet) {
            if range.lowerBound != remainder.startIndex {
                filtered += remainder[..<range.lowerBound]
            }
            // The "replacement" code point.
            filtered += "\u{FFFD}"
            remainder = String(remainder[range.upperBound...])
        }
        filtered += remainder
        return filtered
    }
}
