// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionSnodeKit

public extension HTTPHeader {
    static let sogsPubKey: HTTPHeader = "X-SOGS-Pubkey"
    static let sogsNonce: HTTPHeader = "X-SOGS-Nonce"
    static let sogsTimestamp: HTTPHeader = "X-SOGS-Timestamp"
    static let sogsSignature: HTTPHeader = "X-SOGS-Signature"
}
