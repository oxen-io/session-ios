// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit

public struct ActivityIndicator: View {
    @State private var strokeStart: Double = 0.95
    @State private var strokeEnd: Double = 1.0
    @State private var shorten: Bool = false
    @State private var isRotating: Bool = false
    
    private var themeColor: ThemeValue
    private var width: CGFloat
    
    public init(themeColor: ThemeValue, width: CGFloat) {
        self.themeColor = themeColor
        self.width = width
    }

    public var body: some View {
        GeometryReader { (geometry: GeometryProxy) in
            Circle()
                .trim(from: strokeStart, to: strokeEnd)
                .stroke(
                    themeColor: themeColor,
                    style: StrokeStyle(
                        lineWidth: width,
                        lineCap: .round
                    )
                )
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height
                )
                .rotationEffect(!self.isRotating ? .degrees(0) : .degrees(360))
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            withAnimation(
                Animation
                    .timingCurve(0.4, 0.0, 0.2, 1.0, duration: 1.5)
                    .repeatForever(autoreverses: false)
            ) {
                self.isRotating = true
            }
            
            self.trimStroke()
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                self.trimStroke()
            }
        }
    }
    
    private func trimStroke() {
        self.shorten = !self.shorten
        
        if self.shorten {
            self.strokeStart = 0.0
            self.strokeEnd = 1.0
        } else {
            self.strokeStart = 0.0
            self.strokeEnd = 0.0
        }
        
        withAnimation(.linear(duration: 1.5)) {
            if self.shorten {
                self.strokeStart = 1.0
            } else {
                self.strokeEnd = 1.0
            }
        }
    }
}

struct ActivityIndicator_Previews: PreviewProvider {
    static var previews: some View {
        ActivityIndicator(themeColor: .textPrimary, width: 2)
            .frame(
                width: 40,
                height: 40
            )
    }
}
