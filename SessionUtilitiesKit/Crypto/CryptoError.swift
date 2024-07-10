// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum CryptoError: Error {
    case invalidSeed
    case keyGenerationFailed
    case randomGenerationFailed
    case signatureGenerationFailed
    case signatureVerificationFailed
    case encryptionFailed
    case decryptionFailed
    case failedToGenerateOutput
}
