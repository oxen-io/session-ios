// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public class SnodeRecursiveResponse<T: SnodeSwarmItem>: SnodeResponse {
    private enum CodingKeys: String, CodingKey {
        case swarm
    }
    
    internal let swarm: [String: T]
    
    // MARK: - Initialization
    
    internal init(
        swarm: [String: T],
        hardFork: [Int],
        timeOffset: Int64
    ) {
        self.swarm = swarm
        
        super.init(hardForkVersion: hardFork, timeOffset: timeOffset)
    }
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        swarm = try container.decode([String: T].self, forKey: .swarm)
        
        try super.init(from: decoder)
    }
}
