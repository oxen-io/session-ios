// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public class GetExpiriesResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case expiries
    }
    
    public let expiries: [String: UInt64]
    
    // MARK: - Initialization
    
    required public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        expiries = ((try? container.decode([String: UInt64].self, forKey: .expiries)) ?? [:])
    }
}
