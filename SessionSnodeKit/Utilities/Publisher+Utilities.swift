// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

// MARK: - Data Decoding

public extension Publisher where Output == Data, Failure == Error {
    func decoded<R: Decodable>(
        as type: R.Type,
        using dependencies: Dependencies
    ) -> AnyPublisher<R, Failure> {
        self
            .tryMap { data -> R in try data.decoded(as: type, using: dependencies) }
            .eraseToAnyPublisher()
    }
}

public extension Publisher where Output == (ResponseInfoType, Data?), Failure == Error {
    func decoded<R: Decodable>(
        as type: R.Type,
        using dependencies: Dependencies
    ) -> AnyPublisher<(ResponseInfoType, R), Error> {
        self
            .tryMap { responseInfo, maybeData -> (ResponseInfoType, R) in
                guard let data: Data = maybeData else { throw NetworkError.parsingFailed }
                
                return (responseInfo, try data.decoded(as: type, using: dependencies))
            }
            .eraseToAnyPublisher()
    }
}
