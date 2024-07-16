// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionSnodeKit

public extension HTTPQueryParam {
    static let publicKey: HTTPQueryParam = "public_key"
    static let fromServerId: HTTPQueryParam = "from_server_id"
    
    static let required: HTTPQueryParam = "required"
    
    /// For messages - number between 1 and 256 (default is 100)
    static let limit: HTTPQueryParam = "limit"
    
    /// For file server session version check
    static let platform: HTTPQueryParam = "platform"
    
    /// String indicating the types of updates that the client supports
    static let updateTypes: HTTPQueryParam = "t"
    static let reactors: HTTPQueryParam = "reactors"
}
