// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

class MockCrypto: Mock<CryptoType>, CryptoType {
    func tryGenerate<R>(_ generator: Crypto.Generator<R>) throws -> R {
        return try (
            accept(funcName: "tryGenerate(\(generator.id))", args: generator.args) as? R ??
            { throw CryptoError.failedToGenerateOutput }()
        )
    }
    
    func verify(_ verification: Crypto.Verification) -> Bool {
        return accept(funcName: "verify(\(verification.id))", args: verification.args) as! Bool
    }
}
