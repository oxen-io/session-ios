// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension Network {
    enum Destination: Equatable {
        public struct ServerInfo: Equatable {
            private static let invalidServer: String = "INVALID_SERVER"
            private static let invalidUrl: URL = URL(fileURLWithPath: "INVALID_URL")
            
            private let server: String
            private let queryParameters: [HTTPQueryParam: String]
            private let _url: URL
            private let _pathAndParamsString: String
            
            public let method: HTTPMethod
            public let headers: [HTTPHeader: String]
            public let x25519PublicKey: String
            
            public var url: URL {
                get throws {
                    guard _url != ServerInfo.invalidUrl else { throw NetworkError.invalidURL }
                    
                    return _url
                }
            }
            public var pathAndParamsString: String {
                get throws {
                    guard _url != ServerInfo.invalidUrl else { throw NetworkError.invalidPreparedRequest }
                    
                    return _pathAndParamsString
                }
            }
            
            public init(
                method: HTTPMethod,
                server: String,
                queryParameters: [HTTPQueryParam: String],
                headers: [HTTPHeader: String],
                x25519PublicKey: String
            ) {
                self._url = ServerInfo.invalidUrl
                self._pathAndParamsString = ""
                
                self.method = method
                self.server = server
                self.queryParameters = queryParameters
                self.headers = headers
                self.x25519PublicKey = x25519PublicKey
            }
            
            fileprivate init(
                method: HTTPMethod,
                url: URL,
                server: String?,
                pathAndParamsString: String?,
                queryParameters: [HTTPQueryParam: String] = [:],
                headers: [HTTPHeader: String],
                x25519PublicKey: String
            ) {
                self._url = url
                self._pathAndParamsString = (pathAndParamsString ?? url.path)
                
                self.method = method
                self.server = {
                    if let explicitServer: String = server { return explicitServer }
                    if let urlHost: String = url.host {
                        return "\(url.scheme.map { "\($0)://" } ?? "")\(urlHost)"
                    }
                    
                    return ServerInfo.invalidServer
                }()
                self.queryParameters = queryParameters
                self.headers = headers
                self.x25519PublicKey = x25519PublicKey
            }
            
            fileprivate func updated<E: EndpointType>(for endpoint: E) throws -> ServerInfo {
                let pathAndParamsString: String = generatePathsAndParams(endpoint: endpoint, queryParameters: queryParameters)
                
                return ServerInfo(
                    method: method,
                    url: try (URL(string: "\(server)\(pathAndParamsString)") ?? { throw NetworkError.invalidURL }()),
                    server: server,
                    pathAndParamsString: pathAndParamsString,
                    queryParameters: queryParameters,
                    headers: headers,
                    x25519PublicKey: x25519PublicKey
                )
            }
            
            public func updated(with headers: [HTTPHeader: String]) -> ServerInfo {
                return ServerInfo(
                    method: method,
                    url: _url,
                    server: server,
                    pathAndParamsString: _pathAndParamsString,
                    queryParameters: queryParameters,
                    headers: self.headers.updated(with: headers),
                    x25519PublicKey: x25519PublicKey
                )
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
        case cached(success: Bool, timeout: Bool, statusCode: Int, headers: [HTTPHeader: String], data: Data?)
        
        // MARK: - Convenience
        
        public var method: HTTPMethod {
            switch self {
                case .server(let info), .serverUpload(let info, _), .serverDownload(let info): return info.method
                default: return .post   // Always POST for snode destinations
            }
        }
        
        public var url: URL? {
            switch self {
                case .server(let info), .serverUpload(let info, _), .serverDownload(let info): return try? info.url
                case .snode, .randomSnode, .randomSnodeLatestNetworkTimeTarget: return nil
                case .cached: return nil
            }
        }
        
        public var headers: [HTTPHeader: String] {
            switch self {
                case .server(let info), .serverUpload(let info, _), .serverDownload(let info):
                    return info.headers
                    
                case .snode, .randomSnode, .randomSnodeLatestNetworkTimeTarget: return [:]
                case .cached(_, _, _, let headers, _): return headers
            }
        }
        
        public var urlPathAndParamsString: String {
            switch self {
                case .server(let info), .serverUpload(let info, _), .serverDownload(let info):
                    return ((try? info.pathAndParamsString) ?? "")
                default: return ""
            }
        }
        
        public static func server(
            method: HTTPMethod = .get,
            server: String,
            queryParameters: [HTTPQueryParam: String] = [:],
            headers: [HTTPHeader: String] = [:],
            x25519PublicKey: String
        ) throws -> Destination {
            return .server(info: ServerInfo(
                method: method,
                server: server,
                queryParameters: queryParameters,
                headers: headers,
                x25519PublicKey: x25519PublicKey
            ))
        }
        
        public static func serverUpload(
            server: String,
            queryParameters: [HTTPQueryParam: String] = [:],
            headers: [HTTPHeader: String] = [:],
            x25519PublicKey: String,
            fileName: String?
        ) throws -> Destination {
            return .serverUpload(
                info: ServerInfo(
                    method: .post,
                    server: server,
                    queryParameters: queryParameters,
                    headers: headers,
                    x25519PublicKey: x25519PublicKey
                ),
                fileName: fileName
            )
        }
        
        public static func serverDownload(
            url: URL,
            queryParameters: [HTTPQueryParam: String] = [:],
            headers: [HTTPHeader: String] = [:],
            x25519PublicKey: String,
            fileName: String?
        ) throws -> Destination {
            return .serverDownload(info: ServerInfo(
                method: .get,
                url: url,
                server: nil,
                pathAndParamsString: nil,
                headers: headers,
                x25519PublicKey: x25519PublicKey
            ))
        }
        
        public static func cached<T: Codable>(
            success: Bool = true,
            timeout: Bool = false,
            statusCode: Int = 200,
            headers: [HTTPHeader: String] = [:],
            response: T?,
            using dependencies: Dependencies
        ) throws -> Destination {
            switch response {
                case .none: return .cached(success: success, timeout: timeout, statusCode: statusCode, headers: headers, data: nil)
                case .some(let response):
                    guard let data: Data = try? JSONEncoder(using: dependencies).encode(response) else {
                        throw NetworkError.invalidPreparedRequest
                    }
                    
                    return .cached(success: success, timeout: timeout, statusCode: statusCode, headers: headers, data: data)
            }
        }
        
        // MARK: - Convenience
        
        internal static func generatePathsAndParams<E: EndpointType>(endpoint: E, queryParameters: [HTTPQueryParam: String]) -> String {
            return [
                "/\(endpoint.path)",
                queryParameters
                    .map { key, value in "\(key)=\(value)" }
                    .joined(separator: "&")
            ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "?")
        }
        
        internal func withGeneratedUrl<E: EndpointType>(for endpoint: E) throws -> Destination {
            switch self {
                case .server(let info): return .server(info: try info.updated(for: endpoint))
                case .serverUpload(let info, let fileName):
                    return .serverUpload(info: try info.updated(for: endpoint), fileName: fileName)
                case .serverDownload(let info): return .serverDownload(info: try info.updated(for: endpoint))
                    
                default: return self
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
                    
                case (.cached(let lhsSuccess, let lhsTimeout, let lhsStatusCode, let lhsHeaders, let lhsData), .cached(let rhsSuccess, let rhsTimeout, let rhsStatusCode, let rhsHeaders, let rhsData)):
                    return (
                        lhsSuccess == rhsSuccess &&
                        lhsTimeout == rhsTimeout &&
                        lhsStatusCode == rhsStatusCode &&
                        lhsHeaders == rhsHeaders &&
                        lhsData == rhsData
                    )
                
                default: return false
            }
        }
    }
}
