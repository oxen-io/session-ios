// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension PushNotificationAPI {
    struct LegacyPushServerResponse: Codable {
        let code: Int
        let message: String?
    }
}
