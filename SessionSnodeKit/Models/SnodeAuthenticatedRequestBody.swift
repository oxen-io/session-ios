// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public class SnodeAuthenticatedRequestBody: Encodable {
    private enum CodingKeys: String, CodingKey {
        case pubkey
        case subkey
        case timestampMs = "timestamp"
        case ed25519PublicKey = "pubkey_ed25519"
        case signatureBase64 = "signature"
    }
    
    internal let pubkey: String
    internal let ed25519PublicKey: [UInt8]
    internal let ed25519SecretKey: [UInt8]
    private let subkey: String?
    internal let timestampMs: UInt64?
    
    // MARK: - Initialization

    public init(
        pubkey: String,
        ed25519PublicKey: [UInt8],
        ed25519SecretKey: [UInt8],
        subkey: String? = nil,
        timestampMs: UInt64? = nil
    ) {
        self.pubkey = pubkey
        self.ed25519PublicKey = ed25519PublicKey
        self.ed25519SecretKey = ed25519SecretKey
        self.subkey = subkey
        self.timestampMs = timestampMs
    }
    
    // MARK: - Codable
    
    public func encode(to encoder: Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        // Generate the signature for the request for encoding
        let signatureBase64: String = try generateSignature().toBase64()
        try container.encode(pubkey, forKey: .pubkey)
        try container.encodeIfPresent(subkey, forKey: .subkey)
        try container.encodeIfPresent(timestampMs, forKey: .timestampMs)
        try container.encode(ed25519PublicKey.toHexString(), forKey: .ed25519PublicKey)
        try container.encode(signatureBase64, forKey: .signatureBase64)
    }
    
    // MARK: - Abstract Functions
    
    func generateSignature() throws -> [UInt8] {
        preconditionFailure("abstract class - override in subclass")
    }
}
