// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension Network {
    enum Destination: Equatable {
        case snode(LibSession.Snode)
        case server(
            url: URL,
            method: HTTPMethod,
            headers: [HTTPHeader: String]?,
            x25519PublicKey: String
        )
    }
}
