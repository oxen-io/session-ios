// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

// MARK: - Network.PreparedRequest<R>

public extension Network {
    struct PreparedRequest<R> {
        public struct CachedResponse {
            fileprivate let info: ResponseInfoType
            fileprivate let originalData: Any
            fileprivate let convertedData: R
        }
        
        public let body: Data?
        public let destination: Destination
        public let additionalSignatureData: Any?
        public let originalType: Decodable.Type
        public let responseType: R.Type
        public let retryCount: Int
        public let requestTimeout: TimeInterval
        public let requestAndPathBuildTimeout: TimeInterval?
        public let cachedResponse: CachedResponse?
        fileprivate let responseConverter: ((ResponseInfoType, Any) throws -> R)
        public let subscriptionHandler: (() -> Void)?
        public let outputEventHandler: (((CachedResponse)) -> Void)?
        public let completionEventHandler: ((Subscribers.Completion<Error>) -> Void)?
        public let cancelEventHandler: (() -> Void)?
        
        // The following types are needed for `BatchRequest` handling
        public let method: HTTPMethod
        public let path: String
        public let endpoint: (any EndpointType)
        public let endpointName: String
        public let headers: [HTTPHeader: String]
        public let batchEndpoints: [any EndpointType]
        public let batchRequestVariant: Network.BatchRequest.Child.Variant
        public let batchResponseTypes: [Decodable.Type]
        public let requireAllBatchResponses: Bool
        public let excludedSubRequestHeaders: [HTTPHeader]
        
        private let jsonKeyedBodyEncoder: ((inout KeyedEncodingContainer<Network.BatchRequest.Child.CodingKeys>, Network.BatchRequest.Child.CodingKeys) throws -> ())?
        private let jsonBodyEncoder: ((inout SingleValueEncodingContainer) throws -> ())?
        private let b64: String?
        private let bytes: [UInt8]?
        
        public init<T: Encodable, E: EndpointType>(
            request: Request<T, E>,
            responseType: R.Type,
            requireAllBatchResponses: Bool = true,
            retryCount: Int = 0,
            requestTimeout: TimeInterval = Network.defaultTimeout,
            requestAndPathBuildTimeout: TimeInterval? = nil,
            using dependencies: Dependencies
        ) throws where R: Decodable {
            try self.init(
                request: request,
                responseType: responseType,
                additionalSignatureData: NoSignature.null,
                requireAllBatchResponses: requireAllBatchResponses,
                retryCount: retryCount,
                requestTimeout: requestTimeout,
                requestAndPathBuildTimeout: requestAndPathBuildTimeout,
                using: dependencies
            )
        }
        
        public init<T: Encodable, E: EndpointType, S>(
            request: Request<T, E>,
            responseType: R.Type,
            additionalSignatureData: S?,
            requireAllBatchResponses: Bool = true,
            retryCount: Int = 0,
            requestTimeout: TimeInterval = Network.defaultTimeout,
            requestAndPathBuildTimeout: TimeInterval? = nil,
            using dependencies: Dependencies
        ) throws where R: Decodable {
            let batchRequests: [Network.BatchRequest.Child]? = (request.body as? BatchRequestChildRetrievable)?.requests
            let batchEndpoints: [E] = (batchRequests?
                .compactMap { $0.request.batchRequestEndpoint(of: E.self) })
                .defaulting(to: [])
            let batchResponseTypes: [Decodable.Type]? = (batchRequests?
                .compactMap { batchRequest -> [Decodable.Type]? in
                    guard batchRequest.request.batchRequestEndpoint(of: E.self) != nil else { return nil }
                    
                    return batchRequest.request.batchResponseTypes
                }
                .flatMap { $0 })
            
            self.body = try request.bodyData(using: dependencies)
            self.destination = request.destination
            self.additionalSignatureData = additionalSignatureData
            self.originalType = R.self
            self.responseType = responseType
            self.retryCount = retryCount
            self.requestTimeout = requestTimeout
            self.requestAndPathBuildTimeout = requestAndPathBuildTimeout
            self.cachedResponse = nil
            
            // When we are making a batch request we also want to call though any sub request event
            // handlers (this allows a lot more reusability for individual requests to manage their
            // own results or custom handling just when triggered via a batch request)
            self.responseConverter = {
                guard
                    let subRequestResponseConverters: [(Int, ((ResponseInfoType, Any) throws -> Any))] = batchRequests?
                        .enumerated()
                        .compactMap({ ($0.0, $0.1.request.erasedResponseConverter) }),
                    !subRequestResponseConverters.isEmpty
                else {
                    return { info, response in
                        guard let validResponse: R = response as? R else { throw NetworkError.invalidResponse }
                        
                        return validResponse
                    }
                }
                
                // Results are returned in the same order they were made in so we can use the matching
                // indexes to get the correct response
                return { info, response in
                    let convertedResponse: Any = try {
                        switch response {
                            case let batchResponse as Network.BatchResponse:
                                return Network.BatchResponse(
                                    data: try subRequestResponseConverters
                                        .map { index, responseConverter in
                                            guard batchResponse.count > index else {
                                                throw NetworkError.invalidResponse
                                            }
                                            
                                            return try responseConverter(info, batchResponse[index])
                                        }
                                )
                            
                            case let batchResponseMap as Network.BatchResponseMap<E>:
                                return Network.BatchResponseMap(
                                    data: try subRequestResponseConverters
                                        .reduce(into: [E: Any]()) { result, subResponse in
                                            let index: Int = subResponse.0
                                            let responseConverter: ((ResponseInfoType, Any) throws -> Any) = subResponse.1
                                            
                                            guard
                                                batchEndpoints.count > index,
                                                let targetResponse: Any = batchResponseMap[batchEndpoints[index]]
                                            else { throw NetworkError.invalidResponse }
                                            
                                            let endpoint: E = batchEndpoints[index]
                                            result[endpoint] = try responseConverter(info, targetResponse)
                                        }
                                )
                            
                            default: throw NetworkError.invalidResponse
                        }
                    }()
                    
                    guard let validResponse: R = convertedResponse as? R else {
                        Log.error("[PreparedRequest] Unable to convert responses for missing response")
                        throw NetworkError.invalidResponse
                    }
                    
                    return validResponse
                }
            }()
            self.outputEventHandler = {
                guard
                    let subRequestEventHandlers: [(Int, ((ResponseInfoType, Any, Any) -> Void))] = batchRequests?
                        .enumerated()
                        .compactMap({ index, batchRequest in
                            batchRequest.request.erasedOutputEventHandler.map { (index, $0) }
                        }),
                    !subRequestEventHandlers.isEmpty
                else { return nil }
                
                // Results are returned in the same order they were made in so we can use the matching
                // indexes to get the correct response
                return { data in
                    switch data.originalData {
                        case let batchResponse as Network.BatchResponse:
                            subRequestEventHandlers.forEach { index, eventHandler in
                                guard batchResponse.count > index else {
                                    Log.error("[PreparedRequest] Unable to handle output events for missing response")
                                    return
                                }
                                
                                eventHandler(data.info, batchResponse[index], batchResponse[index])
                            }
                        
                        case let batchResponseMap as Network.BatchResponseMap<E>:
                            subRequestEventHandlers.forEach { index, eventHandler in
                                guard
                                    batchEndpoints.count > index,
                                    let targetResponse: Any = batchResponseMap[batchEndpoints[index]]
                                else {
                                    Log.error("[PreparedRequest] Unable to handle output events for missing response")
                                    return
                                }
                                
                                eventHandler(data.info, targetResponse, targetResponse)
                            }
                            
                        default: Log.error("[PreparedRequest] Unable to handle output events for unknown batch response type")
                    }
                }
            }()
            self.subscriptionHandler = nil
            self.completionEventHandler = {
                guard
                    let subRequestEventHandlers: [((Subscribers.Completion<Error>) -> Void)] = batchRequests?
                        .compactMap({ $0.request.completionEventHandler }),
                    !subRequestEventHandlers.isEmpty
                else { return nil }
                
                // Since the completion event doesn't provide us with any data we can't return the
                // individual subRequest results here
                return { result in subRequestEventHandlers.forEach { $0(result) } }
            }()
            self.cancelEventHandler = {
                guard
                    let subRequestEventHandlers: [(() -> Void)] = batchRequests?
                        .compactMap({ $0.request.cancelEventHandler }),
                    !subRequestEventHandlers.isEmpty
                else { return nil }
                
                return { subRequestEventHandlers.forEach { $0() } }
            }()
            
            // The following data is needed in this type for handling batch requests
            self.method = request.destination.method
            self.endpoint = request.endpoint
            self.endpointName = E.name
            self.path = request.destination.urlPathAndParamsString
            self.headers = request.destination.headers
            
            self.batchEndpoints = batchEndpoints
            self.batchRequestVariant = E.batchRequestVariant
            self.batchResponseTypes = batchResponseTypes.defaulting(to: [Network.BatchSubResponse<R>.self])
            self.requireAllBatchResponses = requireAllBatchResponses
            self.excludedSubRequestHeaders = E.excludedSubRequestHeaders
            
            if batchRequests != nil && self.batchEndpoints.count != self.batchResponseTypes.count {
                Log.error("[PreparedRequest] Created with invalid sub requests")
            }
            
            // Note: Need to differentiate between JSON, b64 string and bytes body values to ensure
            // they are encoded correctly so the server knows how to handle them
            switch request.body {
                case let bodyString as String:
                    self.jsonKeyedBodyEncoder = nil
                    self.jsonBodyEncoder = nil
                    self.b64 = bodyString
                    self.bytes = nil
                    
                case let bodyBytes as [UInt8]:
                    self.jsonKeyedBodyEncoder = nil
                    self.jsonBodyEncoder = nil
                    self.b64 = nil
                    self.bytes = bodyBytes
                    
                default:
                    self.jsonKeyedBodyEncoder = { [body = request.body] container, key in
                        try container.encodeIfPresent(body, forKey: key)
                    }
                    self.jsonBodyEncoder = { [body = request.body] container in
                        try container.encode(body)
                    }
                    self.b64 = nil
                    self.bytes = nil
            }
        }
        
        fileprivate init<U: Decodable>(
            body: Data?,
            destination: Destination,
            additionalSignatureData: Any?,
            originalType: U.Type,
            responseType: R.Type,
            retryCount: Int,
            requestTimeout: TimeInterval,
            requestAndPathBuildTimeout: TimeInterval?,
            cachedResponse: CachedResponse?,
            responseConverter: @escaping (ResponseInfoType, Any) throws -> R,
            subscriptionHandler: (() -> Void)?,
            outputEventHandler: ((CachedResponse) -> Void)?,
            completionEventHandler: ((Subscribers.Completion<Error>) -> Void)?,
            cancelEventHandler: (() -> Void)?,
            method: HTTPMethod,
            endpoint: (any EndpointType),
            endpointName: String,
            headers: [HTTPHeader: String],
            path: String,
            batchEndpoints: [any EndpointType],
            batchRequestVariant: Network.BatchRequest.Child.Variant,
            batchResponseTypes: [Decodable.Type],
            requireAllBatchResponses: Bool,
            excludedSubRequestHeaders: [HTTPHeader],
            jsonKeyedBodyEncoder: ((inout KeyedEncodingContainer<Network.BatchRequest.Child.CodingKeys>, Network.BatchRequest.Child.CodingKeys) throws -> ())?,
            jsonBodyEncoder: ((inout SingleValueEncodingContainer) throws -> ())?,
            b64: String?,
            bytes: [UInt8]?
        ) {
            self.body = body
            self.destination = destination
            self.additionalSignatureData = additionalSignatureData
            self.originalType = originalType
            self.responseType = responseType
            self.retryCount = retryCount
            self.requestTimeout = requestTimeout
            self.requestAndPathBuildTimeout = requestAndPathBuildTimeout
            self.cachedResponse = cachedResponse
            self.responseConverter = responseConverter
            self.subscriptionHandler = subscriptionHandler
            self.outputEventHandler = outputEventHandler
            self.completionEventHandler = completionEventHandler
            self.cancelEventHandler = cancelEventHandler
            
            // The following data is needed in this type for handling batch requests
            self.method = method
            self.endpoint = endpoint
            self.endpointName = endpointName
            self.headers = headers
            self.path = path
            self.batchEndpoints = batchEndpoints
            self.batchRequestVariant = batchRequestVariant
            self.batchResponseTypes = batchResponseTypes
            self.requireAllBatchResponses = requireAllBatchResponses
            self.excludedSubRequestHeaders = excludedSubRequestHeaders
            self.jsonKeyedBodyEncoder = jsonKeyedBodyEncoder
            self.jsonBodyEncoder = jsonBodyEncoder
            self.b64 = b64
            self.bytes = bytes
        }
    }
}

// MARK: - ErasedPreparedRequest

public protocol ErasedPreparedRequest {
    var endpointName: String { get }
    var batchRequestVariant: Network.BatchRequest.Child.Variant { get }
    var batchResponseTypes: [Decodable.Type] { get }
    var excludedSubRequestHeaders: [HTTPHeader] { get }
    
    var erasedResponseConverter: ((ResponseInfoType, Any) throws -> Any) { get }
    var erasedOutputEventHandler: ((ResponseInfoType, Any, Any) -> Void)? { get }
    var completionEventHandler: ((Subscribers.Completion<Error>) -> Void)? { get }
    var cancelEventHandler: (() -> Void)? { get }
    
    func batchRequestEndpoint<E: EndpointType>(of type: E.Type) -> E?
    func encodeForBatchRequest(to encoder: Encoder) throws
}

extension Network.PreparedRequest: ErasedPreparedRequest {
    public var erasedResponseConverter: ((ResponseInfoType, Any) throws -> Any) {
        let originalType: Decodable.Type = self.originalType
        let converter: ((ResponseInfoType, Any) throws -> R) = self.responseConverter
        
        return { info, data in
            switch data {
                case let subResponse as ErasedBatchSubResponse:
                    return Network.BatchSubResponse(
                        code: subResponse.code,
                        headers: subResponse.headers,
                        body: try originalType.from(subResponse.erasedBody).map { try converter(info, $0) },
                        failedToParseBody: subResponse.failedToParseBody
                    )
                    
                default: return try originalType.from(data).map { try converter(info, $0) } as Any
            }
        }
    }
    
    public var erasedOutputEventHandler: ((ResponseInfoType, Any, Any) -> Void)? {
        guard let outputEventHandler: ((CachedResponse) -> Void) = self.outputEventHandler else {
            return nil
        }
        
        let originalType: Decodable.Type = self.originalType
        let originalConverter: ((ResponseInfoType, Any) throws -> R) = self.responseConverter
        
        return { info, _, data in
            switch data {
                case let subResponse as ErasedBatchSubResponse:
                    guard
                        let erasedBody: Any = originalType.from(subResponse.erasedBody),
                        let validResponse: R = try? originalConverter(info, erasedBody)
                    else { return }
                    
                    outputEventHandler(CachedResponse(
                        info: info,
                        originalData: subResponse.erasedBody as Any,
                        convertedData: validResponse
                    ))
                    
                default:
                    guard
                        let erasedBody: Any = originalType.from(data),
                        let validResponse: R = try? originalConverter(info, erasedBody)
                    else { return }
                    
                    outputEventHandler(CachedResponse(
                        info: info,
                        originalData: erasedBody,
                        convertedData: validResponse
                    ))
            }
        }
    }
    
    public func batchRequestEndpoint<E: EndpointType>(of type: E.Type) -> E? {
        return (endpoint as? E)
    }
    
    public func encodeForBatchRequest(to encoder: Encoder) throws {
        switch batchRequestVariant {
            case .unsupported:
                SNLog("Attempted to encode unsupported request type \(endpointName) as a batch subrequest")
                
            case .sogs:
                var container: KeyedEncodingContainer<Network.BatchRequest.Child.CodingKeys> = encoder.container(keyedBy: Network.BatchRequest.Child.CodingKeys.self)
                
                // Exclude request signature headers (not used for sub-requests)
                let excludedSubRequestHeaders: [HTTPHeader] = excludedSubRequestHeaders
                let batchRequestHeaders: [HTTPHeader: String] = headers
                    .filter { key, _ in !excludedSubRequestHeaders.contains(key) }
                
                if !batchRequestHeaders.isEmpty {
                    try container.encode(batchRequestHeaders, forKey: .headers)
                }
                
                try container.encode(method, forKey: .method)
                try container.encode(path, forKey: .path)
                try jsonKeyedBodyEncoder?(&container, .json)
                try container.encodeIfPresent(b64, forKey: .b64)
                try container.encodeIfPresent(bytes, forKey: .bytes)
                
            case .storageServer:
                var container: SingleValueEncodingContainer = encoder.singleValueContainer()
                
                try jsonBodyEncoder?(&container)
        }
    }
}

// MARK: - Transformations

public extension Network.PreparedRequest {
    func signed(
        _ db: Database,
        with requestSigner: (Database, Network.PreparedRequest<R>, Dependencies) throws -> Network.Destination,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<R> {
        let signedDestination: Network.Destination = try requestSigner(db, self, dependencies)
        
        return Network.PreparedRequest(
            body: body,
            destination: signedDestination,
            additionalSignatureData: additionalSignatureData,
            originalType: originalType,
            responseType: responseType,
            retryCount: retryCount,
            requestTimeout: requestTimeout,
            requestAndPathBuildTimeout: requestAndPathBuildTimeout,
            cachedResponse: cachedResponse,
            responseConverter: responseConverter,
            subscriptionHandler: subscriptionHandler,
            outputEventHandler: outputEventHandler,
            completionEventHandler: completionEventHandler,
            cancelEventHandler: cancelEventHandler,
            method: method,
            endpoint: endpoint,
            endpointName: endpointName,
            headers: signedDestination.headers,
            path: path,
            batchEndpoints: batchEndpoints,
            batchRequestVariant: batchRequestVariant,
            batchResponseTypes: batchResponseTypes,
            requireAllBatchResponses: requireAllBatchResponses,
            excludedSubRequestHeaders: excludedSubRequestHeaders,
            jsonKeyedBodyEncoder: jsonKeyedBodyEncoder,
            jsonBodyEncoder: jsonBodyEncoder,
            b64: b64,
            bytes: bytes
        )
    }
    
    /// Due to the way prepared requests work we need to cast between different types and as a result can't avoid potentially
    /// throwing when mapping so the `map` function just calls through to the `tryMap` function, but we have both to make
    /// the interface more consistent for dev use
    func map<O>(transform: @escaping (ResponseInfoType, R) throws -> O) -> Network.PreparedRequest<O> {
        return tryMap(transform: transform)
    }
    
    func tryMap<O>(transform: @escaping (ResponseInfoType, R) throws -> O) -> Network.PreparedRequest<O> {
        let originalConverter: ((ResponseInfoType, Any) throws -> R) = self.responseConverter
        let responseConverter: ((ResponseInfoType, Any) throws -> O) = { info, response in
            let validResponse: R = try originalConverter(info, response)
            
            return try transform(info, validResponse)
        }
        
        return Network.PreparedRequest<O>(
            body: body,
            destination: destination,
            additionalSignatureData: additionalSignatureData,
            originalType: originalType,
            responseType: O.self,
            retryCount: retryCount,
            requestTimeout: requestTimeout,
            requestAndPathBuildTimeout: requestAndPathBuildTimeout,
            cachedResponse: cachedResponse.map { data in
                (try? responseConverter(data.info, data.convertedData))
                    .map { convertedData in
                        Network.PreparedRequest<O>.CachedResponse(
                            info: data.info,
                            originalData: data.originalData,
                            convertedData: convertedData
                        )
                    }
            },
            responseConverter: responseConverter,
            subscriptionHandler: subscriptionHandler,
            outputEventHandler: self.outputEventHandler.map { eventHandler in
                { data in
                    guard let validResponse: R = try? originalConverter(data.info, data.originalData) else {
                        return
                    }
                    
                    eventHandler(CachedResponse(
                        info: data.info,
                        originalData: data.originalData,
                        convertedData: validResponse
                    ))
                }
            },
            completionEventHandler: completionEventHandler,
            cancelEventHandler: cancelEventHandler,
            method: method,
            endpoint: endpoint,
            endpointName: endpointName,
            headers: headers,
            path: path,
            batchEndpoints: batchEndpoints,
            batchRequestVariant: batchRequestVariant,
            batchResponseTypes: batchResponseTypes,
            requireAllBatchResponses: requireAllBatchResponses,
            excludedSubRequestHeaders: excludedSubRequestHeaders,
            jsonKeyedBodyEncoder: jsonKeyedBodyEncoder,
            jsonBodyEncoder: jsonBodyEncoder,
            b64: b64,
            bytes: bytes
        )
    }
    
    func handleEvents(
        receiveSubscription: (() -> Void)? = nil,
        receiveOutput: (((ResponseInfoType, R)) -> Void)? = nil,
        receiveCompletion: ((Subscribers.Completion<Error>) -> Void)? = nil,
        receiveCancel: (() -> Void)? = nil
    ) -> Network.PreparedRequest<R> {
        let subscriptionHandler: (() -> Void)? = {
            switch (self.subscriptionHandler, receiveSubscription) {
                case (.none, .none): return nil
                case (.some(let eventHandler), .none): return eventHandler
                case (.none, .some(let eventHandler)): return eventHandler
                case (.some(let originalEventHandler), .some(let eventHandler)):
                    return {
                        originalEventHandler()
                        eventHandler()
                    }
            }
        }()
        let outputEventHandler: ((CachedResponse) -> Void)? = {
            switch (self.outputEventHandler, receiveOutput) {
                case (.none, .none): return nil
                case (.some(let eventHandler), .none): return eventHandler
                case (.none, .some(let eventHandler)):
                    return { data in
                        eventHandler((data.info, data.convertedData))
                    }
                    
                case (.some(let originalEventHandler), .some(let eventHandler)):
                    return { data in
                        originalEventHandler(data)
                        eventHandler((data.info, data.convertedData))
                    }
            }
        }()
        let completionEventHandler: ((Subscribers.Completion<Error>) -> Void)? = {
            switch (self.completionEventHandler, receiveCompletion) {
                case (.none, .none): return nil
                case (.some(let eventHandler), .none): return eventHandler
                case (.none, .some(let eventHandler)): return eventHandler
                case (.some(let originalEventHandler), .some(let eventHandler)):
                    return { result in
                        originalEventHandler(result)
                        eventHandler(result)
                    }
            }
        }()
        let cancelEventHandler: (() -> Void)? = {
            switch (self.cancelEventHandler, receiveCancel) {
                case (.none, .none): return nil
                case (.some(let eventHandler), .none): return eventHandler
                case (.none, .some(let eventHandler)): return eventHandler
                case (.some(let originalEventHandler), .some(let eventHandler)):
                    return {
                        originalEventHandler()
                        eventHandler()
                    }
            }
        }()
        
        return Network.PreparedRequest(
            body: body,
            destination: destination,
            additionalSignatureData: additionalSignatureData,
            originalType: originalType,
            responseType: responseType,
            retryCount: retryCount,
            requestTimeout: requestTimeout,
            requestAndPathBuildTimeout: requestAndPathBuildTimeout,
            cachedResponse: cachedResponse,
            responseConverter: responseConverter,
            subscriptionHandler: subscriptionHandler,
            outputEventHandler: outputEventHandler,
            completionEventHandler: completionEventHandler,
            cancelEventHandler: cancelEventHandler,
            method: method,
            endpoint: endpoint,
            endpointName: endpointName,
            headers: headers,
            path: path,
            batchEndpoints: batchEndpoints,
            batchRequestVariant: batchRequestVariant,
            batchResponseTypes: batchResponseTypes,
            requireAllBatchResponses: requireAllBatchResponses,
            excludedSubRequestHeaders: excludedSubRequestHeaders,
            jsonKeyedBodyEncoder: jsonKeyedBodyEncoder,
            jsonBodyEncoder: jsonBodyEncoder,
            b64: b64,
            bytes: bytes
        )
    }
}

// MARK: - Response

public extension Network.PreparedRequest {
    static func cached<E: EndpointType>(
        _ cachedResponse: R,
        endpoint: E,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<R> where R: Codable {
        return Network.PreparedRequest(
            body: nil,
            destination: try .cached(
                response: cachedResponse,
                using: dependencies
            ),
            additionalSignatureData: nil,
            originalType: R.self,
            responseType: R.self,
            retryCount: 0,
            requestTimeout: 0,
            requestAndPathBuildTimeout: nil,
            cachedResponse: Network.PreparedRequest<R>.CachedResponse(
                info: Network.ResponseInfo(code: 0, headers: [:]),
                originalData: cachedResponse,
                convertedData: cachedResponse
            ),
            responseConverter: { _, _ in cachedResponse },
            subscriptionHandler: nil,
            outputEventHandler: nil,
            completionEventHandler: nil,
            cancelEventHandler: nil,
            method: .get,
            endpoint: endpoint,
            endpointName: E.name,
            headers: [:],
            path: "",
            batchEndpoints: [],
            batchRequestVariant: .unsupported,
            batchResponseTypes: [],
            requireAllBatchResponses: false,
            excludedSubRequestHeaders: [],
            jsonKeyedBodyEncoder: nil,
            jsonBodyEncoder: nil,
            b64: nil,
            bytes: nil
        )
    }
}

// MARK: - Network.PreparedRequest<R>.CachedResponse

public extension Publisher where Failure == Error {
    func eraseToAnyPublisher<R>() -> AnyPublisher<(ResponseInfoType, R), Error> where Output == Network.PreparedRequest<R>.CachedResponse {
        return self
            .map { ($0.info, $0.convertedData) }
            .eraseToAnyPublisher()
    }
}

// MARK: - Decoding

public extension Decodable {
    fileprivate static func from(_ value: Any?) -> Self? {
        return (value as? Self)
    }
    
    static func decoded(from data: Data, using dependencies: Dependencies) throws -> Self {
        return try data.decoded(as: Self.self, using: dependencies)
    }
}

public extension Publisher where Output == (ResponseInfoType, Data?), Failure == Error {
    func decoded<R>(
        with preparedRequest: Network.PreparedRequest<R>,
        using dependencies: Dependencies
    ) -> AnyPublisher<Network.PreparedRequest<R>.CachedResponse, Error> {
        self
            .tryMap { responseInfo, maybeData -> Network.PreparedRequest<R>.CachedResponse in
                // Depending on the 'originalType' we need to process the response differently
                let targetData: Any = try {
                    switch preparedRequest.originalType {
                        case let erasedBatchResponse as ErasedBatchResponseMap.Type:
                            let response: Network.BatchResponse = try Network.BatchResponse.decodingResponses(
                                from: maybeData,
                                as: preparedRequest.batchResponseTypes,
                                requireAllResults: preparedRequest.requireAllBatchResponses,
                                using: dependencies
                            )
                            
                            return try erasedBatchResponse.from(
                                batchEndpoints: preparedRequest.batchEndpoints,
                                response: response
                            )
                        
                        case is Network.BatchResponse.Type:
                            return try Network.BatchResponse.decodingResponses(
                                from: maybeData,
                                as: preparedRequest.batchResponseTypes,
                                requireAllResults: preparedRequest.requireAllBatchResponses,
                                using: dependencies
                            )
                            
                        case is NoResponse.Type: return NoResponse()
                        case is Optional<Data>.Type: return maybeData as Any
                        case is Data.Type: return try maybeData ?? { throw NetworkError.parsingFailed }()
                        
                        case is _OptionalProtocol.Type:
                            guard let data: Data = maybeData else { return maybeData as Any }
                            
                            return try preparedRequest.originalType.decoded(from: data, using: dependencies)
                        
                        default:
                            guard let data: Data = maybeData else { throw NetworkError.parsingFailed }
                            
                            return try preparedRequest.originalType.decoded(from: data, using: dependencies)
                    }
                }()
                
                // Generate and return the converted data
                return Network.PreparedRequest<R>.CachedResponse(
                    info: responseInfo,
                    originalData: targetData,
                    convertedData: try preparedRequest.responseConverter(responseInfo, targetData)
                )
            }
            .eraseToAnyPublisher()
    }
}

// MARK: - _OptionalProtocol

/// This protocol should only be used within this file and is used to distinguish between `Any.Type` and `Optional<Any>.Type` as
/// it seems that `is Optional<Any>.Type` doesn't work nicely but this protocol works nicely as long as the case is under any explicit
/// `Optional<T>` handling that we need
private protocol _OptionalProtocol {}

extension Optional: _OptionalProtocol {}
