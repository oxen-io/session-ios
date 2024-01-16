// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Authentication Types

public extension Authentication {
    /// Used for when interacting as the current user
    struct standard: AuthenticationMethod {
        public let sessionId: SessionId
        public let ed25519KeyPair: KeyPair
        
        public var info: Info { .standard(sessionId: sessionId, ed25519KeyPair: ed25519KeyPair) }
        
        // MARK: - SignatureGenerator
        
        public func generateSignature(with verificationBytes: [UInt8], using dependencies: Dependencies) throws -> Authentication.Signature {
            return try dependencies[singleton: .crypto].tryGenerate(
                .signature(message: verificationBytes, ed25519SecretKey: ed25519KeyPair.secretKey)
            )
        }
    }
    
    /// Used for when interacting as a group admin
    struct groupAdmin: AuthenticationMethod {
        public let groupSessionId: SessionId
        public let ed25519SecretKey: [UInt8]
        
        public var info: Info { .groupAdmin(groupSessionId: groupSessionId, ed25519SecretKey: ed25519SecretKey) }
        
        public init(groupSessionId: SessionId, ed25519SecretKey: [UInt8]) {
            self.groupSessionId = groupSessionId
            self.ed25519SecretKey = ed25519SecretKey
        }
        
        // MARK: - SignatureGenerator
        
        public func generateSignature(with verificationBytes: [UInt8], using dependencies: Dependencies) throws -> Authentication.Signature {
            return try dependencies[singleton: .crypto].tryGenerate(
                .signature(message: verificationBytes, ed25519SecretKey: ed25519SecretKey)
            )
        }
    }

    /// Used for when interacting as a group member
    struct groupMember: AuthenticationMethod {
        public let groupSessionId: SessionId
        public let authData: Data
        
        public var info: Info { .groupMember(groupSessionId: groupSessionId, authData: authData) }
        
        public init(groupSessionId: SessionId, authData: Data) {
            self.groupSessionId = groupSessionId
            self.authData = authData
        }
        
        // MARK: - SignatureGenerator
        
        public func generateSignature(with verificationBytes: [UInt8], using dependencies: Dependencies) throws -> Authentication.Signature {
            return try LibSession.generateSubaccountSignature(
                groupSessionId: groupSessionId,
                verificationBytes: verificationBytes,
                memberAuthData: authData,
                using: dependencies
            )
        }
    }
}

// MARK: - Convenience

fileprivate struct GroupAuthData: Codable, FetchableRecord {
    let groupIdentityPrivateKey: Data?
    let authData: Data?
}

public extension Authentication {
    static func with(
        _ db: Database,
        sessionIdHexString: String,
        using dependencies: Dependencies
    ) throws -> AuthenticationMethod {
        switch try? SessionId(from: sessionIdHexString) {
            case .some(let sessionId) where sessionId.prefix == .standard:
                guard let keyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db, using: dependencies) else {
                    throw SnodeAPIError.noKeyPair
                }
                
                return Authentication.standard(sessionId: sessionId, ed25519KeyPair: keyPair)
                
            case .some(let sessionId) where sessionId.prefix == .group:
                let authData: GroupAuthData? = try? ClosedGroup
                    .filter(id: sessionIdHexString)
                    .select(.authData, .groupIdentityPrivateKey)
                    .asRequest(of: GroupAuthData.self)
                    .fetchOne(db)
                
                switch (authData?.groupIdentityPrivateKey, authData?.authData) {
                    case (.some(let privateKey), _):
                        return Authentication.groupAdmin(
                            groupSessionId: sessionId,
                            ed25519SecretKey: Array(privateKey)
                        )
                        
                    case (_, .some(let authData)):
                        return Authentication.groupMember(
                            groupSessionId: sessionId,
                            authData: authData
                        )
                        
                    default: throw SnodeAPIError.invalidAuthentication
                }
                
            default: throw SnodeAPIError.invalidAuthentication
        }
    }
}
