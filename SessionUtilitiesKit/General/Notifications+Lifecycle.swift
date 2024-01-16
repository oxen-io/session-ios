// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Notification.Name {
    static let sessionDidEnterBackground = Notification.Name("sessionDidEnterBackground")
    static let sessionWillEnterForeground = Notification.Name("sessionWillEnterForeground")
    static let sessionWillResignActive = Notification.Name("sessionWillResignActive")
    static let sessionDidBecomeActive = Notification.Name("sessionDidBecomeActive")
}

@objc public extension NSNotification {
    @objc static let sessionDidEnterBackground = Notification.Name.sessionDidEnterBackground.rawValue as NSString
    @objc static let sessionWillEnterForeground = Notification.Name.sessionWillEnterForeground.rawValue as NSString
    @objc static let sessionWillResignActive = Notification.Name.sessionWillResignActive.rawValue as NSString
    @objc static let sessionDidBecomeActive = Notification.Name.sessionDidBecomeActive.rawValue as NSString
}
