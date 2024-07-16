// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension Network {
    enum Destination: Equatable {
        public struct ServerInfo: Equatable {
            public let method: HTTPMethod
            public let url: URL
            public let pathAndParamsString: String
            public let headers: [HTTPHeader: String]?
            public let x25519PublicKey: String
            
            public init(
                method: HTTPMethod,
                url: URL,
                pathAndParamsString: String,
                headers: [HTTPHeader: String]?,
                x25519PublicKey: String
            ) {
                self.method = method
                self.url = url
                self.pathAndParamsString = pathAndParamsString
                self.headers = headers
                self.x25519PublicKey = x25519PublicKey
            }
        }
        
        case snode(LibSession.Snode, swarmPublicKey: String?)
        case randomSnode(swarmPublicKey: String, snodeRetrievalRetryCount: Int)
        case randomSnodeLatestNetworkTimeTarget(
            swarmPublicKey: String,
            snodeRetrievalRetryCount: Int,
            bodyWithUpdatedTimestampMs: ((UInt64, Dependencies) -> Encodable?)
        )
        case server(info: ServerInfo)
        case serverUpload(info: ServerInfo, fileName: String?)
        case serverDownload(info: ServerInfo)
        case cached(success: Bool, timeout: Bool, statusCode: Int, data: Data?)
        
        // MARK: - Convenience
        
        public var urlPathAndParamsString: String {
            switch self {
                case .server(let info), .serverUpload(let info, _), .serverDownload(let info): return info.pathAndParamsString
                default: return ""
            }
        }
        
        public static func server<E: EndpointType>(
            method: HTTPMethod = .get,
            server: String,
            endpoint: E,
            queryParameters: [HTTPQueryParam: String] = [:],
            headers: [HTTPHeader: String]? = nil,
            x25519PublicKey: String
        ) throws -> Destination {
            let pathAndParamsString: String = [
                "/\(endpoint.path)",
                queryParameters
                    .map { key, value in "\(key)=\(value)" }
                    .joined(separator: "&")
            ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "?")
            
            return .server(info: ServerInfo(
                method: method,
                url: try (URL(string: "\(server)\(pathAndParamsString)") ?? { throw NetworkError.invalidURL }()),
                pathAndParamsString: pathAndParamsString,
                headers: headers,
                x25519PublicKey: x25519PublicKey
            ))
        }
        
        public static func serverUpload<E: EndpointType>(
            server: String,
            endpoint: E,
            queryParameters: [HTTPQueryParam: String] = [:],
            headers: [HTTPHeader: String]? = nil,
            x25519PublicKey: String,
            fileName: String?
        ) throws -> Destination {
            let pathAndParamsString: String = [
                "/\(endpoint.path)",
                queryParameters
                    .map { key, value in "\(key)=\(value)" }
                    .joined(separator: "&")
            ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "?")
            
            return .serverUpload(
                info: ServerInfo(
                    method: .post,
                    url: try (URL(string: "\(server)\(pathAndParamsString)") ?? { throw NetworkError.invalidURL }()),
                    pathAndParamsString: pathAndParamsString,
                    headers: headers,
                    x25519PublicKey: x25519PublicKey
                ),
                fileName: fileName
            )
        }
        
        public static func serverDownload(
            url: URL,
            queryParameters: [HTTPQueryParam: String] = [:],
            headers: [HTTPHeader: String]? = nil,
            x25519PublicKey: String,
            fileName: String?
        ) throws -> Destination {
            return .serverDownload(info: ServerInfo(
                method: .get,
                url: url,
                pathAndParamsString: url.path,
                headers: headers,
                x25519PublicKey: x25519PublicKey
            ))
        }
        
        public static func cached<T: Codable>(
            success: Bool = true,
            timeout: Bool = false,
            statusCode: Int = 200,
            response: T?,
            using dependencies: Dependencies
        ) throws -> Destination {
            switch response {
                case .none: return .cached(success: success, timeout: timeout, statusCode: statusCode, data: nil)
                case .some(let response):
                    guard let data: Data = try? JSONEncoder(using: dependencies).encode(response) else {
                        throw NetworkError.invalidPreparedRequest
                    }
                    
                    return .cached(success: success, timeout: timeout, statusCode: statusCode, data: data)
            }
        }
        
        // MARK: - Equatable
        
        public static func == (lhs: Destination, rhs: Destination) -> Bool {
            switch (lhs, rhs) {
                case (.snode(let lhsSnode, let lhsSwarmPublicKey), .snode(let rhsSnode, let rhsSwarmPublicKey)):
                    return (
                        lhsSnode == rhsSnode &&
                        lhsSwarmPublicKey == rhsSwarmPublicKey
                    )
                
                case (.randomSnode(let lhsSwarmPublicKey, let lhsRetryCount), .randomSnode(let rhsSwarmPublicKey, let rhsRetryCount)):
                    return (
                        lhsSwarmPublicKey == rhsSwarmPublicKey &&
                        lhsRetryCount == rhsRetryCount
                    )
                
                case (.randomSnodeLatestNetworkTimeTarget(let lhsSwarmPublicKey, let lhsRetryCount, _), .randomSnodeLatestNetworkTimeTarget(let rhsSwarmPublicKey, let rhsRetryCount, _)):
                    return (
                        lhsSwarmPublicKey == rhsSwarmPublicKey &&
                        lhsRetryCount == rhsRetryCount
                    )
                    
                case (.server(let lhsInfo), .server(let rhsInfo)): return (lhsInfo == rhsInfo)
                
                case (.serverUpload(let lhsInfo, let lhsFileName), .serverUpload(let rhsInfo, let rhsFileName)):
                    return (
                        lhsInfo == rhsInfo &&
                        lhsFileName == rhsFileName
                    )
                    
                case (.serverDownload(let lhsInfo), .serverDownload(let rhsInfo)): return (lhsInfo == rhsInfo)
                    
                case (.cached(let lhsSuccess, let lhsTimeout, let lhsStatusCode, let lhsData), .cached(let rhsSuccess, let rhsTimeout, let rhsStatusCode, let rhsData)):
                    return (
                        lhsSuccess == rhsSuccess &&
                        lhsTimeout == rhsTimeout &&
                        lhsStatusCode == rhsStatusCode &&
                        lhsData == rhsData
                    )
                
                default: return false
            }
        }
    }
}
