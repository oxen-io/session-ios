// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdateInviteResponseMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case isApproved
        case profile
    }
    
    public var isApproved: Bool
    public var profile: VisibleMessage.VMProfile?
    
    override public var processWithBlockedSender: Bool { true }
    
    // MARK: - Initialization
    
    public init(
        isApproved: Bool,
        profile: VisibleMessage.VMProfile? = nil,   // Added when sending via the `MessageWithProfile` protocol
        sentTimestampMs: UInt64? = nil
    ) {
        self.isApproved = isApproved
        self.profile = profile
        
        super.init(
            sentTimestampMs: sentTimestampMs
        )
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        isApproved = try container.decode(Bool.self, forKey: .isApproved)
        profile = try? container.decode(VisibleMessage.VMProfile.self, forKey: .profile)
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(isApproved, forKey: .isApproved)
        try container.encodeIfPresent(profile, forKey: .profile)
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String, using dependencies: Dependencies) -> GroupUpdateInviteResponseMessage? {
        guard
            let dataMessage: SNProtoDataMessage = proto.dataMessage,
            let groupInviteResponseMessage = dataMessage.groupUpdateMessage?.inviteResponse
        else { return nil }
        
        return GroupUpdateInviteResponseMessage(
            isApproved: groupInviteResponseMessage.isApproved,
            profile: VisibleMessage.VMProfile.fromProto(dataMessage)
        )
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        do {
            let inviteResponseMessageBuilder: SNProtoGroupUpdateInviteResponseMessage.SNProtoGroupUpdateInviteResponseMessageBuilder = SNProtoGroupUpdateInviteResponseMessage.builder(
                isApproved: isApproved
            )
            
            let groupUpdateMessage = SNProtoGroupUpdateMessage.builder()
            groupUpdateMessage.setInviteResponse(try inviteResponseMessageBuilder.build())
            
            let dataMessage: SNProtoDataMessage.SNProtoDataMessageBuilder = try {
                guard let profile: VisibleMessage.VMProfile = profile else {
                    return SNProtoDataMessage.builder()
                }
                
                return try profile.toProtoBuilder()
            }()
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
    
    public var description: String {
        """
        GroupUpdateInviteResponseMessage(
            isApproved: \(isApproved),
            profile: \(profile?.description ?? "null")
        )
        """
    }
}
