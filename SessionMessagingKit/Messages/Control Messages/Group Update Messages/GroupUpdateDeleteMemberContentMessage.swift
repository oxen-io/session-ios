// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdateDeleteMemberContentMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case memberSessionIds
        case messageHashes
        case adminSignature
    }
    
    public var memberSessionIds: [String]
    public var messageHashes: [String]
    public var adminSignature: Authentication.Signature?
    
    public override var isSelfSendValid: Bool { true }
    
    override public var processWithBlockedSender: Bool { true }
    
    // MARK: - Initialization
    
    public init(
        memberSessionIds: [String],
        messageHashes: [String],
        sentTimestampMs: UInt64,
        authMethod: AuthenticationMethod?,
        using dependencies: Dependencies
    ) throws {
        self.memberSessionIds = memberSessionIds
        self.messageHashes = messageHashes
        self.adminSignature = try authMethod.map { method in
            try method.generateSignature(
                with: GroupUpdateDeleteMemberContentMessage.generateVerificationBytes(
                    memberSessionIds: memberSessionIds,
                    messageHashes: messageHashes,
                    timestampMs: sentTimestampMs
                ),
                using: dependencies
            )
        }
        
        super.init(
            sentTimestampMs: sentTimestampMs
        )
    }
    
    internal init(
        memberSessionIds: [String],
        messageHashes: [String],
        adminSignature: Authentication.Signature?
    ) {
        self.memberSessionIds = memberSessionIds
        self.messageHashes = messageHashes
        self.adminSignature = adminSignature
        
        super.init()
    }
    
    // MARK: - Signature Generation
    
    public static func generateVerificationBytes(
        memberSessionIds: [String],
        messageHashes: [String],
        timestampMs: UInt64
    ) -> [UInt8] {
        /// Ed25519 signature of
        /// `("DELETE_CONTENT" || timestamp || sessionId[0] || ... || sessionId[N] || msgHash[0] || ... || msgHash[N])`
        return "DELETE_CONTENT".bytes
            .appending(contentsOf: "\(timestampMs)".data(using: .ascii)?.bytes)
            .appending(contentsOf: memberSessionIds.joined().bytes)
            .appending(contentsOf: messageHashes.joined().bytes)
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        memberSessionIds = try container.decode([String].self, forKey: .memberSessionIds)
        messageHashes = try container.decode([String].self, forKey: .messageHashes)
        adminSignature = (try? container.decode([UInt8].self, forKey: .adminSignature)).map {
            Authentication.Signature.standard(signature: $0)
        }
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(memberSessionIds, forKey: .memberSessionIds)
        try container.encode(messageHashes, forKey: .messageHashes)
        
        switch adminSignature {
            case .some(.standard(let signature)): try container.encode(signature, forKey: .adminSignature)
            case .some(.subaccount): throw MessageSenderError.signingFailed
            case .none: break   // Valid case (member deleting their own sent messages)
        }
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String, using dependencies: Dependencies) -> GroupUpdateDeleteMemberContentMessage? {
        guard let groupDeleteMemberContentMessage = proto.dataMessage?.groupUpdateMessage?.deleteMemberContent else { return nil }
        
        return GroupUpdateDeleteMemberContentMessage(
            memberSessionIds: groupDeleteMemberContentMessage.memberSessionIds,
            messageHashes: groupDeleteMemberContentMessage.messageHashes,
            adminSignature: groupDeleteMemberContentMessage.adminSignature.map {
                Authentication.Signature.standard(signature: Array($0))
            }
        )
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        do {
            let deleteMemberContentMessageBuilder: SNProtoGroupUpdateDeleteMemberContentMessage.SNProtoGroupUpdateDeleteMemberContentMessageBuilder = SNProtoGroupUpdateDeleteMemberContentMessage.builder()
            deleteMemberContentMessageBuilder.setMemberSessionIds(memberSessionIds)
            deleteMemberContentMessageBuilder.setMessageHashes(messageHashes)
            
            switch adminSignature {
                case .some(.standard(let signature)): deleteMemberContentMessageBuilder.setAdminSignature(Data(signature))
                case .some(.subaccount): throw MessageSenderError.signingFailed
                case .none: break    // Valid case (member deleting their own sent messages)
            }
            
            let groupUpdateMessage = SNProtoGroupUpdateMessage.builder()
            groupUpdateMessage.setDeleteMemberContent(try deleteMemberContentMessageBuilder.build())
            
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
        GroupUpdateDeleteMemberContentMessage(
            memberSessionIds: \(memberSessionIds),
            messageHashes: \(messageHashes),
            adminSignature: \(adminSignature.map { "\($0)" } ?? "null")
        )
        """
    }
}
