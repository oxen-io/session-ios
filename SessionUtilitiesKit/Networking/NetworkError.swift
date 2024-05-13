// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum NetworkError: LocalizedError, Equatable {
    case invalidURL
    case invalidPreparedRequest
    case notFound
    case parsingFailed
    case invalidResponse
    case maxFileSizeExceeded
    case unauthorised
    case badRequest(error: String, rawData: Data?)
    case requestFailed(error: String, rawData: Data?)
    case timeout
    case unknown
    
    public var errorDescription: String? {
        switch self {
            case .invalidURL: return "Invalid URL."
            case .invalidPreparedRequest: return "Invalid PreparedRequest provided."
            case .notFound: return "Not Found."
            case .parsingFailed, .invalidResponse: return "Invalid response."
            case .maxFileSizeExceeded: return "Maximum file size exceeded."
            case .unauthorised: return "Unauthorised (Failed to verify the signature)."
            case .badRequest(let error, _), .requestFailed(let error, _): return error
            case .timeout: return "The request timed out."
            case .unknown: return "An unknown error occurred."
        }
    }
}
