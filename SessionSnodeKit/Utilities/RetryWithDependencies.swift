// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

extension Publishers {
    struct RetryWithDependencies<Upstream: Publisher>: Publisher {
        typealias Output = Upstream.Output
        typealias Failure = Upstream.Failure
        
        let upstream: Upstream
        let retries: Int
        let dependencies: Dependencies
                
        func receive<S>(subscriber: S) where S : Subscriber, Failure == S.Failure, Output == S.Input {
            upstream
                .catch { [upstream, retries, dependencies] error -> AnyPublisher<Output, Failure> in
                    guard retries > 0 else { return Fail(error: error).eraseToAnyPublisher() }
                    
                    // If we got any of the following errors then we shouldn't bother retrying (the request
                    // isn't going to work)
                    switch error as Error {
                        case NetworkError.suspended: return Fail(error: error).eraseToAnyPublisher()
                        default: break
                    }
                    
                    return RetryWithDependencies(upstream: upstream, retries: retries - 1, dependencies: dependencies)
                        .eraseToAnyPublisher()
                }
                .receive(subscriber: subscriber)
        }
    }
}

public extension Publisher {
    func retry(_ retries: Int, using dependencies: Dependencies) -> AnyPublisher<Output, Failure> {
        guard retries > 0 else { return self.eraseToAnyPublisher() }
        guard !dependencies.forceSynchronous else {
            return Publishers.RetryWithDependencies(upstream: self, retries: retries, dependencies: dependencies)
                .eraseToAnyPublisher()
        }
        
        return self.retry(retries).eraseToAnyPublisher()
    }
}
