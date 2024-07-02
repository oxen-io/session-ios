// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionMessagingKit

struct DocumentView_SwiftUI: View {
    @Binding private var maxWidth: CGFloat?
    
    static private let inset: CGFloat = 12
    
    private let attachment: Attachment
    private let textColor: ThemeValue
    
    public init(maxWidth: Binding<CGFloat?>, attachment: Attachment, textColor: ThemeValue) {
        self._maxWidth = maxWidth
        self.attachment = attachment
        self.textColor = textColor
    }
    
    var body: some View {
        HStack(
            alignment: .center,
            spacing: 0
        ) {
            ZStack {
                Image(systemName: "doc")
                    .font(.system(size: Values.largeFontSize))
                    .foregroundColor(themeColor: textColor)

                if attachment.isAudio {
                    Image(systemName: "music.note")
                        .resizable()
                        .renderingMode(.template)
                        .foregroundColor(themeColor: textColor)
                        .scaledToFit()
                        .frame(
                            width: 7,
                            height: 20,
                            alignment: .bottom
                        )
                }
            }
            .frame(
                width: 24 + Values.mediumSpacing * 2,
                height: 32 + Values.smallSpacing * 2
            )
            .backgroundColor(themeColor: .messageBubble_overlay)

            VStack(
                alignment: .leading
            ) {
                Text(attachment.documentFileName)
                    .lineLimit(1)
                    .font(.system(size: Values.mediumFontSize))
                    .foregroundColor(themeColor: textColor)
                    .frame(
                        maxWidth: maxWidth,
                        alignment: .leading
                    )
                
                Text(attachment.documentFileInfo)
                    .font(.system(size: Values.verySmallFontSize))
                    .foregroundColor(themeColor: textColor)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Values.mediumSpacing)
            
            Image(systemName: (attachment.isAudio ? "play.fill" : "arrow.down"))
                .font(.system(size: Values.mediumFontSize))
                .foregroundColor(themeColor: textColor)
                .padding(.trailing, Self.inset)
        }
        .frame(width: maxWidth)
    }
}

struct DocumentView_SwiftUI_Previews: PreviewProvider {
    @State static private var maxWidth: CGFloat? = 200
    
    static var previews: some View {
        VStack {
            DocumentView_SwiftUI(
                maxWidth: $maxWidth,
                attachment: Attachment(
                    variant: .standard,
                    contentType: "audio/mp4",
                    byteCount: 100
                ),
                textColor: .messageBubble_outgoingText
            )
            .frame(height: 58)
            
            DocumentView_SwiftUI(
                maxWidth: $maxWidth,
                attachment: Attachment(
                    variant: .standard,
                    contentType: "txt",
                    byteCount: 1000
                ),
                textColor: .messageBubble_outgoingText
            )
            .frame(height: 58)
        }
    }
}
