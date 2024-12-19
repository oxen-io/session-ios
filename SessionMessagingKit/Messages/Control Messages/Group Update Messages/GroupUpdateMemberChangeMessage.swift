// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdateMemberChangeMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case changeType
        case memberSessionIds
        case historyShared
        case adminSignature
    }
    
    public enum ChangeType: Int, Codable {
        case added = 1
        case removed = 2
        case promoted = 3
    }
    
    public var changeType: ChangeType
    public var memberSessionIds: [String]
    public var historyShared: Bool
    public var adminSignature: Authentication.Signature
    
    public override var isSelfSendValid: Bool { true }
    
    override public var processWithBlockedSender: Bool { true }
    
    // MARK: - Initialization
    
    public init(
        changeType: ChangeType,
        memberSessionIds: [String],
        historyShared: Bool,
        sentTimestampMs: UInt64,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws {
        self.changeType = changeType
        self.memberSessionIds = memberSessionIds
        self.historyShared = historyShared
        self.adminSignature = try authMethod.generateSignature(
            with: GroupUpdateMemberChangeMessage.generateVerificationBytes(
                changeType: changeType,
                timestampMs: sentTimestampMs
            ),
            using: dependencies
        )
        
        super.init(
            sentTimestampMs: sentTimestampMs
        )
    }
    
    public init(
        changeType: ChangeType,
        memberSessionIds: [String],
        historyShared: Bool,
        adminSignature: Authentication.Signature
    ) {
        self.changeType = changeType
        self.memberSessionIds = memberSessionIds
        self.historyShared = historyShared
        self.adminSignature = adminSignature
        
        super.init()
    }
    
    // MARK: - Signature Generation
    
    public static func generateVerificationBytes(
        changeType: ChangeType,
        timestampMs: UInt64
    ) -> [UInt8] {
        /// Ed25519 signature of `("MEMBER_CHANGE" || type || timestamp)`
        return "MEMBER_CHANGE".bytes
            .appending(contentsOf: "\(changeType.rawValue)".data(using: .ascii)?.bytes)
            .appending(contentsOf: "\(timestampMs)".data(using: .ascii)?.bytes)
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        changeType = try container.decode(ChangeType.self, forKey: .changeType)
        memberSessionIds = try container.decode([String].self, forKey: .memberSessionIds)
        historyShared = try container.decode(Bool.self, forKey: .historyShared)
        adminSignature = Authentication.Signature.standard(
            signature: try container.decode([UInt8].self, forKey: .adminSignature)
        )
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(changeType, forKey: .changeType)
        try container.encode(memberSessionIds, forKey: .memberSessionIds)
        try container.encode(historyShared, forKey: .historyShared)
        
        switch adminSignature {
            case .standard(let signature): try container.encode(signature, forKey: .adminSignature)
            case .subaccount: throw MessageSenderError.signingFailed
        }
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String, using dependencies: Dependencies) -> GroupUpdateMemberChangeMessage? {
        guard
            let groupMemberChangeMessage = proto.dataMessage?.groupUpdateMessage?.memberChangeMessage,
            let changeType: ChangeType = ChangeType(rawValue: Int(groupMemberChangeMessage.type.rawValue))
        else { return nil }
        
        
        return GroupUpdateMemberChangeMessage(
            changeType: changeType,
            memberSessionIds: groupMemberChangeMessage.memberSessionIds,
            historyShared: groupMemberChangeMessage.historyShared,
            adminSignature: Authentication.Signature.standard(
                signature: Array(groupMemberChangeMessage.adminSignature)
            )
        )
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        do {
            let memberChangeMessageBuilder: SNProtoGroupUpdateMemberChangeMessage.SNProtoGroupUpdateMemberChangeMessageBuilder = SNProtoGroupUpdateMemberChangeMessage.builder(
                type: {
                    switch changeType {
                        case .added: return .added
                        case .removed: return .removed
                        case .promoted: return .promoted
                    }
                }(),
                adminSignature: try {
                    switch adminSignature {
                        case .standard(let signature): return Data(signature)
                        case .subaccount: throw MessageSenderError.signingFailed
                    }
                }()
            )
            
            memberChangeMessageBuilder.setMemberSessionIds(memberSessionIds)
            memberChangeMessageBuilder.setHistoryShared(historyShared)
            
            let groupUpdateMessage = SNProtoGroupUpdateMessage.builder()
            groupUpdateMessage.setMemberChangeMessage(try memberChangeMessageBuilder.build())
            
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
    
    public var description: String {
        """
        GroupUpdateMemberChangeMessage(
            changeType: \(changeType),
            memberSessionIds: \(memberSessionIds),
            historyShared: \(historyShared),
            adminSignature: \(adminSignature)
        )
        """
    }
}
