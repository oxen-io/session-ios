// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionSnodeKit
import SessionUtilitiesKit

public enum FileServerAPI {
    // MARK: - Settings
    
    public static let oldServer = "http://88.99.175.227"
    public static let oldServerPublicKey = "7cb31905b55cd5580c686911debf672577b3fb0bff81df4ce2d5c4cb3a7aaa69"
    public static let server = "http://filev2.getsession.org"
    public static let serverPublicKey = "da21e1d886c6fbaea313f75298bd64aab03a97ce985b46bb2dad9f2089c8ee59"
    public static let maxFileSize = FileSystem.maxFileSize
    
    /// Standard timeout is 10 seconds which is a little too short for file upload/download with slightly larger files
    public static let fileDownloadTimeout: TimeInterval = 30
    public static let fileUploadTimeout: TimeInterval = 60
    
    // MARK: - File Storage
    
    public static func preparedUpload(
        _ file: Data,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<FileUploadResponse> {
        return try prepareRequest(
            request: Request(
                method: .post,
                server: server,
                endpoint: Endpoint.file,
                headers: [
                    .contentDisposition: "attachment",
                    .contentType: "application/octet-stream"
                ],
                x25519PublicKey: serverPublicKey,
                body: Array(file)
            ),
            responseType: FileUploadResponse.self,
            timeout: FileServerAPI.fileUploadTimeout,
            using: dependencies
        )
    }
    
    public static func preparedDownload(
        fileId: String,
        useOldServer: Bool,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<Data> {
        return try prepareRequest(
            request: Request<NoBody, Endpoint>(
                server: (useOldServer ? oldServer : server),
                endpoint: .fileIndividual(fileId: fileId),
                x25519PublicKey: (useOldServer ? oldServerPublicKey : serverPublicKey)
            ),
            responseType: Data.self,
            timeout: FileServerAPI.fileDownloadTimeout,
            using: dependencies
        )
    }

    public static func preparedGetVersion(
        _ platform: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<String> {
        return try prepareRequest(
            request: Request<NoBody, Endpoint>(
                server: server,
                endpoint: Endpoint.sessionVersion,
                queryParameters: [
                    .platform: platform
                ],
                x25519PublicKey: serverPublicKey
            ),
            responseType: VersionResponse.self,
            timeout: HTTP.defaultTimeout,
            using: dependencies
        )
        .map { _, response in response.version }
    }
    
    // MARK: - Convenience
    
    private static func prepareRequest<T: Encodable, R: Decodable>(
        request: Request<T, Endpoint>,
        responseType: R.Type,
        retryCount: Int = 0,
        timeout: TimeInterval,
        using dependencies: Dependencies
    ) throws -> HTTP.PreparedRequest<R> {
        return HTTP.PreparedRequest<R>(
            request: request,
            urlRequest: try request.generateUrlRequest(using: dependencies),
            responseType: responseType,
            retryCount: retryCount,
            timeout: timeout
        )
    }
}
