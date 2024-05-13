// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public extension Dependencies {
    static let userInfoKey: CodingUserInfoKey = CodingUserInfoKey(rawValue: "io.oxen.dependencies.codingOptions")!
}

public extension Data {
    func decoded<T: Decodable>(as type: T.Type, using dependencies: Dependencies = Dependencies()) throws -> T {
        do {
            let decoder: JSONDecoder = JSONDecoder()
            decoder.userInfo = [ Dependencies.userInfoKey: dependencies ]
            
            return try decoder.decode(type, from: self)
        }
        catch { throw NetworkError.parsingFailed }
    }

    func removingIdPrefixIfNeeded() -> Data {
        var result = self
        if result.count == 33 && SessionId.Prefix(from: result.toHexString()) != nil { result.removeFirst() }
        return result
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

@objc public extension NSData {
    
    @objc func removingIdPrefixIfNeeded() -> NSData {
        var result = self as Data
        if result.count == 33 && SessionId.Prefix(from: result.toHexString()) != nil { result.removeFirst() }
        return result as NSData
    }
}
