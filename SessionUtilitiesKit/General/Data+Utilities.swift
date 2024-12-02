// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public extension Data {
    func appending(_ other: Data) -> Data {
        var mutableData: Data = Data()
        mutableData.append(self)
        mutableData.append(other)
        
        return mutableData
    }
    
    func appending(_ other: [UInt8]) -> Data {
        var mutableData: Data = Data()
        mutableData.append(self)
        mutableData.append(contentsOf: other)
        
        return mutableData
    }
}
