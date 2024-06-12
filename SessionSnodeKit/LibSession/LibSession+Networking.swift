// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionUtil
import SessionUtilitiesKit

public extension Network.RequestType {
    // FIXME: Clean up the network/libSession injection interface
    static func downloadFile(
        from destination: Network.Destination
    ) -> Network.RequestType<Data> {
        return Network.RequestType(
            id: "downloadFile",
            url: "\(destination)",
            args: [destination]
        ) { _ in
            LibSession.downloadFile(from: destination).eraseToAnyPublisher()
        }
    }
}

// MARK: - LibSession

public extension LibSession {
    private static var networkCache: Atomic<UnsafeMutablePointer<network_object>?> = Atomic(nil)
    private static var snodeCachePath: String { "\(OWSFileSystem.appSharedDataDirectoryPath())/snodeCache" }
    private static var isSuspended: Atomic<Bool> = Atomic(false)
    private static var lastPaths: Atomic<[[Snode]]> = Atomic([])
    private static var lastNetworkStatus: Atomic<NetworkStatus> = Atomic(.unknown)
    private static var pathsChangedCallbacks: Atomic<[UUID: ([[Snode]], UUID) -> ()]> = Atomic([:])
    private static var networkStatusCallbacks: Atomic<[UUID: (NetworkStatus) -> ()]> = Atomic([:])
    
    static var hasPaths: Bool { !lastPaths.wrappedValue.isEmpty }
    static var pathsDescription: String { lastPaths.wrappedValue.prettifiedDescription }
    
    fileprivate class CallbackWrapper<Output> {
        public let resultPublisher: CurrentValueSubject<Output?, Error> = CurrentValueSubject(nil)
        private var pointersToDeallocate: [UnsafeRawPointer?] = []
        
        // MARK: - Initialization
        
        deinit {
            pointersToDeallocate.forEach { $0?.deallocate() }
        }
        
        // MARK: - Functions
        
        public static func create(_ callback: @escaping (CallbackWrapper<Output>) throws -> Void) -> AnyPublisher<Output, Error> {
            let wrapper: CallbackWrapper<Output> = CallbackWrapper()
            
            return Deferred {
                Future<Void, Error> { resolver in
                    do {
                        try callback(wrapper)
                        resolver(Result.success(()))
                    }
                    catch { resolver(Result.failure(error)) }
                }
            }
            .flatMap { _ -> AnyPublisher<Output, Error> in
                wrapper
                    .resultPublisher
                    .compactMap { $0 }
                    .first()
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
        }
        
        public static func run(_ ctx: UnsafeMutableRawPointer?, _ output: Output) {
            guard let ctx: UnsafeMutableRawPointer = ctx else {
                return Log.error("[LibSession] CallbackWrapper called with null context.")
            }
            
            // Dispatch async so we don't block libSession's internals with Swift logic (which can block other requests)
            let wrapper: CallbackWrapper<Output> = Unmanaged<CallbackWrapper<Output>>.fromOpaque(ctx).takeRetainedValue()
            DispatchQueue.global(qos: .default).async { [wrapper] in wrapper.resultPublisher.send(output) }
        }
        
        public func unsafePointer() -> UnsafeMutableRawPointer { Unmanaged.passRetained(self).toOpaque() }
        
        public func addUnsafePointerToCleanup<T>(_ pointer: UnsafePointer<T>?) {
            pointersToDeallocate.append(UnsafeRawPointer(pointer))
        }
    }
    
    // MARK: - Public Interface
    
    static func createNetworkIfNeeded(using dependencies: Dependencies = Dependencies()) {
        getOrCreateNetwork()
            .subscribe(on: DispatchQueue.global(qos: .default), using: dependencies)
            .sinkUntilComplete()
    }
    
    static func onNetworkStatusChanged(callback: @escaping (NetworkStatus) -> ()) -> UUID {
        let callbackId: UUID = UUID()
        networkStatusCallbacks.mutate { $0[callbackId] = callback }
        
        // Trigger the callback immediately with the most recent status
        callback(lastNetworkStatus.wrappedValue)
        
        return callbackId
    }
    
    static func removeNetworkChangedCallback(callbackId: UUID?) {
        guard let callbackId: UUID = callbackId else { return }
        
        networkStatusCallbacks.mutate { $0.removeValue(forKey: callbackId) }
    }
    
    static func onPathsChanged(skipInitialCallbackIfEmpty: Bool = false, callback: @escaping ([[Snode]], UUID) -> ()) -> UUID {
        let callbackId: UUID = UUID()
        pathsChangedCallbacks.mutate { $0[callbackId] = callback }
        
        // Trigger the callback immediately with the most recent status
        let lastPaths: [[Snode]] = self.lastPaths.wrappedValue
        if !lastPaths.isEmpty || !skipInitialCallbackIfEmpty {
            callback(lastPaths, callbackId)
        }
        
        return callbackId
    }
    
    static func removePathsChangedCallback(callbackId: UUID?) {
        guard let callbackId: UUID = callbackId else { return }
        
        pathsChangedCallbacks.mutate { $0.removeValue(forKey: callbackId) }
    }
    
    static func suspendNetworkAccess() {
        Log.info("[LibSession] suspendNetworkAccess called.")
        isSuspended.mutate { $0 = true }
        
        guard let network: UnsafeMutablePointer<network_object> = networkCache.wrappedValue else { return }
        
        network_suspend(network)
    }
    
    static func resumeNetworkAccess() {
        isSuspended.mutate { $0 = false }
        Log.info("[LibSession] resumeNetworkAccess called.")
        
        guard let network: UnsafeMutablePointer<network_object> = networkCache.wrappedValue else { return }
        
        network_resume(network)
    }
    
    static func clearSnodeCache() {
        guard let network: UnsafeMutablePointer<network_object> = networkCache.wrappedValue else { return }
        
        network_clear_cache(network)
    }
    
    static func getSwarm(swarmPublicKey: String) -> AnyPublisher<Set<Snode>, Error> {
        typealias Output = Result<Set<Snode>, Error>
        
        return getOrCreateNetwork()
            .flatMap { network in
                CallbackWrapper<Output>
                    .create { wrapper in
                        let cSwarmPublicKey: [CChar] = swarmPublicKey
                            .suffix(64) // Quick way to drop '05' prefix if present
                            .cArray
                            .nullTerminated()
                        
                        network_get_swarm(network, cSwarmPublicKey, { swarmPtr, swarmSize, ctx in
                            guard
                                swarmSize > 0,
                                let cSwarm: UnsafeMutablePointer<network_service_node> = swarmPtr
                            else { return CallbackWrapper<Output>.run(ctx, .failure(SnodeAPIError.unableToRetrieveSwarm)) }
                            
                            var nodes: Set<Snode> = []
                            (0..<swarmSize).forEach { index in nodes.insert(Snode(cSwarm[index])) }
                            CallbackWrapper<Output>.run(ctx, .success(nodes))
                        }, wrapper.unsafePointer());
                    }
                    .tryMap { result in try result.successOrThrow() }
            }
            .eraseToAnyPublisher()
    }
    
    static func getRandomNodes(count: Int) -> AnyPublisher<Set<Snode>, Error> {
        typealias Output = Result<Set<Snode>, Error>
        
        return getOrCreateNetwork()
            .flatMap { network in
                CallbackWrapper<Output>
                    .create { wrapper in
                        network_get_random_nodes(network, UInt16(count), { nodesPtr, nodesSize, ctx in
                            guard
                                nodesSize > 0,
                                let cSwarm: UnsafeMutablePointer<network_service_node> = nodesPtr
                            else { return CallbackWrapper<Output>.run(ctx, .failure(SnodeAPIError.unableToRetrieveSwarm)) }
                            
                            var nodes: Set<Snode> = []
                            (0..<nodesSize).forEach { index in nodes.insert(Snode(cSwarm[index])) }
                            CallbackWrapper<Output>.run(ctx, .success(nodes))
                        }, wrapper.unsafePointer());
                    }
                    .tryMap { result in
                        switch result {
                            case .failure(let error): throw error
                            case .success(let nodes):
                                guard nodes.count > count else { throw SnodeAPIError.unableToRetrieveSwarm }
                                
                                return nodes
                        }
                    }
            }
            .eraseToAnyPublisher()
    }
    
    static func sendOnionRequest<T: Encodable>(
        to destination: Network.Destination,
        body: T?,
        swarmPublicKey: String?,
        timeout: TimeInterval,
        using dependencies: Dependencies
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        typealias Output = (success: Bool, timeout: Bool, statusCode: Int, data: Data?)
        
        return getOrCreateNetwork()
            .tryFlatMap { network in
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
                
                return CallbackWrapper<Output>
                    .create { wrapper in
                        // Trigger the request
                        switch destination {
                            case .snode(let snode):
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
                                    Int64(floor(timeout * 1000)),
                                    { success, timeout, statusCode, dataPtr, dataLen, ctx in
                                        let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                                        CallbackWrapper<Output>.run(ctx, (success, timeout, Int(statusCode), data))
                                    },
                                    wrapper.unsafePointer()
                                )
                                
                            case .server:
                                network_send_onion_request_to_server_destination(
                                    network,
                                    try wrapper.cServerDestination(destination),
                                    cPayloadBytes,
                                    cPayloadBytes.count,
                                    Int64(floor(timeout * 1000)),
                                    { success, timeout, statusCode, dataPtr, dataLen, ctx in
                                        let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                                        CallbackWrapper<Output>.run(ctx, (success, timeout, Int(statusCode), data))
                                    },
                                    wrapper.unsafePointer()
                                )
                        }
                    }
                    .tryMap { success, timeout, statusCode, data -> (any ResponseInfoType, Data?) in
                        try throwErrorIfNeeded(success, timeout, statusCode, data)
                        return (Network.ResponseInfo(code: statusCode), data)
                    }
            }
            .eraseToAnyPublisher()
    }
    
    static func uploadToServer(
        _ data: Data,
        to server: Network.Destination,
        fileName: String?,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<(ResponseInfoType, FileUploadResponse), Error> {
        typealias Output = (success: Bool, timeout: Bool, statusCode: Int, data: Data?)
        
        return getOrCreateNetwork()
            .tryFlatMap { network in
                CallbackWrapper<Output>
                    .create { wrapper in
                        network_upload_to_server(
                            network,
                            try wrapper.cServerDestination(server),
                            Array(data),
                            data.count,
                            fileName?.cString(using: .utf8),
                            Int64(floor(Network.fileUploadTimeout * 1000)),
                            { success, timeout, statusCode, dataPtr, dataLen, ctx in
                                let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                                CallbackWrapper<Output>.run(ctx, (success, timeout, Int(statusCode), data))
                            },
                            wrapper.unsafePointer()
                        )
                    }
                    .tryMap { success, timeout, statusCode, maybeData -> (any ResponseInfoType, FileUploadResponse) in
                        try throwErrorIfNeeded(success, timeout, statusCode, maybeData)
                        
                        guard let data: Data = maybeData else { throw NetworkError.parsingFailed }
                        
                        return (
                            Network.ResponseInfo(code: statusCode),
                            try FileUploadResponse.decoded(from: data, using: dependencies)
                        )
                    }
            }
    }
    
    static func downloadFile(from server: Network.Destination) -> AnyPublisher<(ResponseInfoType, Data), Error> {
        typealias Output = (success: Bool, timeout: Bool, statusCode: Int, data: Data?)
        
        return getOrCreateNetwork()
            .tryFlatMap { network in
                return CallbackWrapper<Output>
                    .create { wrapper in
                        network_download_from_server(
                            network,
                            try wrapper.cServerDestination(server),
                            Int64(floor(Network.fileDownloadTimeout * 1000)),
                            { success, timeout, statusCode, dataPtr, dataLen, ctx in
                                let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                                CallbackWrapper<Output>.run(ctx, (success, timeout, Int(statusCode), data))
                            },
                            wrapper.unsafePointer()
                        )
                    }
                    .tryMap { success, timeout, statusCode, maybeData -> (any ResponseInfoType, Data) in
                        try throwErrorIfNeeded(success, timeout, statusCode, maybeData)
                        
                        guard let data: Data = maybeData else { throw NetworkError.parsingFailed }
                        
                        return (
                            Network.ResponseInfo(code: statusCode),
                            data
                        )
                    }
            }
    }
    
    static func checkClientVersion(
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<(ResponseInfoType, AppVersionResponse), Error> {
        typealias Output = (success: Bool, timeout: Bool, statusCode: Int, data: Data?)
        
        return getOrCreateNetwork()
            .tryFlatMap { network in
                return CallbackWrapper<Output>
                    .create { wrapper in
                        network_get_client_version(
                            network,
                            CLIENT_PLATFORM_IOS,
                            Int64(floor(Network.fileDownloadTimeout * 1000)),
                            { success, timeout, statusCode, dataPtr, dataLen, ctx in
                                let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
                                CallbackWrapper<Output>.run(ctx, (success, timeout, Int(statusCode), data))
                            },
                            wrapper.unsafePointer()
                        )
                    }
                    .tryMap { success, timeout, statusCode, maybeData -> (any ResponseInfoType, AppVersionResponse) in
                        try throwErrorIfNeeded(success, timeout, statusCode, maybeData)
                        
                        guard let data: Data = maybeData else { throw NetworkError.parsingFailed }
                        
                        return (
                            Network.ResponseInfo(code: statusCode),
                            try AppVersionResponse.decoded(from: data, using: dependencies)
                        )
                    }
            }
    }
    
    // MARK: - Internal Functions
    
    private static func getOrCreateNetwork() -> AnyPublisher<UnsafeMutablePointer<network_object>?, Error> {
        guard !isSuspended.wrappedValue else {
            Log.warn("[LibSession] Attempted to access suspended network.")
            return Fail(error: NetworkError.suspended).eraseToAnyPublisher()
        }
        
        guard networkCache.wrappedValue == nil else {
            return Just(networkCache.wrappedValue)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        return Deferred {
            Future<UnsafeMutablePointer<network_object>?, Error> { resolver in
                let network: UnsafeMutablePointer<network_object>? = networkCache.mutate { cachedNetwork in
                    // It's possible for two threads to get past the initial `wrappedValue` check so just
                    // in case check and return the cached value if set
                    if let existingNetwork: UnsafeMutablePointer<network_object> = cachedNetwork {
                        return existingNetwork
                    }
                    
                    // Otherwise create a new network
                    var error: [CChar] = [CChar](repeating: 0, count: 256)
                    var network: UnsafeMutablePointer<network_object>?
                    
                    guard let cCachePath: [CChar] = snodeCachePath.cString(using: .utf8) else {
                        Log.error("[LibQuic] Unable to create network object: \(LibSessionError.invalidCConversion)")
                        return nil
                    }
                    
                    guard network_init(&network, cCachePath, Features.useTestnet, true, &error) else {
                        Log.error("[LibQuic] Unable to create network object: \(String(cString: error))")
                        return nil
                    }
                    
                    // Register for network status changes
                    network_set_status_changed_callback(network, { status, _ in
                        LibSession.updateNetworkStatus(cStatus: status)
                    }, nil)
                    
                    // Register for path changes
                    network_set_paths_changed_callback(network, { pathsPtr, pathsLen, _ in
                        LibSession.updatePaths(cPathsPtr: pathsPtr, pathsLen: pathsLen)
                    }, nil)
                    
                    cachedNetwork = network
                    return network
                }
                
                switch network {
                    case .none: resolver(Result.failure(SnodeAPIError.invalidNetwork))
                    case .some(let network): resolver(Result.success(network))
                }
            }
        }.eraseToAnyPublisher()
    }
    
    private static func updateNetworkStatus(cStatus: CONNECTION_STATUS) {
        let status: NetworkStatus = NetworkStatus(status: cStatus)
        
        guard status == .disconnected || !isSuspended.wrappedValue else {
            Log.warn("[LibSession] Attempted to update network status to '\(status)' for suspended network, closing connections again.")
            
            guard let network: UnsafeMutablePointer<network_object> = networkCache.wrappedValue else { return }
            network_close_connections(network)
            return
        }
        
        // Dispatch async so we don't hold up the libSession thread that triggered the update
        DispatchQueue.global(qos: .default).async {
            Log.info("Network status changed to: \(status)")
            lastNetworkStatus.mutate { lastNetworkStatus in
                lastNetworkStatus = status
                
                networkStatusCallbacks.wrappedValue.forEach { _, callback in
                    callback(status)
                }
            }
        }
    }
    
    private static func updatePaths(cPathsPtr: UnsafeMutablePointer<onion_request_path>?, pathsLen: Int) {
        var paths: [[Snode]] = []
        
        if let cPathsPtr: UnsafeMutablePointer<onion_request_path> = cPathsPtr {
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
        cPathsPtr?.deallocate()
        
        // Dispatch async so we don't hold up the libSession thread that triggered the update
        DispatchQueue.global(qos: .default).async {
            lastPaths.mutate { lastPaths in
                lastPaths = paths
                
                pathsChangedCallbacks.wrappedValue.forEach { id, callback in
                    callback(paths, id)
                }
            }
        }
    }
    
    private static func throwErrorIfNeeded(
        _ success: Bool,
        _ timeout: Bool,
        _ statusCode: Int,
        _ data: Data?
    ) throws {
        guard !success || statusCode < 200 || statusCode > 299 else { return }
        guard !timeout else { throw NetworkError.timeout }
        
        /// Handle status codes with specific meanings
        switch (statusCode, data.map { String(data: $0, encoding: .ascii) }) {
            case (400, .none): throw NetworkError.badRequest(error: "\(NetworkError.unknown)", rawData: data)
            case (400, .some(let responseString)): throw NetworkError.badRequest(error: responseString, rawData: data)
                
            case (401, _):
                Log.warn("Unauthorised (Failed to verify the signature).")
                throw NetworkError.unauthorised
                
            case (404, _): throw NetworkError.notFound
                
            /// A snode will return a `406` but onion requests v4 seems to return `425` so handle both
            case (406, _), (425, _):
                Log.warn("The user's clock is out of sync with the service node network.")
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
                
                throw SnodeAPIError.nodeNotFound(String(responseString.suffix(64)))
                
            case (_, .none): throw NetworkError.unknown
            case (_, .some(let responseString)): throw NetworkError.requestFailed(error: responseString, rawData: data)
        }
    }
}

// MARK: - NetworkStatus

extension LibSession {
    public enum NetworkStatus {
        case unknown
        case connecting
        case connected
        case disconnected
        
        init(status: CONNECTION_STATUS) {
            switch status {
                case CONNECTION_STATUS_CONNECTING: self = .connecting
                case CONNECTION_STATUS_CONNECTED: self = .connected
                case CONNECTION_STATUS_DISCONNECTED: self = .disconnected
                default: self = .unknown
            }
        }
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
            return network_service_node(
                ip: ip.toLibSession(),
                quic_port: quicPort,
                ed25519_pubkey_hex: ed25519PubkeyHex.toLibSession()
            )
        }
        
        init(_ cSnode: network_service_node) {
            ip = "\(cSnode.ip.0).\(cSnode.ip.1).\(cSnode.ip.2).\(cSnode.ip.3)"
            quicPort = cSnode.quic_port
            ed25519PubkeyHex = String(libSessionVal: cSnode.ed25519_pubkey_hex)
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

// MARK: - Convenience

public extension Network.Destination {
    static var fileServer: Network.Destination = .server(
        url: try! Network.fileServerUploadUrl(),
        method: .post,
        headers: nil,
        x25519PublicKey: Network.fileServerPubkey()
    )
    
    static func fileServer(downloadUrl: URL) -> Network.Destination {
        return .server(
            url: downloadUrl,
            method: .get,
            headers: nil,
            x25519PublicKey: Network.fileServerPubkey(url: downloadUrl.absoluteString)
        )
    }
}

private extension LibSession.CallbackWrapper {
    func cServerDestination(_ destination: Network.Destination) throws -> network_server_destination {
        guard
            case .server(let url, let method, let headers, let x25519PublicKey) = destination,
            let host: String = url.host
        else { throw NetworkError.invalidURL }
        
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
