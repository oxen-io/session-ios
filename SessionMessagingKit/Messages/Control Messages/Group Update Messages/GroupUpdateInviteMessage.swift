// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdateInviteMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case inviteeSessionIdHexString
        case groupSessionId
        case groupName
        case memberAuthData
        case profile
        case adminSignature
    }
    
    public var inviteeSessionIdHexString: String
    public var groupSessionId: SessionId
    public var groupName: String
    public var memberAuthData: Data
    public var profile: VisibleMessage.VMProfile?
    public var adminSignature: Authentication.Signature
    
    // MARK: - Initialization
    
    public init(
        inviteeSessionIdHexString: String,
        groupSessionId: SessionId,
        groupName: String,
        memberAuthData: Data,
        profile: VisibleMessage.VMProfile? = nil,   // Added when sending via the `MessageWithProfile` protocol
        sentTimestamp: UInt64,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws {
        self.inviteeSessionIdHexString = inviteeSessionIdHexString
        self.groupSessionId = groupSessionId
        self.groupName = groupName
        self.memberAuthData = memberAuthData
        self.profile = profile
        self.adminSignature = try authMethod.generateSignature(
            with: GroupUpdateInviteMessage.generateVerificationBytes(
                inviteeSessionIdHexString: inviteeSessionIdHexString,
                timestampMs: sentTimestamp
            ),
            using: dependencies
        )
        
        super.init(
            sentTimestamp: sentTimestamp
        )
    }
    
    internal init(
        inviteeSessionIdHexString: String,
        groupSessionId: SessionId,
        groupName: String,
        memberAuthData: Data,
        profile: VisibleMessage.VMProfile? = nil,
        adminSignature: Authentication.Signature
    ) {
        self.inviteeSessionIdHexString = inviteeSessionIdHexString
        self.groupSessionId = groupSessionId
        self.groupName = groupName
        self.memberAuthData = memberAuthData
        self.profile = profile
        self.adminSignature = adminSignature
        
        super.init()
    }
    
    // MARK: - Signature Generation
    
    public static func generateVerificationBytes(
        inviteeSessionIdHexString: String,
        timestampMs: UInt64
    ) -> [UInt8] {
        /// Ed25519 signature of `("INVITE" || inviteeSessionId || timestamp)`
        return "INVITE".bytes
            .appending(contentsOf: inviteeSessionIdHexString.bytes)
            .appending(contentsOf: "\(timestampMs)".data(using: .ascii)?.bytes)
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        inviteeSessionIdHexString = try container.decode(String.self, forKey: .inviteeSessionIdHexString)
        groupSessionId = SessionId(.group, publicKey: Array(try container.decode(Data.self, forKey: .groupSessionId)))
        groupName = try container.decode(String.self, forKey: .groupName)
        memberAuthData = try container.decode(Data.self, forKey: .memberAuthData)
        profile = try? container.decode(VisibleMessage.VMProfile.self, forKey: .profile)
        adminSignature = Authentication.Signature.standard(
            signature: try container.decode([UInt8].self, forKey: .adminSignature)
        )
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(inviteeSessionIdHexString, forKey: .inviteeSessionIdHexString)
        try container.encode(Data(groupSessionId.publicKey), forKey: .groupSessionId)
        try container.encode(groupName, forKey: .groupName)
        try container.encode(memberAuthData, forKey: .memberAuthData)
        try container.encodeIfPresent(profile, forKey: .profile)
        
        switch adminSignature {
            case .standard(let signature): try container.encode(signature, forKey: .adminSignature)
            case .subaccount: throw MessageSenderError.signingFailed
        }
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> GroupUpdateInviteMessage? {
        guard
            let dataMessage: SNProtoDataMessage = proto.dataMessage,
            let groupInviteMessage = dataMessage.groupUpdateMessage?.inviteMessage
        else { return nil }
        
        let userSessionId: SessionId = getUserSessionId()
        
        return GroupUpdateInviteMessage(
            inviteeSessionIdHexString: userSessionId.hexString,
            groupSessionId: SessionId(.group, hex: groupInviteMessage.groupSessionID),
            groupName: groupInviteMessage.name,
            memberAuthData: groupInviteMessage.memberAuthData,
            profile: VisibleMessage.VMProfile.fromProto(dataMessage),
            adminSignature: Authentication.Signature.standard(
                signature: Array(groupInviteMessage.adminSignature)
            )
        )
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        do {
            let inviteMessageBuilder: SNProtoGroupUpdateInviteMessage.SNProtoGroupUpdateInviteMessageBuilder = SNProtoGroupUpdateInviteMessage.builder(
                groupSessionID: groupSessionId.hexString,           // Include the prefix
                name: groupName,
                memberAuthData: memberAuthData,
                adminSignature: try {
                    switch adminSignature {
                        case .standard(let signature): return Data(signature)
                        case .subaccount: throw MessageSenderError.signingFailed
                    }
                }()
            )
            
            let groupUpdateMessage = SNProtoGroupUpdateMessage.builder()
            groupUpdateMessage.setInviteMessage(try inviteMessageBuilder.build())
            
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
        GroupUpdateInviteMessage(
            inviteeSessionIdHexString: \(inviteeSessionIdHexString),
            groupSessionId: \(groupSessionId),
            groupName: \(groupName),
            memberAuthData: \(memberAuthData.toHexString()),
            profile: \(profile?.description ?? "null"),
            adminSignature: \(adminSignature)
        )
        """
    }
}
