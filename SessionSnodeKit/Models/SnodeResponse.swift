// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public class SnodeResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case hardFork = "hf"
        case timeOffset = "t"
    }
    
    internal let hardFork: [Int]
    internal let timeOffset: Int64
    
    // MARK: - Initialization
    
    internal init(hardFork: [Int], timeOffset: Int64) {
        self.hardFork = hardFork
        self.timeOffset = timeOffset
    }
}
