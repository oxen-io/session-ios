// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public struct KeyPair: Codable, Equatable {
    public static let empty: KeyPair = KeyPair(publicKey: [], secretKey: [])
    
    public let publicKey: [UInt8]
    public let secretKey: [UInt8]
    
    // MARK: - Initialization

    public init(publicKey: [UInt8], secretKey: [UInt8]) {
        self.publicKey = publicKey
        self.secretKey = secretKey
    }
    
    // MARK: - Functions
    
    public static func isValidHexEncodedPublicKey(candidate: String) -> Bool {
        // Note: If the logic in here changes ensure it doesn't break `SessionId.Prefix(from:)`
        // Check that it's a valid hexadecimal encoding
        guard Hex.isValid(candidate) else { return false }
        
        // Check that it has length 66 and a valid prefix
        guard candidate.count == 66 && SessionId.Prefix.allCases.first(where: { candidate.hasPrefix($0.rawValue) }) != nil else {
            return false
        }
        
        // It appears to be a valid public key
        return true
    }
}
