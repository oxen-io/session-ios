// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Combine

public struct ToastModifier: ViewModifier {
    @Binding var message: String?
    @State private var workItem: DispatchWorkItem?
    
    public func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                ZStack {
                    mainToastView()
                }.animation(.spring(), value: message)
            )
            .onReceive(Just(message)) { value in
                showToast()
            }
    }
  
    @ViewBuilder func mainToastView() -> some View {
        if let message: String = message {
            ToastView_SwiftUI(message)
        }
    }
  
    private func showToast() {
        workItem?.cancel()
  
        let task = DispatchWorkItem {
            dismissToast()
        }
  
        workItem = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }
  
    private func dismissToast() {
        withAnimation {
            message = nil
        }
    
        workItem?.cancel()
        workItem = nil
    }
}

public struct ToastView_SwiftUI: View {
    var message: String
    
    static let width: CGFloat = 320
    static let height: CGFloat = 44
    
    public init(_ message: String) {
        self.message = message
    }
    
    public var body: some View {
        VStack(
            spacing: 0
        ) {
            ZStack {
                Capsule()
                    .foregroundColor(themeColor: .toast_background)
                
                Text(message)
                    .font(.system(size: Values.verySmallFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Values.mediumSpacing)
            }
            .frame(
                width: Self.width,
                height: Self.height
            )
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .bottom
        )
        .padding(.bottom, Values.smallSpacing)
    }
}

struct Toast_Previews: PreviewProvider {
    static var previews: some View {
        ToastView_SwiftUI("Test message.")
    }
}
