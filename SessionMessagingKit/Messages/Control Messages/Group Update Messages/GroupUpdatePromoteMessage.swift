// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdatePromoteMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case groupIdentitySeed
        case groupName
        case profile
    }
    
    public var groupIdentitySeed: Data
    public var groupName: String
    public var profile: VisibleMessage.VMProfile?
    
    override public var processWithBlockedSender: Bool { true }
    
    // MARK: - Initialization
    
    public init(
        groupIdentitySeed: Data,
        groupName: String,
        profile: VisibleMessage.VMProfile? = nil,   // Added when sending via the `MessageWithProfile` protocol
        sentTimestampMs: UInt64? = nil
    ) {
        self.groupIdentitySeed = groupIdentitySeed
        self.groupName = groupName
        self.profile = profile
        
        super.init(
            sentTimestampMs: sentTimestampMs
        )
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        groupIdentitySeed = try container.decode(Data.self, forKey: .groupIdentitySeed)
        groupName = try container.decode(String.self, forKey: .groupName)
        profile = try container.decodeIfPresent(VisibleMessage.VMProfile.self, forKey: .profile)
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(groupIdentitySeed, forKey: .groupIdentitySeed)
        try container.encode(groupName, forKey: .groupName)
        try container.encodeIfPresent(profile, forKey: .profile)
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String, using dependencies: Dependencies) -> GroupUpdatePromoteMessage? {
        guard
            let dataMessage: SNProtoDataMessage = proto.dataMessage,
            let groupPromoteMessage = proto.dataMessage?.groupUpdateMessage?.promoteMessage
        else { return nil }
        
        return GroupUpdatePromoteMessage(
            groupIdentitySeed: groupPromoteMessage.groupIdentitySeed,
            groupName: groupPromoteMessage.name,
            profile: VisibleMessage.VMProfile.fromProto(dataMessage)
        )
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        do {
            let promoteMessageBuilder: SNProtoGroupUpdatePromoteMessage.SNProtoGroupUpdatePromoteMessageBuilder = SNProtoGroupUpdatePromoteMessage.builder(
                groupIdentitySeed: groupIdentitySeed,
                name: groupName
            )
            
            let groupUpdateMessage = SNProtoGroupUpdateMessage.builder()
            groupUpdateMessage.setPromoteMessage(try promoteMessageBuilder.build())
            
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
        GroupUpdatePromoteMessage(
            groupIdentitySeed: \(groupIdentitySeed.toHexString()),
            groupName: \(groupName),
            profile: \(profile?.description ?? "null")
        )
        """
    }
}
