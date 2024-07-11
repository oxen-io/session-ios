// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum IPv4 {
    
    public static func toInt(_ ip: String) -> Int? {
        let octets: [Int] = ip.split(separator: ".").map { Int($0)! }
        var result: Int = 0
        for i in stride(from: 3, through: 0, by: -1) {
            result += octets[ 3 - i ] << (i * 8)
        }
        
        guard result > 0 else { return nil }
        
        return result
    }
}
