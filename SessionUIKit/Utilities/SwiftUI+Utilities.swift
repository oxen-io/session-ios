// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import UIKit
import SessionUtilitiesKit

struct ViewControllerHolder {
    weak var value: UIViewController?
}

struct ViewControllerKey: EnvironmentKey {
    static var defaultValue: ViewControllerHolder {
        return ViewControllerHolder(value: SNUIKit.mainWindow.wrappedValue?.rootViewController)
    }
}

extension EnvironmentValues {
    public var viewController: UIViewController? {
        get { return self[ViewControllerKey.self].value }
        set { self[ViewControllerKey.self].value = newValue }
    }
}

public struct UIView_SwiftUI: UIViewRepresentable {
    public typealias UIViewType = UIView
    
    private let view: UIView
    
    public init(view: UIView) {
        self.view = view
    }
    
    public func makeUIView(context: Context) -> UIView {
        return self.view
    }
    
    public func updateUIView(_ uiView: UIView, context: Context) {
        uiView.layoutIfNeeded()
    }
}

// MARK: MaxWidthEqualizer
/// PreferenceKey to report the max width of the view.
struct MaxWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0.0

    // We `reduce` to just take the max value from all values reported.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
    
}

/// Convenience view modifier that observe its size, and notify the value back to parent view via `MaxWidthPreferenceKey`.
public struct MaxWidthNotify: ViewModifier {
    
    /// We embed a transparent background view, to the current view to get the size via `GeometryReader`.
    /// The `MaxWidthPreferenceKey` will be reported, when the frame of this view is updated.
    private var sizeView: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: MaxWidthPreferenceKey.self, value: geometry.frame(in: .global).size.width)
        }
    }
    
    public func body(content: Content) -> some View {
        content.background(sizeView)
    }
    
}

/// Convenience modifier to use in the parent view to observe `MaxWidthPreferenceKey` from children, and bind the value to `$width`.
public struct MaxWidthEqualizer: ViewModifier {
    @Binding var width: CGFloat?
    
    public static var notify: MaxWidthNotify {
        MaxWidthNotify()
    }
    
    public init(width: Binding<CGFloat?>) {
        self._width = width
    }
    
    public func body(content: Content) -> some View {
        content.onPreferenceChange(MaxWidthPreferenceKey.self) { value in
            let oldWidth: CGFloat = width ?? 0
            if value > oldWidth {
                width = value
            }
        }
    }
}
