// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

@testable import SessionSnodeKit

extension Snode: Mocked {
    static var mock: Snode = Snode(
        address: "test",
        port: 0,
        ed25519PublicKey: TestConstants.edPublicKey,
        x25519PublicKey: TestConstants.publicKey
    )
}
