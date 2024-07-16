// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import CommonCrypto
import SessionUtilitiesKit

// MARK: - Encryption

public extension Crypto.Generator {
    private static var hmac256KeyLength: Int { 32 }
    private static var hmac256OutputLength: Int { 32 }
    private static var aesCBCIvLength: Int { 16 }
    private static var aesKeySize: Int { 32 }
    
    static func encryptAttachment(
        plaintext: Data,
        using dependencies: Dependencies
    ) -> Crypto.Generator<(ciphertext: Data, encryptionKey: Data, digest: Data)> {
        return Crypto.Generator(
            id: "encryptAttachment",
            args: [plaintext]
        ) {
            // Due to paddedSize, we need to divide by two.
            guard plaintext.count < (UInt.max / 2) else {
                Log.error("[Crypto] Attachment data too long to encrypt.")
                throw CryptoError.encryptionFailed
            }
            
            guard
                var iv: [UInt8] = dependencies[singleton: .crypto].generate(.randomBytes(aesCBCIvLength)),
                var encryptionKey: [UInt8] = dependencies[singleton: .crypto].generate(.randomBytes(aesKeySize)),
                var hmacKey: [UInt8] = dependencies[singleton: .crypto].generate(.randomBytes(hmac256KeyLength))
            else {
                Log.error("[Crypto] Failed to generate random data.")
                throw CryptoError.encryptionFailed
            }

            // The concatenated key for storage
            var outKey: Data = Data()
            outKey.append(Data(encryptionKey))
            outKey.append(Data(hmacKey))

            // Apply any padding
            let desiredSize: Int = max(541, Int(floor(pow(1.05, ceil(log(Double(plaintext.count)) / log(1.05))))))
            var paddedAttachmentData: [UInt8] = Array(plaintext)
            if desiredSize > plaintext.count {
                paddedAttachmentData.append(contentsOf: [UInt8](repeating: 0, count: desiredSize - plaintext.count))
            }
            
            var numBytesEncrypted: size_t = 0
            var bufferData: [UInt8] = Array(Data(count: paddedAttachmentData.count + kCCBlockSizeAES128))
            let cryptStatus: CCCryptorStatus = CCCrypt(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding),
                &encryptionKey, encryptionKey.count,
                &iv,
                &paddedAttachmentData, paddedAttachmentData.count,
                &bufferData, bufferData.count,
                &numBytesEncrypted
            )

            guard cryptStatus == kCCSuccess else {
                Log.error("[Crypto] Failed to encrypt attachment with status: \(cryptStatus).")
                throw CryptoError.encryptionFailed
            }
            
            guard cryptStatus == kCCSuccess else {
                Log.error("[Crypto] Failed to encrypt attachment with status: \(cryptStatus).")
                throw CryptoError.encryptionFailed
            }

            guard bufferData.count >= numBytesEncrypted else {
                Log.error("[Crypto] ciphertext has unexpected length: \(bufferData.count) < \(numBytesEncrypted).")
                throw CryptoError.encryptionFailed
            }
            
            let ciphertext: [UInt8] = Array(bufferData[0..<numBytesEncrypted])
            var encryptedPaddedData: [UInt8] = (iv + ciphertext)

            // compute hmac of: iv || encrypted data
            guard encryptedPaddedData.count < (UInt.max / 2) else {
                Log.error("[Crypto] Attachment data too long to encrypt.")
                throw CryptoError.encryptionFailed
            }
            guard hmacKey.count < (UInt.max / 2) else {
                Log.error("[Crypto] Hmac key is too long.")
                throw CryptoError.encryptionFailed
            }
            
            var hmacDataBuffer: [UInt8] = Array(Data(count: Int(CC_SHA256_DIGEST_LENGTH)))
            CCHmac(
                CCHmacAlgorithm(kCCHmacAlgSHA256),
                &hmacKey,
                hmacKey.count,
                &encryptedPaddedData,
                encryptedPaddedData.count,
                &hmacDataBuffer
            )
            let hmac: [UInt8] = Array(hmacDataBuffer[0..<hmac256OutputLength])
            encryptedPaddedData.append(contentsOf: hmac)

            // compute digest of: iv || encrypted data || hmac
            guard encryptedPaddedData.count < UInt32.max else {
                Log.error("[Crypto] Attachment data too long to encrypt.")
                throw CryptoError.encryptionFailed
            }
            
            var digest: [UInt8] = Array(Data(count: Int(CC_SHA256_DIGEST_LENGTH)))
            CC_SHA256(&encryptedPaddedData, UInt32(encryptedPaddedData.count), &digest)
            
            return (Data(encryptedPaddedData), outKey, Data(digest))
        }
    }
}

// MARK: - Decryption

public extension Crypto.Generator {
    static func decryptAttachment(
        ciphertext: Data,
        key: Data,
        digest: Data,
        unpaddedSize: UInt
    ) -> Crypto.Generator<Data> {
        return Crypto.Generator(
            id: "decryptAttachment",
            args: [ciphertext, key, digest, unpaddedSize]
        ) {
            guard ciphertext.count >= aesCBCIvLength + hmac256OutputLength else {
                Log.error("[Crypto] Attachment shorter than crypto overhead.");
                throw CryptoError.decryptionFailed
            }
            
            // key: 32 byte AES key || 32 byte Hmac-SHA256 key.
            var encryptionKey: [UInt8] = Array(key[0..<aesKeySize])
            var hmacKey: [UInt8] = Array(key[aesKeySize...])
            
            // ciphertext: IV || Ciphertext || truncated MAC(IV||Ciphertext)
            var iv: [UInt8] = Array(ciphertext[0..<aesCBCIvLength])
            var encryptedAttachment: [UInt8] = Array(ciphertext[aesCBCIvLength..<ciphertext.count - hmac256OutputLength])
            let hmac: [UInt8] = Array(ciphertext[(ciphertext.count - hmac256OutputLength)...])
            
            // Verify hmac of: iv || encrypted data
            var dataToAuth: [UInt8] = (iv + encryptedAttachment)
            var hmacDataBuffer: [UInt8] = Array(Data(count: Int(CC_SHA256_DIGEST_LENGTH)))
            CCHmac(
                CCHmacAlgorithm(kCCHmacAlgSHA256),
                &hmacKey,
                hmacKey.count,
                &dataToAuth,
                dataToAuth.count,
                &hmacDataBuffer
            )
            let generatedHmac: [UInt8] = Array(hmacDataBuffer[0..<hmac256OutputLength])
            let isHmacEqual: Bool = {
                guard hmac.count == generatedHmac.count else { return false }
                
                var isEqual: UInt8 = 0
                (0..<hmac.count).forEach { index in
                    // Rather than returning as soon as we find a discrepency, we compare the rest of
                    // the byte stream to maintain a constant time comparison
                    isEqual |= hmac[index] ^ generatedHmac[index]
                }
                
                return (isEqual == 0)
            }()
            
            guard isHmacEqual else {
                Log.error("[Crypto] Bad HMAC on decrypting payload.")
                throw CryptoError.decryptionFailed
            }
            
            // Verify digest of: iv || encrypted data || hmac
            dataToAuth += generatedHmac
            var generatedDigest: [UInt8] = Array(Data(count: Int(CC_SHA256_DIGEST_LENGTH)))
            CC_SHA256(&dataToAuth, UInt32(dataToAuth.count), &generatedDigest)
            let isDigestEqual: Bool = {
                guard digest.count == generatedDigest.count else { return false }
                
                var isEqual: UInt8 = 0
                (0..<digest.count).forEach { index in
                    // Rather than returning as soon as we find a discrepency, we compare the rest of
                    // the byte stream to maintain a constant time comparison
                    isEqual |= digest[index] ^ generatedDigest[index]
                }
                
                return (isEqual == 0)
            }()
            
            guard isDigestEqual else {
                Log.error("[Crypto] Bad digest on decrypting payload.")
                throw CryptoError.decryptionFailed
            }
            
            var numBytesDecrypted: size_t = 0
            var bufferData: [UInt8] = Array(Data(count: ciphertext.count + kCCBlockSizeAES128))
            let cryptStatus: CCCryptorStatus = CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding),
                &encryptionKey, encryptionKey.count,
                &iv,
                &encryptedAttachment, encryptedAttachment.count,
                &bufferData, bufferData.count,
                &numBytesDecrypted
            )
            
            guard cryptStatus == kCCSuccess else {
                Log.error("[Crypto] Failed to decrypt attachment with status: \(cryptStatus).")
                throw CryptoError.decryptionFailed
            }
            guard bufferData.count >= numBytesDecrypted else {
                Log.error("[Crypto] Attachment paddedPlaintext has unexpected length: \(bufferData.count) < \(numBytesDecrypted).")
                throw CryptoError.decryptionFailed
            }
            
            let paddedPlaintext: [UInt8] = Array(bufferData[0..<numBytesDecrypted])
            
            // Legacy iOS clients didn't set the unpaddedSize on attachments.
            // So an unpaddedSize of 0 could mean one of two things:
            // [case 1] receiving a legacy attachment from before padding was introduced
            // [case 2] receiving a modern attachment of length 0 that just has some null padding (e.g. an empty group sync)
            guard unpaddedSize > 0 else {
                guard paddedPlaintext.contains(where: { $0 != 0x00 }) else {
                    // [case 2] The bytes were all 0's. We assume it was all padding and the actual
                    // attachment data was indeed empty. The downside here would be if a legacy client
                    // was intentionally sending an attachment consisting of just 0's. This seems unlikely,
                    // and would only affect iOS clients from before commit:
                    //
                    //      6eeb78157a044e632adc3daf6254aceacd53e335
                    //      Author: Michael Kirk <michael.code@endoftheworl.de>
                    //      Date:   Thu Oct 26 15:08:25 2017 -0700
                    //
                    //      Include size in attachment pointer
                    return Data()
                }
                
                // [case 1] There was something besides 0 in our data, assume it wasn't padding.
                return Data(paddedPlaintext)
            }
            
            guard unpaddedSize <= paddedPlaintext.count else {
                Log.error("[Crypto] Decrypted attachment was smaller than the expected size (\(unpaddedSize) < \(paddedPlaintext.count)), decryption was invalid.")
                throw CryptoError.decryptionFailed
            }
            
            // If the `paddedPlaintext` is the same length as the `unpaddedSize` then just return it
            guard unpaddedSize != paddedPlaintext.count else { return Data(paddedPlaintext) }
            
            return Data(paddedPlaintext[0..<Int(unpaddedSize)])
        }
    }
}
