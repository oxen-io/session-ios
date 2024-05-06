// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public enum Authentication {}
public protocol AuthenticationMethod: SignatureGenerator {
    var info: Authentication.Info { get }
}

public extension AuthenticationMethod {
    var sessionId: SessionId {
        switch info {
            case .standard(let sessionId, _), .groupAdmin(let sessionId, _), .groupMember(let sessionId, _):
                return sessionId
        }
    }
}

// MARK: - SignatureGenerator

public protocol SignatureGenerator {
    func generateSignature(
        with verificationBytes: [UInt8],
        using dependencies: Dependencies
    ) throws -> Authentication.Signature
}

// MARK: - Signature Verification

public extension Authentication {
    static func verify(
        signature: Authentication.Signature,
        publicKey: [UInt8],
        verificationBytes: [UInt8],
        using dependencies: Dependencies
    ) -> Bool {
        switch signature {
            case .standard(let signature):
                return dependencies[singleton: .crypto].verify(
                    .signature(message: verificationBytes, publicKey: publicKey, signature: signature)
                )
                
            // Currently we never sign anything with a subaccount which requires verification
            case .subaccount: return false
        }
    }
}

// MARK: - Authentication.Info

public extension Authentication {
    enum Info: Equatable {
        /// Used for when interacting as the current user
        case standard(sessionId: SessionId, ed25519KeyPair: KeyPair)
        
        /// Used for when interacting as a group admin
        case groupAdmin(groupSessionId: SessionId, ed25519SecretKey: [UInt8])
        
        /// Used for when interacting as a group member
        case groupMember(groupSessionId: SessionId, authData: Data)
    }
}

// MARK: - Authentication.Signature

public extension Authentication {
    enum Signature: Equatable, CustomStringConvertible {
        /// Used for signing standard requests
        case standard(signature: [UInt8])
        
        /// Used for signing standard requests
        case subaccount(subaccount: [UInt8], subaccountSig: [UInt8], signature: [UInt8])
        
        // MARK: - CustomStringConvertible
        
        public var description: String {
            switch self {
                case .standard(let signature):
                    return """
                    standard(
                        signature: \(signature.toHexString())
                    )
                    """
                    
                case .subaccount(let subaccount, let subaccountSig, let signature):
                    return """
                    subaccount(
                        subaccount: \(subaccount.toHexString()),
                        subaccountSig: \(subaccountSig.toHexString()),
                        signature: \(signature.toHexString())
                    )
                    """
            }
        }
    }
}
