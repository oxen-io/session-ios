// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Data {
    func decoded<T: Decodable>(as type: T.Type, using dependencies: Dependencies = Dependencies()) throws -> T {
        do { return try JSONDecoder(using: dependencies).decode(type, from: self) }
        catch { throw HTTPError.parsingFailed }
    }
    
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
