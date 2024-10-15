// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public typealias HTTPHeader = String

public extension HTTPHeader {
    static let authorization: HTTPHeader = "Authorization"
    static let contentType: HTTPHeader = "Content-Type"
    static let contentDisposition: HTTPHeader = "Content-Disposition"
}

// MARK: - Convenience

public extension Dictionary where Key == HTTPHeader, Value == String {
    func toHTTPHeaders() -> [String: String] {
        return self.reduce(into: [:]) { result, next in result[next.key] = next.value }
    }
}
