// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum Format {
    private static let fileSizeFormatter: NumberFormatter = {
        let result: NumberFormatter = NumberFormatter()
        result.numberStyle = .decimal
        result.minimumFractionDigits = 0
        result.maximumFractionDigits = 1
        
        return result
    }()
    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        formatter.allowedUnits = [.minute, .second ]
        formatter.zeroFormattingBehavior = [ .pad ]

        return formatter
    }()
    private static let oneKilobyte: Double = 1024;
    private static let oneMegabyte: Double = (oneKilobyte * oneKilobyte)
    
    public static func fileSize(_ fileSize: UInt) -> String {
        let fileSizeDouble: Double = Double(fileSize)
        
        switch fileSizeDouble {
            case oneMegabyte...Double.greatestFiniteMagnitude:
                return (Format.fileSizeFormatter
                    .string(from: NSNumber(floatLiteral: (fileSizeDouble / oneMegabyte)))?
                    .appending("MB") ??     // stringlint:ignore
                    "attachmentsNa".localizedSNUIKit())
            
            default:
                return (Format.fileSizeFormatter
                    .string(from: NSNumber(floatLiteral: max(0.1, (fileSizeDouble / oneKilobyte))))?
                    .appending("KB") ??     // stringlint:ignore
                    "attachmentsNa".localizedSNUIKit())
        }
    }
    
    public static func duration(_ duration: TimeInterval) -> String {
        return (Format.durationFormatter.string(from: duration) ?? "0:00") // stringlint:ignore
    }
}
