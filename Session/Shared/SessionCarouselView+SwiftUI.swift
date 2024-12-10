// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionMessagingKit
import SessionUtilitiesKit

public struct SessionCarouselView_SwiftUI: View {
    @Binding var index: Int
    
    private let dependencies: Dependencies
    let isOutgoing: Bool
    var contentInfos: [Attachment]
    let numberOfPages: Int
    
    public init(index: Binding<Int>, isOutgoing: Bool, contentInfos: [Attachment], using dependencies: Dependencies) {
        self._index = index
        self.dependencies = dependencies
        self.isOutgoing = isOutgoing
        self.contentInfos = contentInfos
        self.numberOfPages = contentInfos.count
        
        let first = self.contentInfos.first!
        let last = self.contentInfos.last!
        self.contentInfos.append(first)
        self.contentInfos.insert(last, at: 0)
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            ArrowView(index: $index, numberOfPages: numberOfPages, type: .decrement)
                .zIndex(1)
            
            PageView(index: $index, numberOfPages: self.numberOfPages) {
                ForEach(self.contentInfos) { attachment in
                    MediaView_SwiftUI(
                        attachment: attachment,
                        isOutgoing: self.isOutgoing,
                        shouldSupressControls: true,
                        cornerRadius: 0,
                        using: dependencies
                    )
                }
            }
            .aspectRatio(1, contentMode: .fit)
            
            ArrowView(index: $index, numberOfPages: numberOfPages, type: .increment)
                .zIndex(1)
        }
    }
}

struct ArrowView: View {
    @Binding var index: Int
    let numberOfPages: Int
    let maxIndex: Int
    let type: ArrowType
    
    enum ArrowType {
        case increment
        case decrement
    }
    
    init(index: Binding<Int>, numberOfPages: Int, type: ArrowType) {
        self._index = index
        self.numberOfPages = numberOfPages
        self.maxIndex = numberOfPages + 1
        self.type = type
    }
    
    var body: some View {
        let imageName = (self.type == .decrement ? "chevron.left" : "chevron.right") // stringlint:ignore
        Button {
            if self.type == .decrement {
                decrement()
            } else {
                increment()
            }
        } label: {
            Image(systemName: imageName)
                .font(.system(size: 20))
                .foregroundColor(themeColor: .textPrimary)
                .frame(width: 30, height: 30)
        }
    }
    
    func decrement() {
        withAnimation(.easeOut) {
            self.index -= 1
        }
        
        if self.index == 0 {
            self.index = self.maxIndex - 1
        }
    }
    
    func increment() {
        withAnimation(.easeOut) {
            self.index += 1
        }
        
        if self.index == self.maxIndex {
            self.index = 1
        }
    }
}

struct PageView<Content>: View where Content: View {
    @Binding var index: Int
    let numberOfPages: Int
    let maxIndex: Int
    let content: () -> Content

    @State private var offset = CGFloat.zero
    @State private var dragging = false

    init(index: Binding<Int>, numberOfPages: Int, @ViewBuilder content: @escaping () -> Content) {
        self._index = index
        self.numberOfPages = numberOfPages
        self.content = content
        self.maxIndex = numberOfPages + 1
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        self.content()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .content.offset(x: self.offset(in: geometry), y: 0)
                .frame(width: geometry.size.width, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .gesture(
                    DragGesture(coordinateSpace: .local)
                        .onChanged { value in
                            self.dragging = true
                            self.offset = -CGFloat(self.index) * geometry.size.width + value.translation.width
                        }
                        .onEnded { value in
                            let predictedEndOffset = -CGFloat(self.index) * geometry.size.width + value.predictedEndTranslation.width
                            let predictedIndex = Int(round(predictedEndOffset / -geometry.size.width))
                            self.index = self.clampedIndex(from: predictedIndex)
                            withAnimation(.easeOut(duration: 0.2)) {
                                self.dragging = false
                            }
                            // FIXME: This is a workaround for withAnimation() not having completion callback
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                switch self.index {
                                    case 0: self.index = self.maxIndex - 1
                                    case self.maxIndex: self.index = 1
                                    default: break
                                }
                            }
                        }
                )
            }
            .clipped()

            PageControl(index: $index, maxIndex: numberOfPages - 1)
                .padding(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
        }
    }

    func offset(in geometry: GeometryProxy) -> CGFloat {
        if self.dragging {
            return max(min(self.offset, 0), -CGFloat(self.maxIndex) * geometry.size.width)
        } else {
            return -CGFloat(self.index) * geometry.size.width
        }
    }

    func clampedIndex(from predictedIndex: Int) -> Int {
        let newIndex = min(max(predictedIndex, self.index - 1), self.index + 1)
        guard newIndex >= 0 else { return 0 }
        guard newIndex <= maxIndex else { return maxIndex }
        return newIndex
    }
}

struct PageControl: View {
    @Binding var index: Int
    let maxIndex: Int

    var body: some View {
        ZStack {
            Capsule()
                .foregroundColor(.init(white: 0, opacity: 0.4))
            HStack(spacing: 4) {
                ForEach(0...maxIndex, id: \.self) { index in
                    Circle()
                        .fill(index == ((self.index - 1) % (self.maxIndex + 1)) ? Color.white : Color.gray)
                        .frame(width: 7, height: 7)
                }
            }
            .padding(6)
        }
        .fixedSize(horizontal: true, vertical: true)
        .frame(
            maxWidth: .infinity,
            maxHeight: 19
        )
    }
}

struct SessionCarouselView_SwiftUI_Previews: PreviewProvider {
    @State static var index = 1
    static var previews: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            SessionCarouselView_SwiftUI(
                index: $index,
                isOutgoing: true,
                contentInfos: [
                    Attachment(
                        variant: .standard,
                        contentType: "jpeg",
                        byteCount: 100
                    ),
                    Attachment(
                        variant: .standard,
                        contentType: "jpeg",
                        byteCount: 100
                    )
                ],
                using: Dependencies.createEmpty()
            )
        }
    }
}
