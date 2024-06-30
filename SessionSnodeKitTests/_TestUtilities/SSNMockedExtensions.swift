// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionSnodeKit
import SessionUtilitiesKit

extension Network.Destination: Mocked {
    static var mockValue: Network.Destination = Network.Destination.server(
        url: URL(string: "https://oxen.io")!,
        method: .get,
        headers: nil,
        x25519PublicKey: ""
    )
}
