// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionMessagingKit
import SessionUtilitiesKit

public class MockNotificationsManager: Mock<NotificationsManagerType>, NotificationsManagerType {
    public required init(using dependencies: Dependencies) {
        super.init()
        
        mockNoReturn(untrackedArgs: [dependencies])
    }
    
    internal required init(functionHandler: MockFunctionHandler? = nil, initialSetup: ((Mock<NotificationsManagerType>) -> ())? = nil) {
        super.init(functionHandler: functionHandler, initialSetup: initialSetup)
    }
    
    public func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        mockNoReturn(args: [delegate])
    }
    
    public func registerNotificationSettings() -> AnyPublisher<Void, Never> {
        return mock()
    }
    
    public func notifyUser(
        _ db: Database,
        for interaction: Interaction,
        in thread: SessionThread,
        applicationState: UIApplication.State
    ) {
        mockNoReturn(args: [interaction, thread, applicationState], untrackedArgs: [db])
    }
    
    public func notifyUser(
        _ db: Database,
        forIncomingCall interaction: Interaction,
        in thread: SessionThread,
        applicationState: UIApplication.State
    ) {
        mockNoReturn(args: [interaction, thread, applicationState], untrackedArgs: [db])
    }
    
    public func notifyUser(
        _ db: Database,
        forReaction reaction: Reaction,
        in thread: SessionThread,
        applicationState: UIApplication.State
    ) {
        mockNoReturn(args: [reaction, thread, applicationState], untrackedArgs: [db])
    }
    
    public func notifyForFailedSend(_ db: Database, in thread: SessionThread, applicationState: UIApplication.State) {
        mockNoReturn(args: [thread, applicationState], untrackedArgs: [db])
    }
    
    public func cancelNotifications(identifiers: [String]) {
        mockNoReturn(args: [identifiers])
    }
    
    public func clearAllNotifications() {
        mockNoReturn()
    }
}
