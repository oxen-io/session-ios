// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public protocol NotificationsProtocol {
    func notifyUser(_ db: Database, for interaction: Interaction, in thread: SessionThread, isBackgroundPoll: Bool)
    func cancelNotifications(identifiers: [String])
    func clearAllNotifications()
}