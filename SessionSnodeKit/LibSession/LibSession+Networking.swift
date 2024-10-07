// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionUtil
import SessionUtilitiesKit

// MARK: - Cache

public extension Cache {
    static let libSessionNetwork: CacheConfig<LibSession.NetworkCacheType, LibSession.NetworkImmutableCacheType> = Dependencies.create(
        identifier: "libSessionNetwork",
        createInstance: { dependencies in LibSession.NetworkCache(using: dependencies) },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let network: Log.Category = .create("Network", defaultLevel: .info)
}

// MARK: - LibSession.Network

class LibSessionNetwork: NetworkType {
    private let dependencies: Dependencies
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - NetworkType

    func getSwarm(for swarmPublicKey: String) -> AnyPublisher<Set<LibSession.Snode>, Error> {
        typealias Output = Result<Set<LibSession.Snode>, Error>
        
        return dependencies
            .mutate(cache: .libSessionNetwork) { $0.getOrCreateNetwork() }
            .tryMapCallbackWrapper(type: Output.self) { wrapper, network in
                guard let cSwarmPublicKey: [CChar] = swarmPublicKey
                    .suffix(64) // Quick way to drop '05' prefix if present
                    .cString(using: .utf8)
                else { throw LibSessionError.invalidCConversion }
                
                network_get_swarm(network, cSwarmPublicKey, { swarmPtr, swarmSize, ctx in
                    guard
                        swarmSize > 0,
                        let cSwarm: UnsafeMutablePointer<network_service_node> = swarmPtr
                    else { return CallbackWrapper<Output>.run(ctx, .failure(SnodeAPIError.unableToRetrieveSwarm)) }
                    
                    var nodes: Set<LibSession.Snode> = []
                    (0..<swarmSize).forEach { index in nodes.insert(LibSession.Snode(cSwarm[index])) }
                    CallbackWrapper<Output>.run(ctx, .success(nodes))
                }, wrapper.unsafePointer());
            }
            .tryMap { result in try result.successOrThrow() }
            .eraseToAnyPublisher()
    }
    
    func getRandomNodes(count: Int) -> AnyPublisher<Set<LibSession.Snode>, Error> {
        typealias Output = Result<Set<LibSession.Snode>, Error>
        
        return dependencies
            .mutate(cache: .libSessionNetwork) { $0.getOrCreateNetwork() }
            .tryMapCallbackWrapper(type: Output.self) { wrapper, network in
                network_get_random_nodes(network, UInt16(count), { nodesPtr, nodesSize, ctx in
                    guard
                        nodesSize > 0,
                        let cSwarm: UnsafeMutablePointer<network_service_node> = nodesPtr
                    else { return CallbackWrapper<Output>.run(ctx, .failure(SnodeAPIError.unableToRetrieveSwarm)) }
                    
                    var nodes: Set<LibSession.Snode> = []
                    (0..<nodesSize).forEach { index in nodes.insert(LibSession.Snode(cSwarm[index])) }
                    CallbackWrapper<Output>.run(ctx, .success(nodes))
                }, wrapper.unsafePointer());
            }
            .tryMap { result in
                switch result {
                    case .failure(let error): throw error
                    case .success(let nodes):
                        guard nodes.count >= count else { throw SnodeAPIError.unableToRetrieveSwarm }
                        
                        return nodes
                }
            }
            .eraseToAnyPublisher()
    }
    
    func send(
        _ body: Data?,
        to destination: Network.Destination,
        requestTimeout: TimeInterval,
        requestAndPathBuildTimeout: TimeInterval?
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        switch destination {
            case .server, .serverUpload, .serverDownload, .cached:
                return sendRequest(
                    to: destination,
                    body: body,
                    requestTimeout: requestTimeout,
                    requestAndPathBuildTimeout: requestAndPathBuildTimeout
                )
            
            case .snode:
                guard body != nil else { return Fail(error: NetworkError.invalidPreparedRequest).eraseToAnyPublisher() }
                
                return sendRequest(
                    to: destination,
                    body: body,
                    requestTimeout: requestTimeout,
                    requestAndPathBuildTimeout: requestAndPathBuildTimeout
                )
                
            case .randomSnode(let swarmPublicKey, let retryCount):
                guard body != nil else { return Fail(error: NetworkError.invalidPreparedRequest).eraseToAnyPublisher() }
                
                return getSwarm(for: swarmPublicKey)
                    .tryFlatMapWithRandomSnode(retry: retryCount, using: dependencies) { [weak self] snode in
                        try self.validOrThrow().sendRequest(
                            to: .snode(snode, swarmPublicKey: swarmPublicKey),
                            body: body,
                            requestTimeout: requestTimeout,
                            requestAndPathBuildTimeout: requestAndPathBuildTimeout
                        )
                    }
                
            case .randomSnodeLatestNetworkTimeTarget(let swarmPublicKey, let retryCount, let bodyWithUpdatedTimestampMs):
                guard body != nil else { return Fail(error: NetworkError.invalidPreparedRequest).eraseToAnyPublisher() }
                
                return getSwarm(for: swarmPublicKey)
                    .tryFlatMapWithRandomSnode(retry: retryCount, using: dependencies) { [weak self, dependencies] snode in
                        try SnodeAPI
                            .preparedGetNetworkTime(from: snode, using: dependencies)
                            .send(using: dependencies)
                            .tryFlatMap { _, timestampMs in
                                guard
                                    let updatedEncodable: Encodable = bodyWithUpdatedTimestampMs(timestampMs, dependencies),
                                    let updatedBody: Data = try? JSONEncoder(using: dependencies).encode(updatedEncodable)
                                else { throw NetworkError.invalidPreparedRequest }
                                
                                return try self.validOrThrow().sendRequest(
                                        to: .snode(snode, swarmPublicKey: swarmPublicKey),
                                        body: updatedBody,
                                        requestTimeout: requestTimeout,
                                        requestAndPathBuildTimeout: requestAndPathBuildTimeout
                                    )
                                    .map { info, response -> (ResponseInfoType, Data?) in
                                        (
                                            SnodeAPI.LatestTimestampResponseInfo(
                                                code: info.code,
                                                headers: info.headers,
                                                timestampMs: timestampMs
                                            ),
                                            response
                                        )
                                    }
                            }
                    }
        }
    }
    
    func checkClientVersion(ed25519SecretKey: [UInt8]) -> AnyPublisher<(ResponseInfoType, AppVersionResponse), Error> {
        typealias Output = (success: Bool, timeout: Bool, statusCode: Int, headers: [String: String], data: Data?)
        
        return dependencies
            .mutate(cache: .libSessionNetwork) { $0.getOrCreateNetwork() }
            .tryMapCallbackWrapper(type: Output.self) { wrapper, network in
                var cEd25519SecretKey: [UInt8] = Array(ed25519SecretKey)
                
                network_get_client_version(
                    network,
                    CLIENT_PLATFORM_IOS,
                    &cEd25519SecretKey,
                    Int64(floor(Network.defaultTimeout * 1000)),
                    0,
                    { success, timeout, statusCode, cHeaders, cHeaderVals, headerLen, dataPtr, dataLen, ctx in
                        let headers: [String: String] = CallbackWrapper<Output>
                            .headers(cHeaders, cHeaderVals, headerLen)
                        let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                        CallbackWrapper<Output>.run(ctx, (success, timeout, Int(statusCode), headers, data))
                    },
                    wrapper.unsafePointer()
                )
            }
            .tryMap { [dependencies] success, timeout, statusCode, headers, maybeData -> (any ResponseInfoType, AppVersionResponse) in
                try LibSessionNetwork.throwErrorIfNeeded(success, timeout, statusCode, headers, maybeData, using: dependencies)
                
                guard let data: Data = maybeData else { throw NetworkError.parsingFailed }
                
                return (
                    Network.ResponseInfo(code: statusCode),
                    try AppVersionResponse.decoded(from: data, using: dependencies)
                )
            }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Internal Functions
    
    private func sendRequest<T: Encodable>(
        to destination: Network.Destination,
        body: T?,
        requestTimeout: TimeInterval,
        requestAndPathBuildTimeout: TimeInterval?
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        typealias Output = (success: Bool, timeout: Bool, statusCode: Int, headers: [String: String], data: Data?)
        
        return dependencies
            .mutate(cache: .libSessionNetwork) { $0.getOrCreateNetwork() }
            .tryMapCallbackWrapper(type: Output.self) { wrapper, network in
                // Prepare the parameters
                let cPayloadBytes: [UInt8]
                
                switch body {
                    case .none: cPayloadBytes = []
                    case let data as Data: cPayloadBytes = Array(data)
                    case let bytes as [UInt8]: cPayloadBytes = bytes
                    default:
                        guard let encodedBody: Data = try? JSONEncoder().encode(body) else {
                            throw SnodeAPIError.invalidPayload
                        }
                        
                        cPayloadBytes = Array(encodedBody)
                }
                
                // Trigger the request
                switch destination {
                    // These types should be processed and converted to a 'snode' destination before
                    // they get here
                    case .randomSnode, .randomSnodeLatestNetworkTimeTarget:
                        throw NetworkError.invalidPreparedRequest
                    
                    case .snode(let snode, let swarmPublicKey):
                        let cSwarmPublicKey: UnsafePointer<CChar>? = swarmPublicKey.map {
                            // Quick way to drop '05' prefix if present
                            $0.suffix(64).cString(using: .utf8)?.unsafeCopy()
                        }
                        wrapper.addUnsafePointerToCleanup(cSwarmPublicKey)
                        
                        network_send_onion_request_to_snode_destination(
                            network,
                            snode.cSnode,
                            cPayloadBytes,
                            cPayloadBytes.count,
                            cSwarmPublicKey,
                            Int64(floor(requestTimeout * 1000)),
                            Int64(floor((requestAndPathBuildTimeout ?? 0) * 1000)),
                            { success, timeout, statusCode, cHeaders, cHeaderVals, headerLen, dataPtr, dataLen, ctx in
                                let headers: [String: String] = CallbackWrapper<Output>
                                    .headers(cHeaders, cHeaderVals, headerLen)
                                let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                                CallbackWrapper<Output>.run(ctx, (success, timeout, Int(statusCode), headers, data))
                            },
                            wrapper.unsafePointer()
                        )
                    
                    case .server:
                        network_send_onion_request_to_server_destination(
                            network,
                            try wrapper.cServerDestination(destination),
                            cPayloadBytes,
                            cPayloadBytes.count,
                            Int64(floor(requestTimeout * 1000)),
                            Int64(floor((requestAndPathBuildTimeout ?? 0) * 1000)),
                            { success, timeout, statusCode, cHeaders, cHeaderVals, headerLen, dataPtr, dataLen, ctx in
                                let headers: [String: String] = CallbackWrapper<Output>
                                    .headers(cHeaders, cHeaderVals, headerLen)
                                let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                                CallbackWrapper<Output>.run(ctx, (success, timeout, Int(statusCode), headers, data))
                            },
                            wrapper.unsafePointer()
                        )
                    
                    case .serverUpload(_, let fileName):
                        guard !cPayloadBytes.isEmpty else { throw NetworkError.invalidPreparedRequest }
                        
                        network_upload_to_server(
                            network,
                            try wrapper.cServerDestination(destination),
                            cPayloadBytes,
                            cPayloadBytes.count,
                            fileName?.cString(using: .utf8),
                            Int64(floor(requestTimeout * 1000)),
                            Int64(floor((requestAndPathBuildTimeout ?? 0) * 1000)),
                            { success, timeout, statusCode, cHeaders, cHeaderVals, headerLen, dataPtr, dataLen, ctx in
                                let headers: [String: String] = CallbackWrapper<Output>
                                    .headers(cHeaders, cHeaderVals, headerLen)
                                let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                                CallbackWrapper<Output>.run(ctx, (success, timeout, Int(statusCode), headers, data))
                            },
                            wrapper.unsafePointer()
                        )
                    
                    case .serverDownload:
                        network_download_from_server(
                            network,
                            try wrapper.cServerDestination(destination),
                            Int64(floor(requestTimeout * 1000)),
                            Int64(floor((requestAndPathBuildTimeout ?? 0) * 1000)),
                            { success, timeout, statusCode, cHeaders, cHeaderVals, headerLen, dataPtr, dataLen, ctx in
                                let headers: [String: String] = CallbackWrapper<Output>
                                    .headers(cHeaders, cHeaderVals, headerLen)
                                let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                                CallbackWrapper<Output>.run(ctx, (success, timeout, Int(statusCode), headers, data))
                            },
                            wrapper.unsafePointer()
                        )
                    
                    case .cached(let success, let timeout, let statusCode, let headers, let data):
                        wrapper.run((success, timeout, statusCode, headers, data))
                }
            }
            .tryMap { [dependencies] success, timeout, statusCode, headers, data -> (any ResponseInfoType, Data?) in
                try LibSessionNetwork.throwErrorIfNeeded(success, timeout, statusCode, headers, data, using: dependencies)
                return (Network.ResponseInfo(code: statusCode, headers: headers), data)
            }
            .eraseToAnyPublisher()
    }
    
    private static func throwErrorIfNeeded(
        _ success: Bool,
        _ timeout: Bool,
        _ statusCode: Int,
        _ headers: [String: String],
        _ data: Data?,
        using dependencies: Dependencies
    ) throws {
        guard !success || statusCode < 200 || statusCode > 299 else { return }
        guard !timeout else {
            switch data.map({ String(data: $0, encoding: .ascii) }) {
                case .none: throw NetworkError.timeout(error: "\(NetworkError.unknown)", rawData: data)
                case .some(let responseString): throw NetworkError.timeout(error: responseString, rawData: data)
            }
        }
        
        /// Handle status codes with specific meanings
        switch (statusCode, data.map { String(data: $0, encoding: .ascii) }) {
            case (400, .none): throw NetworkError.badRequest(error: "\(NetworkError.unknown)", rawData: data)
            case (400, .some(let responseString)): throw NetworkError.badRequest(error: responseString, rawData: data)
                
            case (401, _):
                Log.warn(.network, "Unauthorised (Failed to verify the signature).")
                throw NetworkError.unauthorised
            
            case (403, _): throw NetworkError.forbidden
            case (404, _): throw NetworkError.notFound
                
            /// A snode will return a `406` but onion requests v4 seems to return `425` so handle both
            case (406, _), (425, _):
                Log.warn(.network, "The user's clock is out of sync with the service node network.")
                throw SnodeAPIError.clockOutOfSync
            
            case (421, _): throw SnodeAPIError.unassociatedPubkey
            case (429, _): throw SnodeAPIError.rateLimited
            case (500, _): throw NetworkError.internalServerError
            case (503, _): throw NetworkError.serviceUnavailable
            case (502, .none): throw NetworkError.badGateway
            case (502, .some(let responseString)):
                guard responseString.count >= 64 && Hex.isValid(String(responseString.suffix(64))) else {
                    throw NetworkError.badGateway
                }
                
                let nodeHex: String = String(responseString.suffix(64))
                
                for path in dependencies[cache: .libSessionNetwork].currentPaths {
                    if let index: Int = path.firstIndex(where: { $0.ed25519PubkeyHex == nodeHex }) {
                        throw SnodeAPIError.nodeNotFound(index, nodeHex)
                    }
                }
                
                throw SnodeAPIError.nodeNotFound(nil, nodeHex)
                
            case (504, _): throw NetworkError.gatewayTimeout
            case (_, .none): throw NetworkError.unknown
            case (_, .some(let responseString)): throw NetworkError.requestFailed(error: responseString, rawData: data)
        }
    }
}

// MARK: - LibSessionNetwork.CallbackWrapper

private extension LibSessionNetwork {
    class CallbackWrapper<Output> {
        public let resultPublisher: CurrentValueSubject<Output?, Error> = CurrentValueSubject(nil)
        private var pointersToDeallocate: [UnsafeRawPointer?] = []
        
        // MARK: - Initialization
        
        deinit {
            pointersToDeallocate.forEach { $0?.deallocate() }
        }
        
        // MARK: - Functions
        
        public static func run(_ ctx: UnsafeMutableRawPointer?, _ output: Output) {
            guard let ctx: UnsafeMutableRawPointer = ctx else {
                return Log.error(.network, "CallbackWrapper called with null context.")
            }
            
            // Dispatch async so we don't block libSession's internals with Swift logic (which can block other requests)
            let wrapper: CallbackWrapper<Output> = Unmanaged<CallbackWrapper<Output>>.fromOpaque(ctx).takeRetainedValue()
            DispatchQueue.global(qos: .default).async { [wrapper] in wrapper.resultPublisher.send(output) }
        }
        
        public func unsafePointer() -> UnsafeMutableRawPointer { Unmanaged.passRetained(self).toOpaque() }
        
        public func addUnsafePointerToCleanup<T>(_ pointer: UnsafePointer<T>?) {
            pointersToDeallocate.append(UnsafeRawPointer(pointer))
        }
        
        public func run(_ output: Output) {
            resultPublisher.send(output)
        }
    }
}

// MARK: - Optional Convenience

private extension Optional where Wrapped == LibSessionNetwork {
    func validOrThrow() throws -> Wrapped {
        switch self {
            case .none: throw NetworkError.invalidState
            case .some(let value): return value
        }
    }
}

// MARK: - NetworkStatus Convenience

private extension NetworkStatus {
    init(status: CONNECTION_STATUS) {
        switch status {
            case CONNECTION_STATUS_CONNECTING: self = .connecting
            case CONNECTION_STATUS_CONNECTED: self = .connected
            case CONNECTION_STATUS_DISCONNECTED: self = .disconnected
            default: self = .unknown
        }
    }
}

// MARK: - Publisher Convenience

fileprivate extension Publisher {
    func tryMapCallbackWrapper<T>(
        maxPublishers: Subscribers.Demand = .unlimited,
        type: T.Type,
        _ transform: @escaping (LibSessionNetwork.CallbackWrapper<T>, Self.Output) throws -> Void
    ) -> AnyPublisher<T, Error> {
        let wrapper: LibSessionNetwork.CallbackWrapper<T> = LibSessionNetwork.CallbackWrapper()
        
        return self
            .tryMap { value -> Void in try transform(wrapper, value) }
            .flatMap { _ in
                wrapper
                    .resultPublisher
                    .compactMap { $0 }
                    .first()
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
}

// MARK: - Snode

extension LibSession {
    public struct Snode: Hashable, CustomStringConvertible {
        public let ip: String
        public let quicPort: UInt16
        public let ed25519PubkeyHex: String
        
        public var address: String { "\(ip):\(quicPort)" }
        public var description: String { address }
        
        public var cSnode: network_service_node {
            var result: network_service_node = network_service_node()
            result.ipString = ip
            result.set(\.quic_port, to: quicPort)
            result.set(\.ed25519_pubkey_hex, to: ed25519PubkeyHex)
            
            return result
        }
        
        init(_ cSnode: network_service_node) {
            ip = cSnode.ipString
            quicPort = cSnode.get(\.quic_port)
            ed25519PubkeyHex = cSnode.get(\.ed25519_pubkey_hex)
        }
        
        internal init(ip: String, quicPort: UInt16, ed25519PubkeyHex: String) {
            self.ip = ip
            self.quicPort = quicPort
            self.ed25519PubkeyHex = ed25519PubkeyHex
        }
        
        public func hash(into hasher: inout Hasher) {
            ip.hash(into: &hasher)
            quicPort.hash(into: &hasher)
            ed25519PubkeyHex.hash(into: &hasher)
        }
        
        public static func == (lhs: Snode, rhs: Snode) -> Bool {
            return (
                lhs.ip == rhs.ip &&
                lhs.quicPort == rhs.quicPort &&
                lhs.ed25519PubkeyHex == rhs.ed25519PubkeyHex
            )
        }
    }
}

// MARK: - Convenience C Access

extension network_service_node: CAccessible, CMutable {
    var ipString: String {
        get { "\(ip.0).\(ip.1).\(ip.2).\(ip.3)" }
        set {
            let ipParts: [UInt8] = newValue
                .components(separatedBy: ".")
                .compactMap { UInt8($0) }
            
            guard ipParts.count == 4 else { return }
            
            self.ip = (ipParts[0], ipParts[1], ipParts[2], ipParts[3])
        }
    }
}

// MARK: - Convenience

private extension LibSessionNetwork.CallbackWrapper {
    static func headers(
        _ cHeaders: UnsafeMutablePointer<UnsafePointer<CChar>?>?,
        _ cHeaderVals: UnsafeMutablePointer<UnsafePointer<CChar>?>?,
        _ count: Int
    ) -> [String: String] {
        let headers: [String] = [String](pointer: cHeaders, count: count, defaultValue: [])
        let headerVals: [String] = [String](pointer: cHeaderVals, count: count, defaultValue: [])
        
        return zip(headers, headerVals)
            .reduce(into: [:]) { result, next in result[next.0] = next.1 }
    }
    
    func cServerDestination(_ destination: Network.Destination) throws -> network_server_destination {
        let method: HTTPMethod
        let url: URL
        let headers: [HTTPHeader: String]?
        let x25519PublicKey: String
        
        switch destination {
            case .snode, .randomSnode, .randomSnodeLatestNetworkTimeTarget, .cached: throw NetworkError.invalidPreparedRequest
            case .server(let info), .serverUpload(let info, _), .serverDownload(let info):
                method = info.method
                url = try info.url
                headers = info.headers
                x25519PublicKey = info.x25519PublicKey
        }
        
        guard let host: String = url.host else { throw NetworkError.invalidURL }
        
        let headerInfo: [(key: String, value: String)]? = headers?.map { ($0.key, $0.value) }
        
        // Handle the more complicated type conversions first
        let cHeaderKeysContent: [UnsafePointer<CChar>?] = (try? ((headerInfo ?? [])
            .map { $0.key.cString(using: .utf8) }
            .unsafeCopyCStringArray()))
            .defaulting(to: [])
        let cHeaderValuesContent: [UnsafePointer<CChar>?] = (try? ((headerInfo ?? [])
            .map { $0.value.cString(using: .utf8) }
            .unsafeCopyCStringArray()))
            .defaulting(to: [])
        
        guard
            cHeaderKeysContent.count == cHeaderValuesContent.count,
            cHeaderKeysContent.allSatisfy({ $0 != nil }),
            cHeaderValuesContent.allSatisfy({ $0 != nil })
        else {
            cHeaderKeysContent.forEach { $0?.deallocate() }
            cHeaderValuesContent.forEach { $0?.deallocate() }
            throw LibSessionError.invalidCConversion
        }
        
        // Convert the other types
        let targetScheme: String = (url.scheme ?? "https")
        let cMethod: UnsafePointer<CChar>? = method.rawValue
            .cString(using: .utf8)?
            .unsafeCopy()
        let cTargetScheme: UnsafePointer<CChar>? = targetScheme
            .cString(using: .utf8)?
            .unsafeCopy()
        let cHost: UnsafePointer<CChar>? = host
            .cString(using: .utf8)?
            .unsafeCopy()
        let cEndpoint: UnsafePointer<CChar>? = url.path
            .appending(url.query.map { value in "?\(value)" })
            .cString(using: .utf8)?
            .unsafeCopy()
        let cX25519Pubkey: UnsafePointer<CChar>? = x25519PublicKey
            .suffix(64) // Quick way to drop '05' prefix if present
            .cString(using: .utf8)?
            .unsafeCopy()
        let cHeaderKeys: UnsafeMutablePointer<UnsafePointer<CChar>?>? = cHeaderKeysContent
            .unsafeCopy()
        let cHeaderValues: UnsafeMutablePointer<UnsafePointer<CChar>?>? = cHeaderValuesContent
            .unsafeCopy()
        let cServerDestination = network_server_destination(
            method: cMethod,
            protocol: cTargetScheme,
            host: cHost,
            endpoint: cEndpoint,
            port: UInt16(url.port ?? (targetScheme == "https" ? 443 : 80)),
            x25519_pubkey: cX25519Pubkey,
            headers: cHeaderKeys,
            header_values: cHeaderValues,
            headers_size: (headerInfo ?? []).count
        )
        
        // Add a cleanup callback to deallocate the header arrays
        self.addUnsafePointerToCleanup(cMethod)
        self.addUnsafePointerToCleanup(cTargetScheme)
        self.addUnsafePointerToCleanup(cHost)
        self.addUnsafePointerToCleanup(cEndpoint)
        self.addUnsafePointerToCleanup(cX25519Pubkey)
        cHeaderKeysContent.forEach { self.addUnsafePointerToCleanup($0) }
        cHeaderValuesContent.forEach { self.addUnsafePointerToCleanup($0) }
        self.addUnsafePointerToCleanup(cHeaderKeys)
        self.addUnsafePointerToCleanup(cHeaderValues)
        
        return cServerDestination
    }
}

// MARK: - LibSession.NetworkCache

public extension LibSession {
    class NetworkCache: NetworkCacheType {
        private static var snodeCachePath: String { "\(FileManager.default.appSharedDataDirectoryPath)/snodeCache" }
        
        private let dependencies: Dependencies
        private let dependenciesPtr: UnsafeMutableRawPointer
        private var network: UnsafeMutablePointer<network_object>? = nil
        private let _paths: CurrentValueSubject<[[Snode]], Never> = CurrentValueSubject([])
        private let _networkStatus: CurrentValueSubject<NetworkStatus, Never> = CurrentValueSubject(.unknown)
        
        public var isSuspended: Bool = false
        public var networkStatus: AnyPublisher<NetworkStatus, Never> { _networkStatus.eraseToAnyPublisher() }
        
        public var paths: AnyPublisher<[[Snode]], Never> { _paths.eraseToAnyPublisher() }
        public var hasPaths: Bool { !_paths.value.isEmpty }
        public var currentPaths: [[Snode]] { _paths.value }
        public var pathsDescription: String { _paths.value.prettifiedDescription }
        
        // MARK: - Initialization
        
        public init(using dependencies: Dependencies) {
            self.dependencies = dependencies
            self.dependenciesPtr = Unmanaged.passRetained(dependencies).toOpaque()
            
            // Create the network object
            getOrCreateNetwork().sinkUntilComplete()
        }
        
        deinit {
            // Send completion events to the observables (so they can resubscribe to a future instance)
            _paths.send(completion: .finished)
            _networkStatus.send(completion: .finished)
            
            // Clear the network changed callbacks (just in case, since we are going to free the
            // dependenciesPtr) and then free the network object
            switch network {
                case .none: break
                case .some(let network):
                    network_set_status_changed_callback(network, nil, nil)
                    network_set_paths_changed_callback(network, nil, nil)
                    network_free(network)
            }
            
            // Finally we need to make sure to clean up the unbalanced retain to the dependencies
            Unmanaged<Dependencies>.fromOpaque(dependenciesPtr).release()
        }
        
        // MARK: - Functions
        
        public func suspendNetworkAccess() {
            Log.info(.network, "Network access suspended.")
            isSuspended = true
            
            switch network {
                case .none: break
                case .some(let network): network_suspend(network)
            }
        }
        
        public func resumeNetworkAccess() {
            isSuspended = false
            Log.info(.network, "Network access resumed.")
            
            switch network {
                case .none: break
                case .some(let network): network_resume(network)
            }
        }
        
        public func getOrCreateNetwork() -> AnyPublisher<UnsafeMutablePointer<network_object>?, Error> {
            guard !isSuspended else {
                Log.warn(.network, "Attempted to access suspended network.")
                return Fail(error: NetworkError.suspended).eraseToAnyPublisher()
            }
            
            switch network {
                case .some(let existingNetwork):
                    return Just(existingNetwork)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                
                case .none:
                    let useTestnet: Bool = (dependencies[feature: .serviceNetwork] == .testnet)
                    let isMainApp: Bool = dependencies[singleton: .appContext].isMainApp
                    var error: [CChar] = [CChar](repeating: 0, count: 256)
                    var network: UnsafeMutablePointer<network_object>?
                    
                    guard let cCachePath: [CChar] = NetworkCache.snodeCachePath.cString(using: .utf8) else {
                        Log.error(.network, "Unable to create network object: \(LibSessionError.invalidCConversion)")
                        return Fail(error: NetworkError.invalidState).eraseToAnyPublisher()
                    }
                    
                    guard network_init(&network, cCachePath, useTestnet, !isMainApp, true, &error) else {
                        Log.error(.network, "Unable to create network object: \(String(cString: error))")
                        return Fail(error: NetworkError.invalidState).eraseToAnyPublisher()
                    }
                    
                    // Store the newly created network
                    self.network = network
                    
                    // Register for network status changes
                    network_set_status_changed_callback(network, { cStatus, ctx in
                        guard let ctx: UnsafeMutableRawPointer = ctx else { return }
                        
                        let status: NetworkStatus = NetworkStatus(status: cStatus)
                        
                        // Dispatch async so we don't hold up the libSession thread that triggered the update
                        // or have a reentrancy issue with the mutable cache
                        DispatchQueue.global(qos: .default).async {
                            let dependencies: Dependencies = Unmanaged<Dependencies>.fromOpaque(ctx).takeUnretainedValue()
                            dependencies.mutate(cache: .libSessionNetwork) { $0.setNetworkStatus(status: status) }
                        }
                    }, dependenciesPtr)
                    
                    // Register for path changes
                    network_set_paths_changed_callback(network, { pathsPtr, pathsLen, ctx in
                        guard let ctx: UnsafeMutableRawPointer = ctx else { return }
                        
                        var paths: [[Snode]] = []
                        
                        if let cPathsPtr: UnsafeMutablePointer<onion_request_path> = pathsPtr {
                            var cPaths: [onion_request_path] = []
                            
                            (0..<pathsLen).forEach { index in
                                cPaths.append(cPathsPtr[index])
                            }
                            
                            // Copy the nodes over as the memory will be freed after the callback is run
                            paths = cPaths.map { cPath in
                                var nodes: [Snode] = []
                                (0..<cPath.nodes_count).forEach { index in
                                    nodes.append(Snode(cPath.nodes[index]))
                                }
                                return nodes
                            }
                            
                            // Need to free the nodes within the path as we are the owner
                            cPaths.forEach { cPath in
                                cPath.nodes.deallocate()
                            }
                        }
                        
                        // Need to free the cPathsPtr as we are the owner
                        pathsPtr?.deallocate()
                        
                        // Dispatch async so we don't hold up the libSession thread that triggered the update
                        // or have a reentrancy issue with the mutable cache
                        DispatchQueue.global(qos: .default).async {
                            let dependencies: Dependencies = Unmanaged<Dependencies>.fromOpaque(ctx).takeUnretainedValue()
                            dependencies.mutate(cache: .libSessionNetwork) { $0.setPaths(paths: paths) }
                        }
                    }, dependenciesPtr)
                    
                    return Just(network)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
            }
        }
        
        public func setNetworkStatus(status: NetworkStatus) {
            guard status == .disconnected || !isSuspended else {
                Log.warn(.network, "Attempted to update network status to '\(status)' for suspended network, closing connections again.")
                
                switch network {
                    case .none: return
                    case .some(let network): return network_close_connections(network)
                }
            }
            
            // Notify any subscribers
            Log.info(.network, "Network status changed to: \(status)")
            _networkStatus.send(status)
        }
        
        public func setPaths(paths: [[Snode]]) {
            // Notify any subscribers
            _paths.send(paths)
        }
        
        public func clearSnodeCache() {
            switch network {
                case .none: break
                case .some(let network): network_clear_cache(network)
            }
        }
    }
    
    // MARK: - NetworkCacheType

    /// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
    protocol NetworkImmutableCacheType: ImmutableCacheType {
        var isSuspended: Bool { get }
        var networkStatus: AnyPublisher<NetworkStatus, Never> { get }
        
        var paths: AnyPublisher<[[Snode]], Never> { get }
        var hasPaths: Bool { get }
        var currentPaths: [[Snode]] { get }
        var pathsDescription: String { get }
    }

    protocol NetworkCacheType: NetworkImmutableCacheType, MutableCacheType {
        var isSuspended: Bool { get }
        var networkStatus: AnyPublisher<NetworkStatus, Never> { get }
        
        var paths: AnyPublisher<[[Snode]], Never> { get }
        var hasPaths: Bool { get }
        var currentPaths: [[Snode]] { get }
        var pathsDescription: String { get }
        
        func suspendNetworkAccess()
        func resumeNetworkAccess()
        func getOrCreateNetwork() -> AnyPublisher<UnsafeMutablePointer<network_object>?, Error>
        func setNetworkStatus(status: NetworkStatus)
        func setPaths(paths: [[Snode]])
        func clearSnodeCache()
    }
}
