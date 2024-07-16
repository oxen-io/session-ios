// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension PushNotificationAPI {
    struct SubscribeResponse: Codable {
        struct SubResponse: Codable {
            /// Flag indicating the success of the registration
            let success: Bool?
            
            /// Value is `true` upon an initial registration
            let added: Bool?
            
            /// Value is `true` upon a renewal/update registration
            let updated: Bool?
            
            /// This will be one of the errors found here:
            /// https://github.com/jagerman/session-push-notification-server/blob/spns-v2/spns/hive/subscription.hpp#L21
            ///
            /// Values at the time of writing are:
            /// OK = 0                                           // Great Success!
            /// BAD_INPUT = 1                            // Unparseable, invalid values, missing required arguments, etc. (details in the string)
            /// SERVICE_NOT_AVAILABLE = 2   // The requested service name isn't currently available
            /// SERVICE_TIMEOUT = 3               // The backend service did not response
            /// ERROR = 4                                   // There was some other error processing the subscription (details in the string)
            /// INTERNAL_ERROR = 5                // An internal program error occured processing the request
            let error: Int?
            
            /// Includes additional information about the error
            let message: String?
        }
        
        let subResponses: [SubResponse]
        
        public init(from decoder: Decoder) throws {
            guard
                let container: SingleValueDecodingContainer = try? decoder.singleValueContainer(),
                let subResponses: [SubResponse] = try? container.decode([SubResponse].self)
            else {
                self.subResponses = [try SubResponse(from: decoder)]
                return
            }
            
            self.subResponses = subResponses
        }
    }
}
