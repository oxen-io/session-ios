// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class ExpirationTimerUpdate: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case syncTarget
    }
    
    public var syncTarget: String?
    
    public override var isSelfSendValid: Bool { true }
    
    public init(syncTarget: String? = nil) {
        super.init()
        
        self.syncTarget = syncTarget
    }
    
    // MARK: - Codable
        
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        syncTarget = try? container.decode(String.self, forKey: .syncTarget)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encodeIfPresent(syncTarget, forKey: .syncTarget)
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String, using dependencies: Dependencies) -> ExpirationTimerUpdate? {
        guard let dataMessageProto = proto.dataMessage else { return nil }
        
        let isExpirationTimerUpdate = (dataMessageProto.flags & UInt32(SNProtoDataMessage.SNProtoDataMessageFlags.expirationTimerUpdate.rawValue)) != 0
        guard isExpirationTimerUpdate else { return nil }
        
        return ExpirationTimerUpdate(
            syncTarget: dataMessageProto.syncTarget
        )
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        let dataMessageProto = SNProtoDataMessage.builder()
        dataMessageProto.setFlags(UInt32(SNProtoDataMessage.SNProtoDataMessageFlags.expirationTimerUpdate.rawValue))
        if let syncTarget = syncTarget { dataMessageProto.setSyncTarget(syncTarget) }
        let contentProto = SNProtoContent.builder()
        
        // DisappearingMessagesConfiguration
        setDisappearingMessagesConfigurationIfNeeded(on: contentProto)
        
        do {
            contentProto.setDataMessage(try dataMessageProto.build())
            return try contentProto.build()
        } catch {
            SNLog("Couldn't construct expiration timer update proto from: \(self).")
            return nil
        }
    }
    
    // MARK: - Description
    
    public var description: String {
        """
        ExpirationTimerUpdate(
            syncTarget: \(syncTarget ?? "null"),
        )
        """
    }
}
