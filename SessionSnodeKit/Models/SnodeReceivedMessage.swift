// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public struct SnodeReceivedMessage: CustomDebugStringConvertible {
    /// Service nodes cache messages for 14 days so default the expiration for message hashes to '15' days
    /// so we don't end up indefinitely storing records which will never be used
    public static let defaultExpirationSeconds: Int64 = ((15 * 24 * 60 * 60) * 1000)
    
    public let info: SnodeReceivedMessageInfo
    public let namespace: SnodeAPI.Namespace
    public let timestampMs: Int64
    public let data: Data
    
    init?(
        snode: LibSession.Snode,
        publicKey: String,
        namespace: SnodeAPI.Namespace,
        rawMessage: GetMessagesResponse.RawMessage
    ) {
        guard let data: Data = Data(base64Encoded: rawMessage.base64EncodedDataString) else {
            SNLog("Failed to decode data for message: \(rawMessage).")
            return nil
        }
        
        self.info = SnodeReceivedMessageInfo(
            snode: snode,
            swarmPublicKey: publicKey,
            namespace: namespace,
            hash: rawMessage.hash,
            expirationDateMs: (rawMessage.expiration ?? SnodeReceivedMessage.defaultExpirationSeconds)
        )
        self.namespace = namespace
        self.timestampMs = rawMessage.timestampMs
        self.data = data
    }
    
    public var debugDescription: String {
        """
        SnodeReceivedMessage(
            hash: \(info.hash),
            expirationMs: \(info.expirationDateMs),
            timestampMs: \(timestampMs),
            data: \(data.base64EncodedString())
        )
        """
    }
}
