// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let notificationsManager: SingletonConfig<NotificationsManagerType> = Dependencies.create(
        identifier: "notificationsManager",
        createInstance: { dependencies in NoopNotificationsManager(using: dependencies) }
    )
}

// MARK: - NotificationsManagerType

public protocol NotificationsManagerType {
    init(using dependencies: Dependencies)
    
    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?)
    func registerNotificationSettings() -> AnyPublisher<Void, Never>
    
    func notifyUser(
        _ db: Database,
        for interaction: Interaction,
        in thread: SessionThread,
        applicationState: UIApplication.State
    )
    
    func notifyUser(_ db: Database, forIncomingCall interaction: Interaction, in thread: SessionThread, applicationState: UIApplication.State)
    func notifyUser(_ db: Database, forReaction reaction: Reaction, in thread: SessionThread, applicationState: UIApplication.State)
    func notifyForFailedSend(_ db: Database, in thread: SessionThread, applicationState: UIApplication.State)
    
    func cancelNotifications(identifiers: [String])
    func clearAllNotifications()
}

// MARK: - NoopNotificationsManager

public struct NoopNotificationsManager: NotificationsManagerType {
    public init(using dependencies: Dependencies) {}
    
    public func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {}
    
    public func registerNotificationSettings() -> AnyPublisher<Void, Never> {
        return Just(()).eraseToAnyPublisher()
    }
    
    public func notifyUser(
        _ db: Database,
        for interaction: Interaction,
        in thread: SessionThread,
        applicationState: UIApplication.State
    ) {}
    public func notifyUser(_ db: Database, forIncomingCall interaction: Interaction, in thread: SessionThread, applicationState: UIApplication.State) {}
    public func notifyUser(_ db: Database, forReaction reaction: Reaction, in thread: SessionThread, applicationState: UIApplication.State) {}
    public func notifyForFailedSend(_ db: Database, in thread: SessionThread, applicationState: UIApplication.State) {}
    
    public func cancelNotifications(identifiers: [String]) {}
    public func clearAllNotifications() {}
}

// MARK: - Notifications

public enum Notifications {
    /// Delay notification of incoming messages when we want to group them (eg. during background polling) to avoid
    /// firing too many notifications at the same time
    public static let delayForGroupedNotifications: TimeInterval = 5
}
