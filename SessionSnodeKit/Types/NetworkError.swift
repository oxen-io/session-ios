// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum NetworkError: Error, Equatable, CustomStringConvertible {
    case invalidState
    case invalidURL
    case invalidPreparedRequest
    case forbidden
    case notFound
    case parsingFailed
    case invalidResponse
    case maxFileSizeExceeded
    case unauthorised
    case internalServerError
    case badGateway
    case serviceUnavailable
    case gatewayTimeout
    case badRequest(error: String, rawData: Data?)
    case requestFailed(error: String, rawData: Data?)
    case timeout(error: String, rawData: Data?)
    case suspended
    case unknown
    
    public var description: String {
        switch self {
            case .invalidState: return "The network is in an invalid state (NetworkError.invalidState)."
            case .invalidURL: return "Invalid URL (NetworkError.invalidURL)."
            case .invalidPreparedRequest: return "Invalid PreparedRequest provided (NetworkError.invalidPreparedRequest)."
            case .forbidden: return "Forbidden (NetworkError.forbidden)."
            case .notFound: return "Not Found (NetworkError.notFound)."
            case .parsingFailed: return "Invalid response (NetworkError.parsingFailed)."
            case .invalidResponse: return "Invalid response (NetworkError.invalidResponse)."
            case .maxFileSizeExceeded: return "Maximum file size exceeded (NetworkError.maxFileSizeExceeded)."
            case .unauthorised: return "Unauthorised (Failed to verify the signature - NetworkError.unauthorised)."
            case .internalServerError: return "Internal server error (NetworkError.internalServerError)."
            case .badGateway: return "Bad gateway (NetworkError.badGateway)."
            case .serviceUnavailable: return "Service unavailable (NetworkError.serviceUnavailable)."
            case .gatewayTimeout: return "Gateway timeout (NetworkError.gatewayTimeout)."
            case .badRequest(let error, _), .requestFailed(let error, _): return error
            case .timeout(let error, _): return "The request timed out with error: \(error) (NetworkError.timeout)."
            case .suspended: return "Network requests are suspended (NetworkError.suspended)."
            case .unknown: return "An unknown error occurred (NetworkError.unknown)."
        }
    }
}
