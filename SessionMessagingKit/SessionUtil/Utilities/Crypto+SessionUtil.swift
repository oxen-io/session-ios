// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Crypto.Generator {
    static func tokenSubaccount(
        config: SessionUtil.Config?,
        groupSessionId: SessionId,
        memberId: String
    ) -> Crypto.Generator<[UInt8]> {
        return Crypto.Generator(
            id: "tokenSubaccount",
            args: [config, groupSessionId, memberId]
        ) {
            guard case .groupKeys(let conf, _, _) = config else { throw SessionUtilError.invalidConfigObject }
            
            var cMemberId: [CChar] = memberId.cArray
            var tokenData: [UInt8] = [UInt8](repeating: 0, count: SessionUtil.sizeSubaccountBytes)
            
            guard groups_keys_swarm_subaccount_token(
                conf,
                &cMemberId,
                &tokenData
            ) else { throw SessionUtilError.failedToMakeSubAccountInGroup }
            
            return tokenData
        }
    }
    
    static func memberAuthData(
        config: SessionUtil.Config?,
        groupSessionId: SessionId,
        memberId: String
    ) -> Crypto.Generator<Authentication.Info> {
        return Crypto.Generator(
            id: "memberAuthData",
            args: [config, groupSessionId, memberId]
        ) {
            guard case .groupKeys(let conf, _, _) = config else { throw SessionUtilError.invalidConfigObject }
            
            var cMemberId: [CChar] = memberId.cArray
            var authData: [UInt8] = [UInt8](repeating: 0, count: SessionUtil.sizeAuthDataBytes)
            
            guard groups_keys_swarm_make_subaccount(
                conf,
                &cMemberId,
                &authData
            ) else { throw SessionUtilError.failedToMakeSubAccountInGroup }
            
            return .groupMember(groupSessionId: groupSessionId, authData: Data(authData))
        }
    }
    
    static func signatureSubaccount(
        config: SessionUtil.Config?,
        verificationBytes: [UInt8],
        memberAuthData: Data
    ) -> Crypto.Generator<Authentication.Signature> {
        return Crypto.Generator(
            id: "signatureSubaccount",
            args: [config, verificationBytes, memberAuthData]
        ) {
            guard case .groupKeys(let conf, _, _) = config else { throw SessionUtilError.invalidConfigObject }
            
            var verificationBytes: [UInt8] = verificationBytes
            var memberAuthData: [UInt8] = Array(memberAuthData)
            var subaccount: [UInt8] = [UInt8](repeating: 0, count: SessionUtil.sizeSubaccountBytes)
            var subaccountSig: [UInt8] = [UInt8](repeating: 0, count: SessionUtil.sizeSubaccountSigBytes)
            var signature: [UInt8] = [UInt8](repeating: 0, count: SessionUtil.sizeSubaccountSignatureBytes)
            
            guard groups_keys_swarm_subaccount_sign_binary(
                conf,
                &verificationBytes,
                verificationBytes.count,
                &memberAuthData,
                &subaccount,
                &subaccountSig,
                &signature
            ) else { throw MessageSenderError.signingFailed }
            
            return Authentication.Signature.subaccount(
                subaccount: subaccount,
                subaccountSig: subaccountSig,
                signature: signature
            )
        }
    }
}

public extension Crypto.Verification {
    static func memberAuthData(
        groupSessionId: SessionId,
        ed25519SecretKey: [UInt8],
        memberAuthData: Data
    ) -> Crypto.Verification {
        return Crypto.Verification(
            id: "memberAuthData",
            args: [groupSessionId, ed25519SecretKey, memberAuthData]
        ) {
            var cGroupId: [CChar] = groupSessionId.hexString.cArray
            var cEd25519SecretKey: [UInt8] = ed25519SecretKey
            var cAuthData: [UInt8] = Array(memberAuthData)
            
            return groups_keys_swarm_verify_subaccount(
                &cGroupId,
                &cEd25519SecretKey,
                &cAuthData
            )
        }
    }
}
