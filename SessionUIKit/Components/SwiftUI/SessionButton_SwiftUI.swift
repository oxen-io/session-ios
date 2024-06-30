// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

struct SessionButton_SwiftUI: View {
    public enum Style {
        case bordered
        case borderless
        case destructive
        case destructiveBorderless
        case filled
    }
    
    public enum Size {
        case small
        case medium
        case large
    }
    
    public struct Info: Equatable {
        public let style: Style
        public let title: String
        public let isEnabled: Bool
        public let accessibility: Accessibility?
        public let minWidth: CGFloat
        public let onTap: () -> ()
        
        public init(
            style: Style,
            title: String,
            isEnabled: Bool = true,
            accessibility: Accessibility? = nil,
            minWidth: CGFloat = 0,
            onTap: @escaping () -> ()
        ) {
            self.style = style
            self.title = title
            self.isEnabled = isEnabled
            self.accessibility = accessibility
            self.onTap = onTap
            self.minWidth = minWidth
        }
        
        public static func == (lhs: SessionButton_SwiftUI.Info, rhs: SessionButton_SwiftUI.Info) -> Bool {
            return (
                lhs.style == rhs.style &&
                lhs.title == rhs.title &&
                lhs.isEnabled == rhs.isEnabled &&
                lhs.accessibility == rhs.accessibility &&
                lhs.minWidth == rhs.minWidth
            )
        }
    }
    
    private let info: SessionButton_SwiftUI.Info
    
    init(info: SessionButton_SwiftUI.Info) {
        self.info = info
    }
    
    var body: some View {
        Text(/*@START_MENU_TOKEN@*/"Hello, World!"/*@END_MENU_TOKEN@*/)
    }
}

#Preview {
    SessionButton_SwiftUI(
        info: .init(
            style: .bordered,
            title: "Test",
            onTap: {}
        )
    )
}
