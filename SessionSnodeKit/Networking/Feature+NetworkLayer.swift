// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUtilitiesKit

// MARK: - FeatureStorage

public extension FeatureStorage {
    static let networkLayers: FeatureConfig<Network.Layers> = Dependencies.create(
        identifier: "networkLayers"
    )
}

// MARK: - Network.Layers

public extension Network {
    struct Layers: OptionSet, Equatable, Hashable, Differentiable, FeatureOption {
        public static let onionRequest: Layers = Layers(rawValue: 1 << 0)
        public static let direct: Layers = Layers(rawValue: 1 << 1)
        
        public enum Events: FeatureEvent {
            case updatedNetworkLayer
            case resetPaths
            case buildingPaths
            case pathsBuilt
            case onionRequestPathCountriesLoaded
            
            public static var updateValueEvent: Events = .updatedNetworkLayer
        }
        
        // MARK: - CaseIterable
        
        public static var allCases: [Layers] = [.onionRequest, .direct]
        
        // MARK: - Initialization
        
        public let rawValue: Int
        
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }
        
        // MARK: - FeatureOption
        
        public static var defaultOption: Layers = .onionRequest
        
        /// Looks like we can init this with a `0` value and it'll successfully create the instance (as an empty set), this state
        /// is invalid so should be marked as such
        public var isValidOption: Bool { !isEmpty }
        
        public var title: String {
            let individualLayerNames: [String] = [
                (self.contains(.onionRequest) ? "Onion Requests" : nil),
                (self.contains(.direct) ? "Direct" : nil)
            ].compactMap { $0 }
            
            guard !individualLayerNames.isEmpty else { return "Onion Requests" }
            guard individualLayerNames.count > 1 else { return individualLayerNames[0] }
            
            return [
                individualLayerNames
                    .removing(index: individualLayerNames.count - 1)
                    .joined(separator: ", "),
                individualLayerNames[individualLayerNames.count - 1]
            ]
            .joined(separator: " and ")
        }
        
        public var subtitle: String? {
            switch self {
                case .onionRequest:
                    return """
                    Requests will be sent via the original Onion Request mechanism, they will be routed between 3 service nodes before reaching their destination.
                    """
                    
                case .direct:
                    return """
                    Requests will be sent directly over HTTPS.
                    
                    <b>Warning:</b> This network layer offers no IP protections so should only be used for debugging purposes.
                    """
                    
                default: return "This is a combination of multiple network layers, requests will be sent over each layer (triggered at the same time)"
            }
        }
        
        public var individualLayers: Set<Layers> {
            return [
                (self.contains(.onionRequest) ? .onionRequest : nil),
                (self.contains(.direct) ? .direct : nil)
            ]
            .compactMap { $0 }
            .asSet()
        }
    }
}

// MARK: - Convenience

public extension Network.Layers {
    func map<R>(_ transform: (Network.Layers) -> R) -> [R] {
        return [
            (self.contains(.onionRequest) ? transform(.onionRequest) : nil),
            (self.contains(.direct) ? transform(.direct) : nil)
        ]
        .compactMap { $0 }
    }
    
    func compactMap<R>(_ transform: (Network.Layers) -> R?) -> [R] {
        return [
            (self.contains(.onionRequest) ? transform(.onionRequest) : nil),
            (self.contains(.direct) ? transform(.direct) : nil)
        ]
        .compactMap { $0 }
    }
}

// MARK: - RequestType

public extension Network.RequestType {
    static func selectedNetworkRequest(
        _ payload: Data,
        to snode: Snode,
        timeout: TimeInterval = HTTP.defaultTimeout,
        using dependencies: Dependencies
    ) -> Network.RequestType<Data?> {
        let requestId: UUID = UUID()
        
        return Network.RequestType(
            id: "selectedNetworkRequest",
            url: snode.address,
            method: "POST",
            body: payload,
            args: [payload, snode, timeout]
        ) {
            return Publishers
                .MergeMany(
                    dependencies[feature: .networkLayers]
                        .compactMap { layer -> AnyPublisher<Result<(ResponseInfoType, Data?), Error>, Never>? in
                            switch layer {
                                case .onionRequest:
                                    return Network.RequestType<Data?>
                                        .onionRequest(payload, to: snode, timeout: timeout)
                                        .generatePublisher()
                                        .asResult()
                                    
                                case .direct:
                                    return Network.RequestType<Data?>
                                        .directRequest(payload, to: snode, timeout: timeout)
                                        .generatePublisher()
                                        .asResult()
                                    
                                default: return nil
                            }
                        }
                )
                .collectAndReturnFirstSuccessResponse(id: requestId, using: dependencies)
        }
    }
    
    static func selectedNetworkRequest(
        _ request: URLRequest,
        to server: String,
        with x25519PublicKey: String,
        timeout: TimeInterval = HTTP.defaultTimeout,
        using dependencies: Dependencies
    ) -> Network.RequestType<Data?> {
        let requestId: UUID = UUID()
        
        return Network.RequestType(
            id: "selectedNetworkRequest",
            url: request.url?.absoluteString,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields,
            body: request.httpBody,
            args: [request, server, x25519PublicKey, timeout]
        ) {
            return Publishers
                .MergeMany(
                    dependencies[feature: .networkLayers]
                        .compactMap { layer -> AnyPublisher<Result<(ResponseInfoType, Data?), Error>, Never>? in
                            switch layer {
                                case .onionRequest:
                                    return Network.RequestType<Data?>
                                        .onionRequest(
                                            request,
                                            to: server,
                                            with: x25519PublicKey,
                                            timeout: timeout
                                        )
                                        .generatePublisher()
                                        .asResult()
                                    
                                case .direct:
                                    return Network.RequestType<Data?>
                                        .directRequest(
                                            request,
                                            to: server,
                                            with: x25519PublicKey,
                                            timeout: timeout
                                        )
                                        .generatePublisher()
                                        .asResult()
                                    
                                default: return nil
                            }
                        }
                )
                .collectAndReturnFirstSuccessResponse(id: requestId, using: dependencies)
        }
    }
}

// MARK: - Convenience

fileprivate extension Publishers.MergeMany where Upstream.Output == Result<(ResponseInfoType, Data?), Error> {
    func collectAndReturnFirstSuccessResponse(
        id: UUID,
        using dependencies: Dependencies
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        self
            .collect()
            .handleEvents(
                receiveSubscription: { subscription in
                    dependencies.mutate(cache: .network) { $0.currentRequests[id.uuidString] = subscription }
                },
                receiveCompletion: { _ in
                    dependencies.mutate(cache: .network) { $0.currentRequests[id.uuidString] = nil }
                }
            )
            .tryMap { (results: [Result<(ResponseInfoType, Data?), Error>]) -> (ResponseInfoType, Data?) in
                guard
                    let result: Result<(ResponseInfoType, Data?), Error> = results.first(where: { result in
                        switch result {
                            case .success: return true
                            case .failure: return false
                        }
                    }),
                    case .success(let response) = result,
                    let data: Data = response.1,
                    let json: [String: Any] = try? JSONSerialization
                        .jsonObject(with: data, options: [ .fragmentsAllowed ]) as? [String: Any],
                    let timestamp: Int64 = json["t"] as? Int64
                else {
                    switch results.first {
                        case .success(let value): return value
                        case .failure(let error): throw error
                        default: throw HTTPError.networkWrappersNotReady
                    }
                }
                
                let offset: Int64 = timestamp - Int64(floor(Date().timeIntervalSince1970 * 1000))
                dependencies.mutate(cache: .snodeAPI) { $0.clockOffsetMs = offset }

                return response
            }
            .eraseToAnyPublisher()
    }
}

// MARK: - Network Cache

public extension Network {
    class Cache: NetworkCacheType {
        public var currentRequests: [String: Subscription] = [:]
    }
}

public extension Cache {
    static let network: CacheConfig<NetworkCacheType, NetworkImmutableCacheType> = Dependencies.create(
        identifier: "networkCache",
        createInstance: { _ in Network.Cache() },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - NetworkCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol NetworkImmutableCacheType: ImmutableCacheType {
    var currentRequests: [String: Subscription] { get }
}

public protocol NetworkCacheType: NetworkImmutableCacheType, MutableCacheType {
    var currentRequests: [String: Subscription] { get set }
}
