// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

/// **Note:** The below code **MUST** match the equivalent in `SessionUtilitiesKit.Data+Utilities`
internal extension Data {
    var suiKitGuessedImageFormat: SUIKImageFormat {
        let twoBytesLength: Int = 2
        
        guard count > twoBytesLength else { return .unknown }
        
        var bytes: [UInt8] = [UInt8](repeating: 0, count: twoBytesLength)
        self.copyBytes(to: &bytes, from: (self.startIndex..<self.startIndex.advanced(by: twoBytesLength)))
        
        switch (bytes[0], bytes[1]) {
            case (0x47, 0x49): return .gif
            case (0x89, 0x50): return .png
            case (0xff, 0xd8): return .jpeg
            case (0x42, 0x4d): return .bmp
            case (0x4D, 0x4D): return .tiff // Motorola byte order TIFF
            case (0x49, 0x49): return .tiff // Intel byte order TIFF
            case (0x52, 0x49): return .webp // First two letters of WebP
                
            default: return .unknown
        }
    }
}
