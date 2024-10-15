// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class ExpirationTimerUpdate: ControlMessage {
    public override var isSelfSendValid: Bool { true }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String, using dependencies: Dependencies) -> ExpirationTimerUpdate? {
        guard let dataMessageProto = proto.dataMessage else { return nil }
        
        let isExpirationTimerUpdate = (dataMessageProto.flags & UInt32(SNProtoDataMessage.SNProtoDataMessageFlags.expirationTimerUpdate.rawValue)) != 0
        guard isExpirationTimerUpdate else { return nil }
        
        return ExpirationTimerUpdate()
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        let dataMessageProto = SNProtoDataMessage.builder()
        dataMessageProto.setFlags(UInt32(SNProtoDataMessage.SNProtoDataMessageFlags.expirationTimerUpdate.rawValue))
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
        ExpirationTimerUpdate()
        """
    }
}
