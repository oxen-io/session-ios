// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

@testable import SessionSnodeKit

extension NoResponse: Mocked {
    static var mock: NoResponse = NoResponse()
}

extension Network.BatchSubResponse: MockedGeneric where T: Mocked {
    typealias Generic = T
    
    static func mock(type: T.Type) -> Network.BatchSubResponse<T> {
        return Network.BatchSubResponse(
            code: 200,
            headers: [:],
            body: Generic.mock,
            failedToParseBody: false
        )
    }
}

extension Network.BatchSubResponse {
    static func mockArrayValue<M: Mocked>(type: M.Type) -> Network.BatchSubResponse<Array<M>> {
        return Network.BatchSubResponse(
            code: 200,
            headers: [:],
            body: [M.mock],
            failedToParseBody: false
        )
    }
}

extension Network.Destination: Mocked {
    static var mock: Network.Destination = try! Network.Destination.server(
        server: "testServer",
        headers: [:],
        x25519PublicKey: ""
    ).withGeneratedUrl(for: MockEndpoint.mock)
}
