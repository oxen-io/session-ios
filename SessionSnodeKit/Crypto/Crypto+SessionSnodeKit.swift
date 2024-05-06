// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUtilitiesKit

// MARK: - ONS Response

internal extension Crypto.Generator {
    static func sessionId(
        name: String,
        response: SnodeAPI.ONSResolveResponse
    ) -> Crypto.Generator<String> {
        return Crypto.Generator(
            id: "sessionId_for_ONS_response",
            args: [name, response]
        ) {
            guard let hexEncodedNonce: String = response.result.nonce else {
                throw SnodeAPIError.decryptionFailed
            }
            
            // Name must be in lowercase
            var cLowercaseName: [CChar] = name.lowercased().cArray
            var cCiphertext: [UInt8] = Array(Data(hex: response.result.encryptedValue))
            var cNonce: [UInt8] = Array(Data(hex: hexEncodedNonce))
            var cSessionId: [CChar] = [CChar](repeating: 0, count: 67)
            
            guard
                cNonce.count == 24,
                session_decrypt_ons_response(
                    &cLowercaseName,
                    cLowercaseName.count,
                    &cCiphertext,
                    cCiphertext.count,
                    &cNonce,
                    &cSessionId
                )
            else { throw SnodeAPIError.decryptionFailed }
            
            return String(cString: cSessionId)
        }
    }
}

// MARK: - Onion Request

internal extension Crypto.Generator {
    static func onionRequestPayload(
        payload: Data,
        destination: OnionRequestAPIDestination,
        path: [Snode]
    ) -> Crypto.Generator<OnionRequestAPI.PreparedOnionRequest> {
        return Crypto.Generator(
            id: "onionRequestPayload",
            args: [payload, destination, path]
        ) {
            guard let guardSnode: Snode = path.first else { throw OnionRequestAPIError.insufficientSnodes }
            
            var cPayloadIn: [UInt8] = Array(payload)
            var finalX25519Pubkey: [UInt8] = [UInt8](repeating: 0, count: 32)
            var finalX25519Seckey: [UInt8] = [UInt8](repeating: 0, count: 32)
            var maybePayloadOutPtr: UnsafeMutablePointer<UInt8>?
            var payloadOutLen: Int = 0
            
            var result: Bool = false
            try CExceptionHelper.performSafely {
                var builder: UnsafeMutablePointer<onion_request_builder_object>? = nil
                onion_request_builder_init(&builder)
                
                switch destination {
                    case .server(let host, let target, let x25519PublicKey, let scheme, let port):
                        let targetScheme: String = (scheme ?? "https")
                        var cHost: [CChar] = host.cArray.nullTerminated()
                        var cTarget: [CChar] = target.cArray.nullTerminated()
                        var cScheme: [CChar] = targetScheme.cArray.nullTerminated()
                        var cDestinationx25519Pubkey: [CChar] = x25519PublicKey.cArray.nullTerminated()
                        
                        onion_request_builder_set_server_destination(
                            builder,
                            &cHost,
                            &cTarget,
                            &cScheme,
                            (port ?? (targetScheme == "https" ? 443 : 80)),
                            &cDestinationx25519Pubkey
                        )
                        
                    case .snode(let snode):
                        var cDestinationEd25519Pubkey: [CChar] = snode.ed25519PublicKey.cArray.nullTerminated()
                        var cDestinationx25519Pubkey: [CChar] = snode.x25519PublicKey.cArray.nullTerminated()
                        
                        onion_request_builder_set_snode_destination(
                            builder,
                            &cDestinationEd25519Pubkey,
                            &cDestinationx25519Pubkey
                        )
                }
                
                path.forEach { snode in
                    var cEd25519Pubkey: [CChar] = snode.ed25519PublicKey.cArray.nullTerminated()
                    var cX25519Pubkey: [CChar] = snode.x25519PublicKey.cArray.nullTerminated()
                    onion_request_builder_add_hop(builder, &cEd25519Pubkey, &cX25519Pubkey)
                }
                
                result = onion_request_builder_build(
                    builder,
                    &cPayloadIn,
                    payload.count,
                    &maybePayloadOutPtr,
                    &payloadOutLen,
                    &finalX25519Pubkey,
                    &finalX25519Seckey
                )
            }
            
            guard
                result,
                let payloadOutPtr: UnsafeMutablePointer<UInt8> = maybePayloadOutPtr
            else { throw OnionRequestAPIError.pathEncryptionFailed }
            
            /// Need to deallocate the `payloadOutPtr` before returning
            let payloadOut: Data = Data(bytes: payloadOutPtr, count: payloadOutLen)
            maybePayloadOutPtr?.deallocate()
            
            return (
                guardSnode,
                payloadOut,
                KeyPair(publicKey: finalX25519Pubkey, secretKey: finalX25519Seckey)
            )
        }
    }
    
    static func onionRequestResponse(
        responseData: Data,
        destination: OnionRequestAPIDestination,
        finalX25519KeyPair: KeyPair
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "onionRequestResponse",
            args: [responseData, destination, finalX25519KeyPair]
        ) {
            var ciphertext: [UInt8] = Array(responseData)
            var cDestinationx25519Pubkey: [UInt8] = {
                switch destination {
                    case .server(_, _, let x25519PublicKey, _, _):
                        return Array(Data(hex: x25519PublicKey))
                        
                    case .snode(let snode): return Array(Data(hex: snode.x25519PublicKey))
                }
            }()
            var finalX25519Pubkey: [UInt8] = finalX25519KeyPair.publicKey
            var finalX25519Seckey: [UInt8] = finalX25519KeyPair.secretKey
            var maybePlaintextPtr: UnsafeMutablePointer<UInt8>?
            var plaintextLen: Int = 0
            
            var result: Bool = false
            try CExceptionHelper.performSafely {
                result = onion_request_decrypt(
                    &ciphertext,
                    ciphertext.count,
                    ENCRYPT_TYPE_X_CHA_CHA_20,
                    &cDestinationx25519Pubkey,
                    &finalX25519Pubkey,
                    &finalX25519Seckey,
                    &maybePlaintextPtr,
                    &plaintextLen
                )
            }
            
            guard
                result,
                let plaintextPtr: UnsafeMutablePointer<UInt8> = maybePlaintextPtr
            else { throw OnionRequestAPIError.pathEncryptionFailed }
            
            /// Need to deallocate the `plaintextPtr` before returning
            let plaintext: Data = Data(bytes: plaintextPtr, count: plaintextLen)
            maybePlaintextPtr?.deallocate()
            
            return plaintext
        }
    }
}
