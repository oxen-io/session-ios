// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension URLResponse {
    var stringEncoding: String.Encoding? {
        guard let encodingName = textEncodingName else { return nil }
        
        let encoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }
}
