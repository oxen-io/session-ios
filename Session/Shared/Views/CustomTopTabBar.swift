// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit

struct TabBarButton: View {
    @Binding var isSelected: Bool
    
    let text: String
    
    var body: some View {
        ZStack(
            alignment: .bottom
        ) {
            Text(text)
                .bold()
                .font(.system(size: Values.mediumFontSize))
                .foregroundColor(themeColor: .textPrimary)
                .padding(.bottom, 5)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
            if isSelected {
                Rectangle()
                    .foregroundColor(themeColor: .primary)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: 5
                    )
                    .padding(.horizontal, Values.verySmallSpacing)
            }
            
        }
    }
}

struct CustomTopTabBar: View {
    @Binding var tabIndex: Int
    let tabTitles: [String]
    
    private static let height = isIPhone5OrSmaller ? CGFloat(32) : CGFloat(48)
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<tabTitles.count, id: \.self) { index in
                TabBarButton(
                    isSelected: .constant(tabIndex == index),
                    text: tabTitles[index]
                )
                .onTapGesture { onButtonTapped(index: index) }
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: Self.height
        )
        .border(width: 1, edges: [.bottom], color: .borderSeparator)
    }
    
    private func onButtonTapped(index: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            tabIndex = index
        }
    }
}
