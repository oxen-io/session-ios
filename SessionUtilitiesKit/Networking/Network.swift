// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine

public protocol NetworkType {
    func send<T>(_ request: Network.RequestType<T>, using dependencies: Dependencies) -> AnyPublisher<(ResponseInfoType, T), Error>
}

public class Network: NetworkType {
    public static let defaultTimeout: TimeInterval = 10
    public static let fileUploadTimeout: TimeInterval = 60
    public static let fileDownloadTimeout: TimeInterval = 30
    
    /// **Note:** The max file size is 10,000,000 bytes (rather than 10MiB which would be `(10 * 1024 * 1024)`), 10,000,000
    /// exactly will be fine but a single byte more will result in an error
    public static let maxFileSize = 10_000_000
}

// MARK: - RequestType

public extension Network {
    struct RequestType<T> {
        public let id: String
        public let url: String?
        public let method: String?
        public let headers: [String: String]?
        public let body: Data?
        public let args: [Any?]
        public let generatePublisher: (Dependencies) -> AnyPublisher<(ResponseInfoType, T), Error>
        
        public init(
            id: String,
            url: String? = nil,
            method: String? = nil,
            headers: [String: String]? = nil,
            body: Data? = nil,
            args: [Any?] = [],
            generatePublisher: @escaping (Dependencies) -> AnyPublisher<(ResponseInfoType, T), Error>
        ) {
            self.id = id
            self.url = url
            self.method = method
            self.headers = headers
            self.body = body
            self.args = args
            self.generatePublisher = generatePublisher
        }
    }
    
    func send<T>(_ request: RequestType<T>, using dependencies: Dependencies) -> AnyPublisher<(ResponseInfoType, T), Error> {
        return request.generatePublisher(dependencies)
    }
}

// MARK: - FileServer Convenience

public extension Network {
    private static let fileServer = "http://filev2.getsession.org"
    private static let fileServerPublicKey = "da21e1d886c6fbaea313f75298bd64aab03a97ce985b46bb2dad9f2089c8ee59"
    private static let legacyFileServer = "http://88.99.175.227"
    private static let legacyFileServerPublicKey = "7cb31905b55cd5580c686911debf672577b3fb0bff81df4ce2d5c4cb3a7aaa69"
    
    private enum Endpoint: EndpointType {
        case file
        case fileIndividual(String)
        case sessionVersion
        
        public static var name: String { "FileServerAPI.Endpoint" }
        
        public var path: String {
            switch self {
                case .file: return "file"
                case .fileIndividual(let fileId): return "file/\(fileId)"
                case .sessionVersion: return "session_version"
            }
        }
    }
    
    static func fileServerPubkey(url: String? = nil) -> String {
        switch url?.contains(legacyFileServer) {
            case true: return legacyFileServerPublicKey
            default: return fileServerPublicKey
        }
    }
    
    static func isFileServerUrl(url: URL) -> Bool {
        return (
            url.absoluteString.starts(with: fileServer) ||
            url.absoluteString.starts(with: legacyFileServer)
        )
    }
    
    static func fileServerUploadUrl() throws -> URL {
        return (
            try URL(string: "\(fileServer)/\(Endpoint.file.path)") ??
            { throw NetworkError.invalidURL }()
        )
    }
    
    static func fileServerDownloadUrlFor(fileId: String) throws -> URL {
        return (
            try URL(string: "\(fileServer)/\(Endpoint.fileIndividual(fileId).path)") ??
            { throw NetworkError.invalidURL }()
        )
    }
    
//case file
//case fileIndividual(fileId: String)
//case sessionVersion
//
//public static var name: String { "FileServerAPI.Endpoint" }
//
//public var path: String {
//    switch self {
//        case .file: return "file"
//        case .fileIndividual(let fileId): return "file/\(fileId)"
//        case .sessionVersion: return "session_version"
//    }
//}
}
