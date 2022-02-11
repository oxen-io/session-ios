// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

enum QueryParam: String {
    case publicKey = "public_key"
    case fromServerId = "from_server_id"
    
    case required = "required"
    case fileName = "X-Filename"
    case limit                      // For messages - number between 1 and 256 (default is 100)
}
