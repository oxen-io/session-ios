// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension SnodeAPI {
    public class ONSResolveResponse: SnodeResponse {
        internal struct Result: Codable {
            enum CodingKeys: String, CodingKey {
                case nonce
                case encryptedValue = "encrypted_value"
            }
            
            internal let nonce: String?
            internal let encryptedValue: String
        }
        
        enum CodingKeys: String, CodingKey {
            case result
        }
        
        internal let result: Result
        
        // MARK: - Initialization
        
        required init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            result = try container.decode(Result.self, forKey: .result)
            
            try super.init(from: decoder)
        }
    }
}
