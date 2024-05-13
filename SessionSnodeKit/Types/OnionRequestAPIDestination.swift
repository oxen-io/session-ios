// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public enum OnionRequestAPIDestination: CustomStringConvertible {
    case snode(LibSession.Snode)
    case server(
        method: String?,
        scheme: String?,
        host: String,
        endpoint: String,
        port: UInt16?,
        headers: [HTTPHeader: String]?,
        x25519PublicKey: String
    )
    
    public var description: String {
        switch self {
            case .snode(let snode): return "Service node \(snode.address)"
            case .server(_, _, let host, _, _, _, _): return host
        }
    }
}
