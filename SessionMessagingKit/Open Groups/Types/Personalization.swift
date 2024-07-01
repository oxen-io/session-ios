// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension OpenGroupAPI {
    public enum Personalization: String {
        case sharedKeys = "sogs.shared_keys"
        case authHeader = "sogs.auth_header"
        
        var bytes: [UInt8] {
            return Array(self.rawValue.utf8)
        }
    }
}
