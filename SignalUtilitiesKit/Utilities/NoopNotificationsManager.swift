// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionMessagingKit
import SessionUtilitiesKit

public class NoopNotificationsManager: NotificationsProtocol {
    public init() {}
    
    public func notifyUser(_ db: Database, for interaction: Interaction, in thread: SessionThread, applicationState: UIApplication.State) {
        Log.error("[NoopNotificationsManager] \(#function) called")
    }
    
    public func notifyUser(_ db: Database, forIncomingCall interaction: Interaction, in thread: SessionThread, applicationState: UIApplication.State) {
        Log.error("[NoopNotificationsManager] \(#function) called")
    }
    
    public func notifyUser(_ db: Database, forReaction reaction: Reaction, in thread: SessionThread, applicationState: UIApplication.State) {
        Log.error("[NoopNotificationsManager] \(#function) called")
    }
    
    public func cancelNotifications(identifiers: [String]) {
        Log.error("[NoopNotificationsManager] \(#function) called")
    }

    public func clearAllNotifications() {
        Log.warn("[NoopNotificationsManager] \(#function) called")
    }
}
