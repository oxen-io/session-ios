// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum HTTPError: LocalizedError, Equatable {
    case generic
    case invalidURL
    case invalidJSON
    case parsingFailed
    case invalidPreparedRequest
    case invalidRequest
    case invalidResponse
    case maxFileSizeExceeded
    case httpRequestFailed(statusCode: UInt, data: Data?)
    case timeout
    case cancelled
    case networkWrappersNotReady
    
    public var errorDescription: String? {
        switch self {
            case .generic: return "An error occurred."
            case .invalidURL: return "Invalid URL."
            case .invalidJSON: return "Invalid JSON."
            case .invalidPreparedRequest: return "Invalid PreparedRequest provided."
            case .invalidRequest: return "Invalid request."
            case .parsingFailed, .invalidResponse: return "Invalid response."
            case .maxFileSizeExceeded: return "Maximum file size exceeded."
            case .httpRequestFailed(let statusCode, _): return "HTTP request failed with status code: \(statusCode)."
            case .timeout: return "The request timed out."
            case .cancelled: return "The request was cancelled."
            case .networkWrappersNotReady: return "The network wrapper was not ready."
        }
    }
}
