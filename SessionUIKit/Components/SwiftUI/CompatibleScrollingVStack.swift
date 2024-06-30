// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct CompatibleScrollingVStack<Content> : View where Content : View {
    let alignment: HorizontalAlignment
    let spacing: CGFloat?
    let content: () -> Content

    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
            @ViewBuilder content: @escaping () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: alignment, spacing: spacing, pinnedViews: [], content:content)
        }
    }
}
