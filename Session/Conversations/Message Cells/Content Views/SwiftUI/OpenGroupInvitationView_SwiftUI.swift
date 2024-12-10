// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

struct OpenGroupInvitationView_SwiftUI: View {
    private let name: String
    private let url: String
    private let textColor: ThemeValue
    private let isOutgoing: Bool
    
    private static let iconSize: CGFloat = 24
    private static let iconImageViewSize: CGFloat = 48
    
    // stringlint:ignore_contents
    init(
        name: String,
        url: String,
        textColor: ThemeValue,
        isOutgoing: Bool
    ) {
        self.name = name
        self.url = {
            if let range = url.range(of: "?public_key=") {
                return String(url[..<range.lowerBound])
            }

            return url
        }()
        self.textColor = textColor
        self.isOutgoing = isOutgoing
    }
    
    var body: some View {
        HStack(
            alignment: .center,
            spacing: Values.mediumSpacing
        ) {
            // Icon
            if let iconImage = UIImage(named: isOutgoing ? "Globe" : "Plus")?
                .withRenderingMode(.alwaysTemplate)
            {
                Circle()
                    .fill(themeColor: (isOutgoing ? .messageBubble_overlay : .primary))
                    .frame(
                        width: Self.iconImageViewSize,
                        height: Self.iconImageViewSize
                    )
                    .overlay {
                        Image(uiImage: iconImage)
                            .foregroundColor(themeColor: (isOutgoing ? .messageBubble_outgoingText : .textPrimary))
                            .frame(
                                width: Self.iconSize,
                                height: Self.iconSize
                            )
                    }
            }
            
            // Text
            VStack(
                alignment: .leading, 
                spacing: 2
            ) {
                Text(name)
                    .bold()
                    .font(.system(size: Values.largeFontSize))
                    .foregroundColor(themeColor: textColor)
                
                Text("communityInvitation".localized())
                    .font(.system(size: Values.smallFontSize))
                    .foregroundColor(themeColor: textColor)
                    .padding(.bottom, 2)
                
                Text(url)
                    .font(.system(size: Values.verySmallFontSize))
                    .foregroundColor(themeColor: textColor)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.all, Values.mediumSpacing)
    }
}

struct OpenGroupInvitationView_SwiftUI_Previews: PreviewProvider {
    static var previews: some View {
        OpenGroupInvitationView_SwiftUI(
            name: Constants.app_name,
            url: "http://open.getsession.org/session?public_key=a03c383cf63c3c4efe67acc52112a6dd734b3a946b9545f488aaa93da7991238",
            textColor: .messageBubble_outgoingText,
            isOutgoing: true
        )
    }
}
