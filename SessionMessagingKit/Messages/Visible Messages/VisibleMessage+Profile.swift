// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

// MARK: - VisibleMessage.VMProfile

public extension VisibleMessage {
    struct VMProfile: Codable {
        public let displayName: String?
        public let profileKey: Data?
        public let profilePictureUrl: String?
        public let blocksCommunityMessageRequests: Bool?
        
        // MARK: - Initialization

        internal init(
            displayName: String,
            profileKey: Data? = nil,
            profilePictureUrl: String? = nil,
            blocksCommunityMessageRequests: Bool? = nil
        ) {
            let hasUrlAndKey: Bool = (profileKey != nil && profilePictureUrl != nil)
            
            self.displayName = displayName
            self.profileKey = (hasUrlAndKey ? profileKey : nil)
            self.profilePictureUrl = (hasUrlAndKey ? profilePictureUrl : nil)
            self.blocksCommunityMessageRequests = blocksCommunityMessageRequests
        }

        // MARK: - Proto Conversion

        public static func fromProto(_ proto: SNProtoDataMessage) -> VMProfile? {
            guard
                let profileProto = proto.profile,
                let displayName = profileProto.displayName
            else { return nil }
            
            return VMProfile(
                displayName: displayName,
                profileKey: proto.profileKey,
                profilePictureUrl: profileProto.profilePicture,
                blocksCommunityMessageRequests: (proto.hasBlocksCommunityMessageRequests ? proto.blocksCommunityMessageRequests : nil)
            )
        }

        public func toProtoBuilder() throws -> SNProtoDataMessage.SNProtoDataMessageBuilder {
            guard let displayName = displayName else { throw MessageSenderError.protoConversionFailed }
            
            let dataMessageProto = SNProtoDataMessage.builder()
            let profileProto = SNProtoLokiProfile.builder()
            profileProto.setDisplayName(displayName)
            
            if let blocksCommunityMessageRequests: Bool = self.blocksCommunityMessageRequests {
                dataMessageProto.setBlocksCommunityMessageRequests(blocksCommunityMessageRequests)
            }
            
            if let profileKey = profileKey, let profilePictureUrl = profilePictureUrl {
                dataMessageProto.setProfileKey(profileKey)
                profileProto.setProfilePicture(profilePictureUrl)
            }
            
            dataMessageProto.setProfile(try profileProto.build())
            return dataMessageProto
        }
        
        public func toProto() -> SNProtoDataMessage? {
            guard
                let dataMessageProtoBuilder = try? toProtoBuilder(),
                let result = try? dataMessageProtoBuilder.build()
            else {
                SNLog("Couldn't construct profile proto from: \(self).")
                return nil
            }
            
            return result
        }
        
        // MARK: - MessageRequestResponse
        
        public static func fromProto(_ proto: SNProtoMessageRequestResponse) -> VMProfile? {
            guard
                let profileProto = proto.profile,
                let displayName = profileProto.displayName
            else { return nil }
            
            return VMProfile(
                displayName: displayName,
                profileKey: proto.profileKey,
                profilePictureUrl: profileProto.profilePicture
            )
        }
        
        public func toProto(isApproved: Bool) -> SNProtoMessageRequestResponse? {
            guard let displayName = displayName else {
                SNLog("Couldn't construct profile proto from: \(self).")
                return nil
            }
            let messageRequestResponseProto = SNProtoMessageRequestResponse.builder(
                isApproved: isApproved
            )
            let profileProto = SNProtoLokiProfile.builder()
            profileProto.setDisplayName(displayName)
            
            if let profileKey = profileKey, let profilePictureUrl = profilePictureUrl {
                messageRequestResponseProto.setProfileKey(profileKey)
                profileProto.setProfilePicture(profilePictureUrl)
            }
            do {
                messageRequestResponseProto.setProfile(try profileProto.build())
                return try messageRequestResponseProto.build()
            } catch {
                SNLog("Couldn't construct profile proto from: \(self).")
                return nil
            }
        }
        
        // MARK: Description
        
        public var description: String {
            """
            Profile(
                displayName: \(displayName ?? "null"),
                profileKey: \(profileKey?.description ?? "null"),
                profilePictureUrl: \(profilePictureUrl ?? "null")
            )
            """
        }
    }
}

// MARK: - Conversion

extension VisibleMessage.VMProfile {
    init(
        profile: Profile,
        blocksCommunityMessageRequests: Bool?
    ) {
        self.displayName = profile.name
        self.profileKey = profile.profileEncryptionKey
        self.profilePictureUrl = profile.profilePictureUrl
        self.blocksCommunityMessageRequests = blocksCommunityMessageRequests
    }
}

// MARK: - MessageWithProfile

public protocol MessageWithProfile {
    var profile: VisibleMessage.VMProfile? { get set }
}

extension VisibleMessage: MessageWithProfile {}
extension MessageRequestResponse: MessageWithProfile {}
extension GroupUpdateInviteMessage: MessageWithProfile {}
extension GroupUpdatePromoteMessage: MessageWithProfile {}
extension GroupUpdateInviteResponseMessage: MessageWithProfile {}
