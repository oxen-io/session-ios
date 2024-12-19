// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public class SnodeResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case hardForkVersion = "hf"
        case timeOffset = "t"
    }
    
    internal let hardForkVersion: [Int]
    internal let timeOffset: Int64
    
    // MARK: - Initialization
    
    internal init(hardForkVersion: [Int], timeOffset: Int64) {
        self.hardForkVersion = hardForkVersion
        self.timeOffset = timeOffset
    }
}
