// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionMessagingKit

struct VoiceMessageView_SwiftUI: View {
    @State var isPlaying: Bool = false
    @State var time: String = "0:00"
    @State var speed: String = "1.5×"
    @State var progress: Double = 0.0
    
    private static let width: CGFloat = 160
    private static let toggleContainerSize: CGFloat = 20
    
    private var attachment: Attachment
    
    public init(attachment: Attachment) {
        self.attachment = attachment
    }
    
    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .foregroundColor(themeColor: .messageBubble_overlay)
                .frame(width: Self.width * progress)
            
            HStack(
                alignment: .center,
                spacing: 0
            ) {
                ZStack {
                    Circle()
                        .foregroundColor(themeColor: .backgroundSecondary)
                        .frame(
                            width: Self.toggleContainerSize,
                            height: Self.toggleContainerSize
                        )
                    if let toggleImage: UIImage = UIImage(named: isPlaying ? "Pause" : "Play")?.withRenderingMode(.alwaysTemplate) {
                        Image(uiImage: toggleImage)
                            .resizable()
                            .foregroundColor(themeColor: .textPrimary)
                            .scaledToFit()
                            .frame(
                                width: 8,
                                height: 8
                            )
                    }
                    
                    if attachment.state == .downloading {
                        ActivityIndicator(themeColor: .textPrimary, width: 2)
                            .frame(
                                width: Self.toggleContainerSize,
                                height: Self.toggleContainerSize
                            )
                    }
                }
                
                Rectangle()
                    .foregroundColor(themeColor: .backgroundSecondary)
                    .frame(height: 1)
                
                ZStack {
                    Capsule()
                        .foregroundColor(themeColor: .backgroundSecondary)
                        .frame(
                            width: 44,
                            height: Self.toggleContainerSize
                        )
                    
                    Text(attachment.duration.defaulting(to: 0).formatted(format: .hoursMinutesSeconds))
                        .foregroundColor(themeColor: .textPrimary)
                        .font(.system(size: Values.smallFontSize))
                }
            }
            .padding(.all, Values.smallSpacing)
        }
        .frame(
            width: Self.width
        )
    }
}

struct VoiceMessageView_SwiftUI_Previews: PreviewProvider {
    static var previews: some View {
        VoiceMessageView_SwiftUI(
            attachment: Attachment(
                variant: .voiceMessage,
                contentType: "mp4",
                byteCount: 100
            )
        )
        .frame(height: 58)
    }
}
