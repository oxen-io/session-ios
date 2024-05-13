// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension SnodeAPI {
    enum Endpoint: EndpointType {
        case sendMessage
        case getMessages
        case deleteMessages
        case deleteAll
        case deleteAllBefore
        case revokeSubaccount
        case unrevokeSubaccount
        case expire
        case expireAll
        case getExpiries
        case batch
        case sequence
        
        case getInfo
        case getSwarm
        
        case jsonRPCCall
        case oxenDaemonRPCCall
        
        // jsonRPCCall proxied calls
        
        case jsonGetServiceNodes
        
        // oxenDaemonRPCCall proxied calls
        
        case daemonOnsResolve
        case daemonGetServiceNodes
        
        public static var name: String { "SnodeAPI.Endpoint" }
        public static var batchRequestVariant: Network.BatchRequest.Child.Variant = .storageServer
        
        public var path: String {
            switch self {
                case .sendMessage: return "store"
                case .getMessages: return "retrieve"
                case .deleteMessages: return "delete"
                case .deleteAll: return "delete_all"
                case .deleteAllBefore: return "delete_before"
                case .revokeSubaccount: return "revoke_subaccount"
                case .unrevokeSubaccount: return "unrevoke_subaccount"
                case .expire: return "expire"
                case .expireAll: return "expire_all"
                case .getExpiries: return "get_expiries"
                case .batch: return "batch"
                case .sequence: return "sequence"
                
                case .getInfo: return "info"
                case .getSwarm: return "get_swarm"
                
                case .jsonRPCCall: return "json_rpc"
                case .oxenDaemonRPCCall: return "oxend_request"
                
                // jsonRPCCall proxied calls
                
                case .jsonGetServiceNodes: return "get_service_nodes"
                
                // oxenDaemonRPCCall proxied calls
                
                case .daemonOnsResolve: return "ons_resolve"
                case .daemonGetServiceNodes: return "get_service_nodes"
            }
        }
    }
}
