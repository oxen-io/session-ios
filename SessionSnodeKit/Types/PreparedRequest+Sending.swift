// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

public extension Network.PreparedRequest {
    func send(using dependencies: Dependencies) -> AnyPublisher<(ResponseInfoType, R), Error> {
        return dependencies[singleton: .network]
            .send(body, to: destination, requestTimeout: requestTimeout, requestAndPathBuildTimeout: requestAndPathBuildTimeout)
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
    func send<R>(using dependencies: Dependencies) -> AnyPublisher<(ResponseInfoType, R), Error> where Wrapped == Network.PreparedRequest<R> {
        guard let instance: Wrapped = self else {
            return Fail(error: NetworkError.invalidPreparedRequest)
                .eraseToAnyPublisher()
        }
        
        return instance.send(using: dependencies)
    }
}
