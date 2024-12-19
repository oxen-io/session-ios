// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdateMemberLeftMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case memberLeftCodableId
    }
    
    /// This value shouldn't be used for any logic, it's just used to ensure this type can be uniquely encoded/decoded by
    /// the `Message.createMessageFrom(_:sender:)` function and won't collide with other message types due
    /// to having the same keys
    private let memberLeftCodableId: UUID = UUID()
    
    public override var isSelfSendValid: Bool { true }
    
    override public var processWithBlockedSender: Bool { true }
    
    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String, using dependencies: Dependencies) -> GroupUpdateMemberLeftMessage? {
        guard proto.dataMessage?.groupUpdateMessage?.memberLeftMessage != nil else { return nil }
        
        return GroupUpdateMemberLeftMessage()
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        do {
            let memberLeftMessageBuilder: SNProtoGroupUpdateMemberLeftMessage.SNProtoGroupUpdateMemberLeftMessageBuilder = SNProtoGroupUpdateMemberLeftMessage.builder()
            
            let groupUpdateMessage = SNProtoGroupUpdateMessage.builder()
            groupUpdateMessage.setMemberLeftMessage(try memberLeftMessageBuilder.build())
            
            let dataMessage = SNProtoDataMessage.builder()
            dataMessage.setGroupUpdateMessage(try groupUpdateMessage.build())
            
            let contentProto = SNProtoContent.builder()
            contentProto.setDataMessage(try dataMessage.build())
            return try contentProto.build()
        } catch {
            SNLog("Couldn't construct data extraction notification proto from: \(self).")
            return nil
        }
    }

    // MARK: - Description
    
    public var description: String { "GroupUpdateMemberLeftMessage()" }
}
