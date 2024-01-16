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
        // If we are given an explicit 'displayPictureFilename' then only use that (this could be for
        // either Community conversations or updated groups)
        if let displayPictureFilename: String = displayPictureFilename {
            update(
                Info(
                    imageData: DisplayPictureManager.displayPicture(owner: .file(displayPictureFilename)),
                    icon: profileIcon
                )
            )
            return
        }
        
        // Otherwise there are conversation-type-specific behaviours
        switch threadVariant {
            case .community:
                let placeholderImage: UIImage = {
                    switch self.size {
                        case .navigation, .message: return #imageLiteral(resourceName: "SessionWhite16")
                        case .list: return #imageLiteral(resourceName: "SessionWhite24")
                        case .hero: return #imageLiteral(resourceName: "SessionWhite40")
                    }
                }()
                
                update(
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
                    )
                )
                
            case .legacyGroup, .group:
                guard !publicKey.isEmpty else { return }
                
                update(
                    Info(
                        imageData: (
                            profile.map { DisplayPictureManager.displayPicture(owner: .user($0)) } ??
                            PlaceholderIcon.generate(
                                seed: publicKey,
                                text: (profile?.displayName(for: threadVariant))
                                    .defaulting(to: publicKey),
                                size: (additionalProfile != nil ?
                                    self.size.multiImageSize :
                                    self.size.viewSize
                                )
                            ).pngData()
                        ),
                        icon: profileIcon
                    ),
                    additionalInfo: additionalProfile
                        .map { otherProfile in
                            Info(
                                imageData: (
                                    DisplayPictureManager.displayPicture(owner: .user(otherProfile)) ??
                                    PlaceholderIcon.generate(
                                        seed: otherProfile.id,
                                        text: otherProfile.displayName(for: threadVariant),
                                        size: self.size.multiImageSize
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
                guard !publicKey.isEmpty else { return }
                
                update(
                    Info(
                        imageData: (
                            profile.map { DisplayPictureManager.displayPicture(owner: .user($0)) } ??
                            PlaceholderIcon.generate(
                                seed: publicKey,
                                text: (profile?.displayName(for: threadVariant))
                                    .defaulting(to: publicKey),
                                size: (additionalProfile != nil ?
                                    self.size.multiImageSize :
                                    self.size.viewSize
                                )
                            ).pngData()
                        ),
                        icon: profileIcon
                    )
                )
        }
    }
}
