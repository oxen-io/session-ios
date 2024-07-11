// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import UIKit

public struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    
    public init(items: [Any]) {
        self.items = items
    }

    public func makeUIViewController(context: UIViewControllerRepresentableContext<ActivityView>) -> UIActivityViewController {
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: UIViewControllerRepresentableContext<ActivityView>) {}
}
