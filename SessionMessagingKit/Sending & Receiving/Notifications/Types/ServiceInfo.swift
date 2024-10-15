// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension PushNotificationAPI {
    struct ServiceInfo: Codable {
        private enum CodingKeys: String, CodingKey {
            case token
        }
        
        private let token: String
        
        // MARK: - Initialization
        
        init(token: String) {
            self.token = token
        }
    }
}
