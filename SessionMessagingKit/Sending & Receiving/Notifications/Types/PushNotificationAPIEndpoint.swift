// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionSnodeKit
import SessionUtilitiesKit

public extension PushNotificationAPI {
    enum Endpoint: EndpointType {
        case subscribe
        case unsubscribe
        
        // MARK: - Legacy Endpoints
        
        case legacyNotify
        case legacyRegister
        case legacyUnregister
        case legacyGroupsOnlySubscribe
        case legacyGroupSubscribe
        case legacyGroupUnsubscribe
        
        public static var name: String { "PushNotificationAPI.Endpoint" }
        
        public var path: String {
            switch self {
                case .subscribe: return "subscribe"
                case .unsubscribe: return "unsubscribe"
                    
                // Legacy Endpoints
                case .legacyNotify: return "notify"
                case .legacyRegister: return "register"
                case .legacyUnregister: return "unregister"
                case .legacyGroupsOnlySubscribe: return "register_legacy_groups_only"
                case .legacyGroupSubscribe: return "subscribe_closed_group"
                case .legacyGroupUnsubscribe: return "unsubscribe_closed_group"
            }
        }
        
        // MARK: - Convenience
        
        func server(using dependencies: Dependencies) -> String {
            switch self {
                case .legacyNotify, .legacyRegister, .legacyUnregister,
                    .legacyGroupsOnlySubscribe, .legacyGroupSubscribe, .legacyGroupUnsubscribe:
                    return PushNotificationAPI.legacyServer
                    
                default: return PushNotificationAPI.server.value(using: dependencies)
            }
        }
        
        var serverPublicKey: String {
            switch self {
                case .legacyNotify, .legacyRegister, .legacyUnregister,
                    .legacyGroupsOnlySubscribe, .legacyGroupSubscribe, .legacyGroupUnsubscribe:
                    return PushNotificationAPI.legacyServerPublicKey
                    
                default: return PushNotificationAPI.serverPublicKey
            }
        }
    }
}
