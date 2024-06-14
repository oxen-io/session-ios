// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SignalCoreKit

public extension String {
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
        guard let text = text?.filterStringForDisplay() else { return nil }

        // iOS strips anything that looks like a printf formatting character from
        // the notification body, so if we want to dispay a literal "%" in a notification
        // it must be escaped.
        // see https://developer.apple.com/documentation/uikit/uilocalnotification/1616646-alertbody
        // for more details.
        return text.replacingOccurrences(of: "%", with: "%%")
    }
}

// MARK: - Formatting

public extension String.StringInterpolation {
    mutating func appendInterpolation(plural value: Int) {
        appendInterpolation(value == 1 ? "" : "s") // stringlint:disable
    }
    
    public mutating func appendInterpolation(period value: String) {
        appendInterpolation(value.hasSuffix(".") ? "" : ".") // stringlint:disable
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
        var dateComponentsFormatter = DateComponentsFormatter()
        dateComponentsFormatter.allowedUnits = [.weekOfMonth, .day, .hour, .minute, .second]
        var calendar = Calendar.current
        
        switch format {
            case .videoDuration:
                guard duration < 3600 else { fallthrough }
                dateComponentsFormatter.maximumUnitCount = 2
                dateComponentsFormatter.unitsStyle = .positional
                dateComponentsFormatter.zeroFormattingBehavior = .pad
                return dateComponentsFormatter.string(from: duration) ?? ""
            
            case .hoursMinutesSeconds:
                dateComponentsFormatter.maximumUnitCount = 3
                dateComponentsFormatter.unitsStyle = .positional
                dateComponentsFormatter.zeroFormattingBehavior = .dropLeading
                return dateComponentsFormatter.string(from: duration) ?? ""
                
            case .short: // Single unit, no localization, short version e.g. 1w
                dateComponentsFormatter.maximumUnitCount = 1
                dateComponentsFormatter.unitsStyle = .abbreviated
                calendar.locale = Locale(identifier: "en-US")
                dateComponentsFormatter.calendar = calendar
                return dateComponentsFormatter.string(from: duration) ?? ""
                
            case .long: // Single unit, long version e.g. 1 week
                dateComponentsFormatter.maximumUnitCount = 1
                dateComponentsFormatter.unitsStyle = .full
                return dateComponentsFormatter.string(from: duration) ?? ""
            
            case .twoUnits: // 2 units, no localization, short version e.g 1w 1d
                dateComponentsFormatter.maximumUnitCount = 2
                dateComponentsFormatter.unitsStyle = .abbreviated
                dateComponentsFormatter.zeroFormattingBehavior = .dropLeading
                calendar.locale = Locale(identifier: "en-US")
                dateComponentsFormatter.calendar = calendar
                return dateComponentsFormatter.string(from: duration) ?? ""
            }
    }
}
