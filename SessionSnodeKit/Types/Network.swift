// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let network: SingletonConfig<NetworkType> = Dependencies.create(
        identifier: "network",
        createInstance: { dependencies in LibSessionNetwork(using: dependencies) }
    )
}

// MARK: - NetworkType

public protocol NetworkType {
    func getSwarm(for swarmPublicKey: String) -> AnyPublisher<Set<LibSession.Snode>, Error>
    func getRandomNodes(count: Int) -> AnyPublisher<Set<LibSession.Snode>, Error>
    
    func send(
        _ body: Data?,
        to destination: Network.Destination,
        timeout: TimeInterval
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error>
    
    func checkClientVersion(ed25519SecretKey: [UInt8]) -> AnyPublisher<(ResponseInfoType, AppVersionResponse), Error>
}

// MARK: - Network Constants

public class Network {
    public static let defaultTimeout: TimeInterval = 10
    public static let fileUploadTimeout: TimeInterval = 60
    public static let fileDownloadTimeout: TimeInterval = 30
    
    /// **Note:** The max file size is 10,000,000 bytes (rather than 10MiB which would be `(10 * 1024 * 1024)`), 10,000,000
    /// exactly will be fine but a single byte more will result in an error
    public static let maxFileSize: UInt = 10_000_000
}

// MARK: - NetworkStatus

public enum NetworkStatus {
    case unknown
    case connecting
    case connected
    case disconnected
}

// MARK: - FileServer Convenience

public extension Network {
    enum FileServer {
        fileprivate static let fileServer = "http://filev2.getsession.org"
        fileprivate static let fileServerPublicKey = "da21e1d886c6fbaea313f75298bd64aab03a97ce985b46bb2dad9f2089c8ee59"
        fileprivate static let legacyFileServer = "http://88.99.175.227"
        fileprivate static let legacyFileServerPublicKey = "7cb31905b55cd5580c686911debf672577b3fb0bff81df4ce2d5c4cb3a7aaa69"
        
        public enum Endpoint: EndpointType {
            case file
            case fileIndividual(String)
            case directUrl(URL)
            case sessionVersion
            
            public static var name: String { "FileServerAPI.Endpoint" }
            
            public var path: String {
                switch self {
                    case .file: return "file"
                    case .fileIndividual(let fileId): return "file/\(fileId)"
                    case .directUrl(let url): return url.path
                    case .sessionVersion: return "session_version"
                }
            }
        }
        
        public static func downloadUrlString(for url: String, fileId: String) -> String {
            switch url.contains(legacyFileServer) {
                case true: return "\(fileServer)/\(Endpoint.fileIndividual(fileId).path)"
                default: return downloadUrlString(for: fileId)
            }
        }
        
        public static func downloadUrlString(for fileId: String) -> String {
            return "\(fileServer)/\(Endpoint.fileIndividual(fileId).path)"
        }
    }
    
    static func preparedUpload(
        data: Data,
        using dependencies: Dependencies
    ) throws -> PreparedRequest<FileUploadResponse> {
        return try PreparedRequest(
            request: Request(
                endpoint: FileServer.Endpoint.file,
                destination: .serverUpload(
                    server: FileServer.fileServer,
                    endpoint: FileServer.Endpoint.file,
                    x25519PublicKey: FileServer.fileServerPublicKey,
                    fileName: nil
                ),
                body: data
            ),
            responseType: FileUploadResponse.self,
            timeout: Network.fileUploadTimeout,
            using: dependencies
        )
    }
    
    static func preparedDownload(
        url: URL,
        using dependencies: Dependencies
    ) throws -> PreparedRequest<Data> {
        return try PreparedRequest(
            request: Request<NoBody, FileServer.Endpoint>(
                endpoint: FileServer.Endpoint.directUrl(url),
                destination: .serverDownload(
                    url: url,
                    x25519PublicKey: FileServer.fileServerPublicKey,
                    fileName: nil
                )
            ),
            responseType: Data.self,
            timeout: Network.fileUploadTimeout,
            using: dependencies
        )
    }
}
