// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import UIKit

struct ViewControllerHolder {
    weak var value: UIViewController?
}

struct ViewControllerKey: EnvironmentKey {
    static var defaultValue: ViewControllerHolder {
        return ViewControllerHolder(value: SNUIKit.mainWindow?.rootViewController)
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

// MARK: - MaxWidthEqualizer

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

public struct Line: View {
    let color: ThemeValue
    
    public init(color: ThemeValue) {
        self.color = color
    }
    
    public var body: some View {
        Rectangle()
            .fill(themeColor: color)
            .frame(height: 1)
    }
}

struct EdgeBorder: Shape {
    
    var width: CGFloat
    var edges: [Edge]
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for edge in edges {
            var x: CGFloat {
                switch edge {
                case .top, .bottom, .leading: return rect.minX
                case .trailing: return rect.maxX - width
                }
            }
            
            var y: CGFloat {
                switch edge {
                case .top, .leading, .trailing: return rect.minY
                case .bottom: return rect.maxY - width
                }
            }
            
            var w: CGFloat {
                switch edge {
                case .top, .bottom: return rect.width
                case .leading, .trailing: return self.width
                }
            }
            
            var h: CGFloat {
                switch edge {
                case .top, .bottom: return self.width
                case .leading, .trailing: return rect.height
                }
            }
            path.addPath(Path(CGRect(x: x, y: y, width: w, height: h)))
        }
        return path
    }
}

extension View {
    public func border(width: CGFloat, edges: [Edge], color: ThemeValue) -> some View {
        overlay(
            EdgeBorder(width: width, edges: edges)
                .foregroundColor(themeColor: color)
        )
    }
    
    public func toastView(message: Binding<String?>) -> some View {
        self.modifier(ToastModifier(message: message))
    }
    
    public func textViewTransparentScrolling() -> some View {
        if #available(iOS 16.0, *) {
            return scrollContentBackground(.hidden)
        } else {
            return onAppear {
                UITextView.appearance().backgroundColor = .clear
            }
        }
    }
    
    public func transparentListBackground() -> some View {
        if #available(iOS 16.0, *) {
            return scrollContentBackground(.hidden)
        } else {
            return onAppear {
                UITableView.appearance().backgroundColor = .clear
            }
        }
    }
    
    public func accessibility(_ accessibility: Accessibility) -> some View {
        if #available(iOSApplicationExtension 14.0, *) {
            guard let identifier = accessibility.identifier else {
                return self
            }
            return accessibilityIdentifier(identifier).accessibilityLabel(accessibility.label ?? "")
        } else {
            return self
        }
    }
}

extension Binding {
    public func onChange(_ handler: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(
            get: { self.wrappedValue },
            set: { newValue in
                handler(newValue)
                self.wrappedValue = newValue
            }
        )
    }
}
