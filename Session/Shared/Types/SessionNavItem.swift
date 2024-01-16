// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUtilitiesKit

public struct SessionNavItem<Id: Equatable>: Equatable {
    let id: Id
    let image: UIImage?
    let style: UIBarButtonItem.Style
    let systemItem: UIBarButtonItem.SystemItem?
    let accessibilityIdentifier: String
    let accessibilityLabel: String?
    let action: (() -> Void)?
    
    // MARK: - Initialization
    
    public init(
        id: Id,
        systemItem: UIBarButtonItem.SystemItem?,
        accessibilityIdentifier: String,
        accessibilityLabel: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.id = id
        self.image = nil
        self.style = .plain
        self.systemItem = systemItem
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }
    
    public init(
        id: Id,
        image: UIImage?,
        style: UIBarButtonItem.Style,
        accessibilityIdentifier: String,
        accessibilityLabel: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.id = id
        self.image = image
        self.style = style
        self.systemItem = nil
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }
    
    // MARK: - Functions
    
    public func createBarButtonItem() -> DisposableBarButtonItem {
        let result: DisposableBarButtonItem = {
            guard let systemItem: UIBarButtonItem.SystemItem = systemItem else {
                return DisposableBarButtonItem(
                    image: image,
                    style: style,
                    target: nil,
                    action: nil
                )
            }
            
            return DisposableBarButtonItem(
                barButtonSystemItem: systemItem,
                target: nil,
                action: nil
            )
        }()
        result.accessibilityIdentifier = accessibilityIdentifier
        result.accessibilityLabel = accessibilityLabel
        
        return result
    }
    
    // MARK: - Conformance
    
    public static func == (
        lhs: SessionNavItem<Id>,
        rhs: SessionNavItem<Id>
    ) -> Bool {
        return (
            lhs.id == rhs.id &&
            lhs.image == rhs.image &&
            lhs.style == rhs.style &&
            lhs.systemItem == rhs.systemItem &&
            lhs.accessibilityIdentifier == rhs.accessibilityIdentifier
        )
    }
}
