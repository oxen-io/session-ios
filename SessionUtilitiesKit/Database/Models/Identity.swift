// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public struct Identity: Codable, Identifiable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "identity" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case variant
        case data
    }
    
    public enum Variant: String, Codable, CaseIterable, DatabaseValueConvertible {
        case ed25519SecretKey
        case ed25519PublicKey
        case x25519PrivateKey
        case x25519PublicKey
    }
    
    public var id: Variant { variant }
    
    public let variant: Variant
    public let data: Data
    
    // MARK: - Initialization
    
    public init(
        variant: Variant,
        data: Data
    ) {
        self.variant = variant
        self.data = data
    }
}

// MARK: - GRDB Interactions

public extension Identity {
    static func generate(
        from seed: Data,
        using dependencies: Dependencies = Dependencies()
    ) throws -> (ed25519KeyPair: KeyPair, x25519KeyPair: KeyPair) {
        guard (seed.count == 16) else { throw CryptoError.invalidSeed }

        let padding = Data(repeating: 0, count: 16)
        
        guard
            let ed25519KeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                .ed25519KeyPair(seed: Array(seed + padding))
            ),
            let x25519PublicKey: [UInt8] = dependencies[singleton: .crypto].generate(
                .x25519(ed25519Pubkey: ed25519KeyPair.publicKey)
            ),
            let x25519SecretKey: [UInt8] = dependencies[singleton: .crypto].generate(
                .x25519(ed25519Seckey: ed25519KeyPair.secretKey)
            )
        else { throw CryptoError.keyGenerationFailed }
        
        return (
            ed25519KeyPair: KeyPair(
                publicKey: ed25519KeyPair.publicKey,
                secretKey: ed25519KeyPair.secretKey
            ),
            x25519KeyPair: KeyPair(
                publicKey: x25519PublicKey,
                secretKey: x25519SecretKey
            )
        )
    }

    static func store(_ db: Database, ed25519KeyPair: KeyPair, x25519KeyPair: KeyPair) throws {
        try Identity(variant: .ed25519SecretKey, data: Data(ed25519KeyPair.secretKey)).upsert(db)
        try Identity(variant: .ed25519PublicKey, data: Data(ed25519KeyPair.publicKey)).upsert(db)
        try Identity(variant: .x25519PrivateKey, data: Data(x25519KeyPair.secretKey)).upsert(db)
        try Identity(variant: .x25519PublicKey, data: Data(x25519KeyPair.publicKey)).upsert(db)
    }
    
    static func userExists(
        _ db: Database? = nil,
        using dependencies: Dependencies = Dependencies()
    ) -> Bool {
        return (fetchUserEd25519KeyPair(db, using: dependencies) != nil)
    }
    
    static func fetchUserKeyPair(
        _ db: Database? = nil,
        using dependencies: Dependencies = Dependencies()
    ) -> KeyPair? {
        guard let db: Database = db else {
            return dependencies[singleton: .storage].read { db in fetchUserKeyPair(db, using: dependencies) }
        }
        guard
            let publicKey: Data = try? Identity.fetchOne(db, id: .x25519PublicKey)?.data,
            let secretKey: Data = try? Identity.fetchOne(db, id: .x25519PrivateKey)?.data
        else { return nil }
        
        return KeyPair(
            publicKey: publicKey.bytes,
            secretKey: secretKey.bytes
        )
    }
    
    static func fetchUserEd25519KeyPair(
        _ db: Database? = nil,
        using dependencies: Dependencies = Dependencies()
    ) -> KeyPair? {
        guard let db: Database = db else {
            return dependencies[singleton: .storage].read { db in fetchUserEd25519KeyPair(db, using: dependencies) }
        }
        guard
            let publicKey: Data = try? Identity.fetchOne(db, id: .ed25519PublicKey)?.data,
            let secretKey: Data = try? Identity.fetchOne(db, id: .ed25519SecretKey)?.data
        else { return nil }
        
        return KeyPair(
            publicKey: publicKey.bytes,
            secretKey: secretKey.bytes
        )
    }
}

// MARK: - Convenience

public extension Notification.Name {
    static let registrationStateDidChange = Notification.Name("registrationStateDidChange")
}

public extension Identity {
    static func didRegister() {
        NotificationCenter.default.post(name: .registrationStateDidChange, object: nil, userInfo: nil)
    }
}
