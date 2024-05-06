// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdateInfoChangeMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case changeType
        case updatedName
        case updatedExpiration
        case adminSignature
    }
    
    public enum ChangeType: Int, Codable {
        case name = 1
        case avatar = 2
        case disappearingMessages = 3
    }
    
    public var changeType: ChangeType
    public var updatedName: String?
    public var updatedExpiration: UInt32?
    public var adminSignature: Authentication.Signature
    
    override public var processWithBlockedSender: Bool { true }
    
    // MARK: - Initialization
    
    public init(
        changeType: ChangeType,
        updatedName: String? = nil,
        updatedExpiration: UInt32? = nil,
        sentTimestamp: UInt64,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws {
        self.changeType = changeType
        self.updatedName = updatedName
        self.updatedExpiration = updatedExpiration
        self.adminSignature = try authMethod.generateSignature(
            with: GroupUpdateInfoChangeMessage.generateVerificationBytes(
                changeType: changeType,
                timestampMs: sentTimestamp
            ),
            using: dependencies
        )
        
        super.init(
            sentTimestamp: sentTimestamp
        )
    }
    
    internal init(
        changeType: ChangeType,
        updatedName: String? = nil,
        updatedExpiration: UInt32? = nil,
        adminSignature: Authentication.Signature
    ) {
        self.changeType = changeType
        self.updatedName = updatedName
        self.updatedExpiration = updatedExpiration
        self.adminSignature = adminSignature
        
        super.init()
    }
    
    // MARK: - Signature Generation
    
    public static func generateVerificationBytes(
        changeType: ChangeType,
        timestampMs: UInt64
    ) -> [UInt8] {
        /// Ed25519 signature of `("INFO_CHANGE" || type || timestamp)`
        return "INFO_CHANGE".bytes
            .appending(contentsOf: "\(changeType.rawValue)".data(using: .ascii)?.bytes)
            .appending(contentsOf: "\(timestampMs)".data(using: .ascii)?.bytes)
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        changeType = try container.decode(ChangeType.self, forKey: .changeType)
        updatedName = try? container.decode(String.self, forKey: .updatedName)
        updatedExpiration = try? container.decode(UInt32.self, forKey: .updatedExpiration)
        adminSignature = Authentication.Signature.standard(
            signature: try container.decode([UInt8].self, forKey: .adminSignature)
        )
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(changeType, forKey: .changeType)
        try container.encodeIfPresent(updatedName, forKey: .updatedName)
        try container.encodeIfPresent(updatedExpiration, forKey: .updatedExpiration)
        
        switch adminSignature {
            case .standard(let signature): try container.encode(signature, forKey: .adminSignature)
            case .subaccount: throw MessageSenderError.signingFailed
        }
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> GroupUpdateInfoChangeMessage? {
        guard
            let groupInfoChangeMessage = proto.dataMessage?.groupUpdateMessage?.infoChangeMessage,
            let changeType: ChangeType = ChangeType(rawValue: Int(groupInfoChangeMessage.type.rawValue))
        else { return nil }
        
        
        return GroupUpdateInfoChangeMessage(
            changeType: changeType,
            updatedName: groupInfoChangeMessage.updatedName,
            updatedExpiration: groupInfoChangeMessage.updatedExpiration,
            adminSignature: Authentication.Signature.standard(
                signature: Array(groupInfoChangeMessage.adminSignature)
            )
        )
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        do {
            let infoChangeMessageBuilder: SNProtoGroupUpdateInfoChangeMessage.SNProtoGroupUpdateInfoChangeMessageBuilder = SNProtoGroupUpdateInfoChangeMessage.builder(
                type: {
                    switch changeType {
                        case .name: return .name
                        case .avatar: return .avatar
                        case .disappearingMessages: return .disappearingMessages
                    }
                }(),
                adminSignature: try {
                    switch adminSignature {
                        case .standard(let signature): return Data(signature)
                        case .subaccount: throw MessageSenderError.signingFailed
                    }
                }()
            )
            
            if let updatedName: String = updatedName {
                infoChangeMessageBuilder.setUpdatedName(updatedName)
            }
            
            if let updatedExpiration: UInt32 = updatedExpiration.map({ UInt32($0) }) {
                infoChangeMessageBuilder.setUpdatedExpiration(updatedExpiration)
            }
            
            let groupUpdateMessage = SNProtoGroupUpdateMessage.builder()
            groupUpdateMessage.setInfoChangeMessage(try infoChangeMessageBuilder.build())
            
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
        GroupUpdateInfoChangeMessage(
            changeType: \(changeType),
            updatedName: \(String(describing: updatedName)),
            updatedExpiration: \(String(describing: updatedExpiration)),
            adminSignature: \(adminSignature)
        )
        """
    }
}
