// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

public extension ProfilePictureView {
    func update(
        publicKey: String,
        threadVariant: SessionThread.Variant,
        displayPictureFilename: String?,
        profile: Profile?,
        profileIcon: ProfileIcon = .none,
        additionalProfile: Profile? = nil,
        additionalProfileIcon: ProfileIcon = .none
    ) {
        let (info, additionalInfo): (Info?, Info?) = ProfilePictureView.getProfilePictureInfo(
            size: self.size,
            publicKey: publicKey,
            threadVariant: threadVariant,
            displayPictureFilename: displayPictureFilename,
            profile: profile,
            profileIcon: profileIcon,
            additionalProfile: additionalProfile,
            additionalProfileIcon: additionalProfileIcon
        )
        
        guard let info: Info = info else { return }
        
        update(info, additionalInfo: additionalInfo)
    }
    
    static func getProfilePictureInfo(
        size: Size,
        publicKey: String,
        threadVariant: SessionThread.Variant,
        displayPictureFilename: String?,
        profile: Profile?,
        profileIcon: ProfileIcon = .none,
        additionalProfile: Profile? = nil,
        additionalProfileIcon: ProfileIcon = .none
    ) -> (Info?, Info?) {
        // If we are given an explicit 'displayPictureFilename' then only use that (this could be for
        // either Community conversations or updated groups)
        if let displayPictureFilename: String = displayPictureFilename {
            return (Info(
                imageData: DisplayPictureManager.displayPicture(owner: .file(displayPictureFilename)),
                icon: profileIcon
            ), nil)
        }
        
        
        // Otherwise there are conversation-type-specific behaviours
        switch threadVariant {
            case .community:
                let placeholderImage: UIImage = {
                    switch size {
                        case .navigation, .message: return #imageLiteral(resourceName: "SessionWhite16")
                        case .list: return #imageLiteral(resourceName: "SessionWhite24")
                        case .hero: return #imageLiteral(resourceName: "SessionWhite40")
                    }
                }()
                
                return (
                    Info(
                        imageData: placeholderImage.pngData(),
                        inset: UIEdgeInsets(
                            top: 12,
                            left: 12,
                            bottom: 12,
                            right: 12
                        ),
                        icon: profileIcon,
                        forcedBackgroundColor: .theme(.classicDark, color: .borderSeparator)
                    ),
                    nil
                )
                
            case .legacyGroup, .group:
                guard !publicKey.isEmpty else { return (nil, nil) }
                
                return (
                    Info(
                        imageData: (
                            profile.map { DisplayPictureManager.displayPicture(owner: .user($0)) } ??
                            PlaceholderIcon.generate(
                                seed: publicKey,
                                text: (profile?.displayName(for: threadVariant))
                                    .defaulting(to: publicKey),
                                size: (additionalProfile != nil ?
                                    size.multiImageSize :
                                    size.viewSize
                                )
                            ).pngData()
                        ),
                        icon: profileIcon
                    ),
                    additionalProfile
                        .map { otherProfile in
                            Info(
                                imageData: (
                                    DisplayPictureManager.displayPicture(owner: .user(otherProfile)) ??
                                    PlaceholderIcon.generate(
                                        seed: otherProfile.id,
                                        text: otherProfile.displayName(for: threadVariant),
                                        size: size.multiImageSize
                                    ).pngData()
                                ),
                                icon: additionalProfileIcon
                            )
                        }
                        .defaulting(
                            to: Info(
                                imageData: UIImage(systemName: "person.fill")?.pngData(),
                                renderingMode: .alwaysTemplate,
                                themeTintColor: .white,
                                inset: UIEdgeInsets(
                                    top: 3,
                                    left: 0,
                                    bottom: -5,
                                    right: 0
                                ),
                                icon: additionalProfileIcon
                            )
                        )
                )
                
            case .contact:
                guard !publicKey.isEmpty else { return (nil, nil) }
                
                return (
                    Info(
                        imageData: (
                            profile.map { DisplayPictureManager.displayPicture(owner: .user($0)) } ??
                            PlaceholderIcon.generate(
                                seed: publicKey,
                                text: (profile?.displayName(for: threadVariant))
                                    .defaulting(to: publicKey),
                                size: (additionalProfile != nil ?
                                    size.multiImageSize :
                                    size.viewSize
                                )
                            ).pngData()
                        ),
                        icon: profileIcon
                    ),
                    nil
                )
        }
    }
}
