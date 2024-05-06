// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public enum OnionRequestAPIError: Error, CustomStringConvertible {
    case httpRequestFailedAtDestination(statusCode: UInt, data: Data, destination: OnionRequestAPIDestination)
    case insufficientSnodes
    case invalidURL
    case missingSnodeVersion
    case snodePublicKeySetMissing
    case unsupportedSnodeVersion(String)
    case invalidRequestInfo
    case pathEncryptionFailed

    public var description: String {
        switch self {
            case .httpRequestFailedAtDestination(let statusCode, let data, let destination):
                if statusCode == 429 { return "Rate limited (OnionRequestAPIError.httpRequestFailedAtDestination)." }
                if let processedResponseBodyData: Data = OnionRequestAPI.process(bencodedData: data)?.body, let errorResponse: String = String(data: processedResponseBodyData, encoding: .utf8) {
                    return "HTTP request failed at destination (\(destination)) with status code: \(statusCode), error body: \(errorResponse) (OnionRequestAPIError.httpRequestFailedAtDestination)."
                }
                if let errorResponse: String = String(data: data, encoding: .utf8) {
                    return "HTTP request failed at destination (\(destination)) with status code: \(statusCode), error body: \(errorResponse) (OnionRequestAPIError.httpRequestFailedAtDestination)."
                }
                
                return "HTTP request failed at destination (\(destination)) with status code: \(statusCode) (OnionRequestAPIError.httpRequestFailedAtDestination)."
            
            case .insufficientSnodes: return "Couldn't find enough Service Nodes to build a path (OnionRequestAPIError.insufficientSnodes)."
            case .invalidURL: return "Invalid URL (OnionRequestAPIError.invalidURL)."
            case .missingSnodeVersion: return "Missing Service Node version (OnionRequestAPIError.missingSnodeVersion)."
            case .snodePublicKeySetMissing: return "Missing Service Node public key set (OnionRequestAPIError.snodePublicKeySetMissing)."
            case .unsupportedSnodeVersion(let version): return "Unsupported Service Node version: \(version) (OnionRequestAPIError.unsupportedSnodeVersion)."
            case .invalidRequestInfo: return "Invalid Request Info (OnionRequestAPIError.invalidRequestInfo)."
            case .pathEncryptionFailed: return "Path Encryption Failed (OnionRequestAPIError.pathEncryptionFailed)."
        }
    }
}
