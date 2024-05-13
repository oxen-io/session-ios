// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

public extension Network.PreparedRequest {
    /// Send an onion request for the prepared data
    func send(using dependencies: Dependencies) -> AnyPublisher<(ResponseInfoType, R), Error> {
        // If we have a cached response then user that directly
        if let cachedResponse: Network.PreparedRequest<R>.CachedResponse = self.cachedResponse {
            return Just(cachedResponse)
                .setFailureType(to: Error.self)
                .handleEvents(
                    receiveSubscription: { _ in self.subscriptionHandler?() },
                    receiveOutput: self.outputEventHandler,
                    receiveCompletion: self.completionEventHandler,
                    receiveCancel: self.cancelEventHandler
                )
                .eraseToAnyPublisher()
        }
        
        // Otherwise trigger the request
        return Just(())
            .setFailureType(to: Error.self)
            .tryFlatMap { _ in
                switch target {
                    case let serverTarget as any ServerRequestTarget:
                        return dependencies.network
                            .send(
                                .onionRequest(
                                    request,
                                    to: serverTarget.server,
                                    with: serverTarget.x25519PublicKey,
                                    timeout: timeout
                                ),
                                using: dependencies
                            )
                        
                    case let snodeTarget as Network.SnodeTarget:
                        guard let payload: Data = request.httpBody else { throw NetworkError.invalidPreparedRequest }

                        return dependencies.network
                            .send(
                                .onionRequest(
                                    payload,
                                    to: snodeTarget.snode,
                                    swarmPublicKey: snodeTarget.swarmPublicKey,
                                    timeout: timeout
                                ),
                                using: dependencies
                            )
                        
                    case let randomTarget as Network.RandomSnodeTarget:
                        guard let payload: Data = request.httpBody else { throw NetworkError.invalidPreparedRequest }

                        return LibSession.getSwarm(swarmPublicKey: randomTarget.swarmPublicKey)
                            .tryFlatMapWithRandomSnode(retry: randomTarget.retryCount, using: dependencies) { snode in
                                dependencies.network
                                    .send(
                                        .onionRequest(
                                            payload,
                                            to: snode,
                                            swarmPublicKey: randomTarget.swarmPublicKey,
                                            timeout: timeout
                                        ),
                                        using: dependencies
                                    )
                            }
                        
                    case let randomTarget as Network.RandomSnodeLatestNetworkTimeTarget:
                        guard request.httpBody != nil else { throw NetworkError.invalidPreparedRequest }
                        
                        return LibSession.getSwarm(swarmPublicKey: randomTarget.swarmPublicKey)
                            .tryFlatMapWithRandomSnode(retry: randomTarget.retryCount, using: dependencies) { snode in
                                SnodeAPI
                                    .getNetworkTime(from: snode, using: dependencies)
                                    .tryFlatMap { timestampMs in
                                        guard
                                            let updatedRequest: URLRequest = try? randomTarget
                                                .urlRequestWithUpdatedTimestampMs(timestampMs, dependencies),
                                            let payload: Data = updatedRequest.httpBody
                                        else { throw NetworkError.invalidPreparedRequest }
                                        
                                        return dependencies.network
                                            .send(
                                                .onionRequest(
                                                    payload,
                                                    to: snode,
                                                    swarmPublicKey: randomTarget.swarmPublicKey,
                                                    timeout: timeout
                                                ),
                                                using: dependencies
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
                        
                    default: throw NetworkError.invalidPreparedRequest
                }
            }
            .decoded(with: self, using: dependencies)
            .retry(retryCount, using: dependencies)
            .handleEvents(
                receiveSubscription: { _ in self.subscriptionHandler?() },
                receiveOutput: self.outputEventHandler,
                receiveCompletion: self.completionEventHandler,
                receiveCancel: self.cancelEventHandler
            )
            .eraseToAnyPublisher()
    }
}

public extension Optional {
    func send<R>(
        using dependencies: Dependencies
    ) -> AnyPublisher<(ResponseInfoType, R), Error> where Wrapped == Network.PreparedRequest<R> {
        guard let instance: Wrapped = self else {
            return Fail(error: NetworkError.invalidPreparedRequest)
                .eraseToAnyPublisher()
        }
        
        return instance.send(using: dependencies)
    }
}
