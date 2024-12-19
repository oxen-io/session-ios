// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

class MockCrypto: Mock<CryptoType>, CryptoType {
    func tryGenerate<R>(_ generator: Crypto.Generator<R>) throws -> R {
        return try mockThrowing(funcName: "generate<\(R.self)>(\(generator.id))", args: generator.args)
    }
    
    func verify(_ verification: Crypto.Verification) -> Bool {
        return mock(funcName: "verify(\(verification.id))", args: verification.args)
    }
}
