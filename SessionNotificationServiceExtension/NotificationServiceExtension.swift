// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import CallKit
import UserNotifications
import BackgroundTasks
import SessionMessagingKit
import SignalUtilitiesKit
import SignalCoreKit
import SessionUtilitiesKit

public final class NotificationServiceExtension: UNNotificationServiceExtension {
    private var didPerformSetup = false
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var request: UNNotificationRequest?
    private var openGroupPollCancellable: AnyCancellable?

    public static let isFromRemoteKey = "remote"    // stringlint:disable
    public static let threadIdKey = "Signal.AppNotificationsUserInfoKey.threadId"    // stringlint:disable
    public static let threadVariantRaw = "Signal.AppNotificationsUserInfoKey.threadVariantRaw"    // stringlint:disable
    public static let threadNotificationCounter = "Session.AppNotificationsUserInfoKey.threadNotificationCounter"    // stringlint:disable
    private static let callPreOfferLargeNotificationSupressionDuration: TimeInterval = 30

    // MARK: Did receive a remote push notification request
    
    override public func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        self.request = request
        
        // Called via the OS so create a default 'Dependencies' instance
        let dependencies: Dependencies = Dependencies()
        
        guard let notificationContent = request.content.mutableCopy() as? UNMutableNotificationContent else {
            return self.completeSilenty(using: dependencies)
        }

        // Abort if the main app is running
        guard !dependencies[defaults: .appGroup, key: .isMainAppActive] else {
            return self.completeSilenty(using: dependencies)
        }
        
        /// Create the context if we don't have it (needed before _any_ interaction with the database)
        if !dependencies.hasInitialised(singleton: .appContext) {
            dependencies.set(singleton: .appContext, to: NotificationServiceExtensionContext())
            Dependencies.setIsRTLRetriever(requiresMainThread: false) {
                NotificationServiceExtensionContext.determineDeviceRTL()
            }
        }
        
        let isCallOngoing: Bool = dependencies[defaults: .appGroup, key: .isCallOngoing]
        let lastCallPreOffer: Date? = dependencies[defaults: .appGroup, key: .lastCallPreOffer]

        // Perform main setup
        Storage.resumeDatabaseAccess(using: dependencies)
        DispatchQueue.main.sync { self.setUpIfNecessary(using: dependencies) }

        // Handle the push notification
        dependencies[singleton: .appReadiness].runNowOrWhenAppDidBecomeReady {
            let openGroupPollingPublishers: [AnyPublisher<Void, Error>] = self.pollForOpenGroups(using: dependencies)
            defer {
                self.openGroupPollCancellable = Publishers
                    .MergeMany(openGroupPollingPublishers)
                    .subscribe(on: DispatchQueue.global(qos: .background))
                    .subscribe(on: DispatchQueue.main)
                    .sink(
                        receiveCompletion:  { [weak self] _ in self?.completeSilenty(using: dependencies) },
                        receiveValue: { _ in }
                    )
            }
            
            let (maybeData, metadata, result) = PushNotificationAPI.processNotification(
                notificationContent: notificationContent,
                using: dependencies
            )
            
            guard
                (result == .success || result == .legacySuccess),
                let data: Data = maybeData
            else {
                switch result {
                    // If we got an explicit failure, or we got a success but no content then show
                    // the fallback notification
                    case .success, .legacySuccess, .failure, .legacyFailure:
                        return self.handleFailure(for: notificationContent, error: .processing(result))
                        
                    case .successTooLong:
                        /// If the notification is too long and there is an ongoing call or a recent call pre-offer then we assume the notification
                        /// is a call `ICE_CANDIDATES` message and just complete silently (because the fallback would be annoying), if not
                        /// then we do want to show the fallback notification
                        guard
                            isCallOngoing ||
                            (lastCallPreOffer ?? Date.distantPast).timeIntervalSinceNow < NotificationServiceExtension.callPreOfferLargeNotificationSupressionDuration
                        else { return self.handleFailure(for: notificationContent, error: .processing(result)) }
                        
                        NSLog("[NotificationServiceExtension] Suppressing large notification too close to a call.")
                        return
                        
                    case .legacyForceSilent, .failureNoContent: return
                }
            }
            
            // HACK: It is important to use write synchronously here to avoid a race condition
            // where the completeSilenty() is called before the local notification request
            // is added to notification center
            dependencies[singleton: .storage].write { db in
                do {
                    guard let processedMessage: ProcessedMessage = try Message.processRawReceivedMessageAsNotification(db, data: data, metadata: metadata, using: dependencies) else {
                        self.handleFailure(for: notificationContent, error: .messageProcessing)
                        return
                    }
                    
                    switch processedMessage {
                        /// Custom handle config messages (as they don't get handled by the normal `MessageReceiver.handle` call
                        case .config(let publicKey, let namespace, let serverHash, let serverTimestampMs, let data):
                            try LibSession.handleConfigMessages(
                                db,
                                sessionIdHexString: publicKey,
                                messages: [
                                    ConfigMessageReceiveJob.Details.MessageInfo(
                                        namespace: namespace,
                                        serverHash: serverHash,
                                        serverTimestampMs: serverTimestampMs,
                                        data: data
                                    )
                                ]
                            )
                            
                        /// Due to the way the `CallMessage` works we need to custom handle it's behaviour within the notification
                        /// extension, for all other message types we want to just use the standard `MessageReceiver.handle` call
                        case .standard(let threadId, let threadVariant, _, let messageInfo) where messageInfo.message is CallMessage:
                            guard let callMessage = messageInfo.message as? CallMessage else {
                                return self.completeSilenty(using: dependencies)
                            }
                            
                            // Throw if the message is outdated and shouldn't be processed
                            try MessageReceiver.throwIfMessageOutdated(
                                db,
                                message: messageInfo.message,
                                threadId: threadId,
                                threadVariant: threadVariant
                            )
                            
                            try MessageReceiver.handleCallMessage(
                                db,
                                threadId: threadId,
                                threadVariant: threadVariant,
                                message: callMessage
                            )
                            
                            guard case .preOffer = callMessage.kind else {
                                return self.completeSilenty(using: dependencies)
                            }
                            
                            switch (db[.areCallsEnabled], isCallOngoing) {
                                case (false, _):
                                    if
                                        let sender: String = callMessage.sender,
                                        let interaction: Interaction = try MessageReceiver.insertCallInfoMessage(
                                            db,
                                            for: callMessage,
                                            state: .permissionDenied
                                        )
                                    {
                                        let thread: SessionThread = try SessionThread
                                            .fetchOrCreate(
                                                db,
                                                id: sender,
                                                variant: .contact,
                                                shouldBeVisible: nil,
                                                calledFromConfigHandling: false,
                                                using: dependencies
                                            )

                                        // Notify the user if the call message wasn't already read
                                        if !interaction.wasRead {
                                            dependencies[singleton: .notificationsManager].notifyUser(
                                                db,
                                                forIncomingCall: interaction,
                                                in: thread,
                                                applicationState: .background
                                            )
                                        }
                                    }
                                    
                                case (true, true):
                                    try MessageReceiver.handleIncomingCallOfferInBusyState(
                                        db,
                                        message: callMessage
                                    )
                                    
                                case (true, false):
                                    try MessageReceiver.insertCallInfoMessage(db, for: callMessage)
                                    self.handleSuccessForIncomingCall(db, for: callMessage, using: dependencies)
                            }
                            
                            // Perform any required post-handling logic
                            try MessageReceiver.postHandleMessage(
                                db,
                                threadId: threadId,
                                message: messageInfo.message,
                                using: dependencies
                            )
                            
                        case .standard(let threadId, let threadVariant, let proto, let messageInfo):
                            try MessageReceiver.handle(
                                db,
                                threadId: threadId,
                                threadVariant: threadVariant,
                                message: messageInfo.message,
                                serverExpirationTimestamp: messageInfo.serverExpirationTimestamp,
                                associatedWithProto: proto
                            )
                    }
                }
                catch {
                    if let error = error as? MessageReceiverError, error.isRetryable {
                        switch error {
                            case .invalidGroupPublicKey, .noGroupKeyPair, .outdatedMessage:
                                self.completeSilenty(using: dependencies)
                            
                            default: self.handleFailure(for: notificationContent, error: .messageHandling(error))
                        }
                    }
                }
            }
        }
    }

    // MARK: Setup

    private func setUpIfNecessary(
        using dependencies: Dependencies,
        completion: @escaping () -> Void = {}
    ) {
        AssertIsOnMainThread()

        // The NSE will often re-use the same process, so if we're
        // already set up we want to do nothing; we're already ready
        // to process new messages.
        guard !didPerformSetup else { return }

        NSLog("[NotificationServiceExtension] Performing setup")
        didPerformSetup = true

        AppVersion.configure(using: dependencies)
        Cryptography.seedRandom()

        AppSetup.setupEnvironment(
            retrySetupIfDatabaseInvalid: true,
            appSpecificBlock: {
                /// The `NotificationServiceExtension` needs custom behaviours for it's notification presenter so set it up here
                dependencies.set(singleton: .notificationsManager, to: NSENotificationPresenter())
            },
            migrationsCompletion: { [weak self] result, needsConfigSync in
                switch result {
                    // Only 'NSLog' works in the extension - viewable via Console.app
                    case .failure(let error):
                        NSLog("[NotificationServiceExtension] Failed to complete migrations: \(error)")
                        self?.completeSilenty(using: dependencies)
                        
                    case .success:
                        // We should never receive a non-voip notification on an app that doesn't support
                        // app extensions since we have to inform the service we wanted these, so in theory
                        // this path should never occur. However, the service does have our push token
                        // so it is possible that could change in the future. If it does, do nothing
                        // and don't disturb the user. Messages will be processed when they open the app.
                        guard dependencies[singleton: .storage, key: .isReadyForAppExtensions] else {
                            NSLog("[NotificationServiceExtension] Not ready for extensions")
                            self?.completeSilenty(using: dependencies)
                            return
                        }
                        
                        DispatchQueue.main.async {
                            self?.versionMigrationsDidComplete(
                                needsConfigSync: needsConfigSync,
                                using: dependencies
                            )
                        }
                }
                
                completion()
            },
            using: dependencies
        )
    }
    
    private func versionMigrationsDidComplete(
        needsConfigSync: Bool,
        using dependencies: Dependencies
    ) {
        AssertIsOnMainThread()

        // If we need a config sync then trigger it now
        if needsConfigSync {
            dependencies[singleton: .storage].write { db in
                ConfigurationSyncJob.enqueue(
                    db,
                    sessionIdHexString: getUserSessionId(db, using: dependencies).hexString,
                    using: dependencies
                )
            }
        }

        checkIsAppReady(migrationsCompleted: true, using: dependencies)
    }

    private func checkIsAppReady(
        migrationsCompleted: Bool,
        using dependencies: Dependencies
    ) {
        AssertIsOnMainThread()

        // Only mark the app as ready once.
        guard !dependencies[singleton: .appReadiness].isAppReady else { return }

        // App isn't ready until storage is ready AND all version migrations are complete.
        guard dependencies[singleton: .storage].isValid && migrationsCompleted else {
            NSLog("[NotificationServiceExtension] Storage invalid")
            self.completeSilenty(using: dependencies)
            return
        }

        SignalUtilitiesKit.Configuration.performMainSetup(using: dependencies)

        // Note that this does much more than set a flag; it will also run all deferred blocks.
        dependencies[singleton: .appReadiness].setAppReady()
    }
    
    // MARK: Handle completion
    
    override public func serviceExtensionTimeWillExpire() {
        // Called via the OS so create a default 'Dependencies' instance
        let dependencies: Dependencies = Dependencies()
        
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        NSLog("[NotificationServiceExtension] Execution time expired")
        openGroupPollCancellable?.cancel()
        completeSilenty(using: dependencies)
    }
    
    private func completeSilenty(using dependencies: Dependencies) {
        NSLog("[NotificationServiceExtension] Complete silently")
        let silentContent: UNMutableNotificationContent = UNMutableNotificationContent()
        silentContent.badge = dependencies[singleton: .storage]
            .read { db in try Interaction.fetchUnreadCount(db, using: dependencies) }
            .map { NSNumber(value: $0) }
            .defaulting(to: NSNumber(value: 0))
        Storage.suspendDatabaseAccess()
        
        self.contentHandler!(silentContent)
    }
    
    private func handleSuccessForIncomingCall(
        _ db: Database,
        for callMessage: CallMessage,
        using dependencies: Dependencies
    ) {
        if #available(iOSApplicationExtension 14.5, *), Preferences.isCallKitSupported {
            guard let caller: String = callMessage.sender, let timestamp = callMessage.sentTimestamp else { return }
            
            let payload: JSON = [
                "uuid": callMessage.uuid,
                "caller": caller,
                "timestamp": timestamp
            ]
            
            CXProvider.reportNewIncomingVoIPPushPayload(payload) { error in
                if let error = error {
                    self.handleFailureForVoIP(db, for: callMessage)
                    NSLog("[NotificationServiceExtension] Failed to notify main app of call message: \(error)")
                }
                else {
                    NSLog("[NotificationServiceExtension] Successfully notified main app of call message.")
                    dependencies[defaults: .appGroup, key: .lastCallPreOffer] = Date()
                    self.completeSilenty(using: dependencies)
                }
            }
        }
        else {
            self.handleFailureForVoIP(db, for: callMessage)
        }
    }
    
    private func handleFailureForVoIP(_ db: Database, for callMessage: CallMessage) {
        let notificationContent = UNMutableNotificationContent()
        notificationContent.userInfo = [ NotificationServiceExtension.isFromRemoteKey : true ]
        notificationContent.title = "Session"
        notificationContent.badge = (try? Interaction.fetchUnreadCount(db))
            .map { NSNumber(value: $0) }
            .defaulting(to: NSNumber(value: 0))
        
        if let sender: String = callMessage.sender {
            let senderDisplayName: String = Profile.displayName(db, id: sender, threadVariant: .contact)
            notificationContent.body = "\(senderDisplayName) is calling..."
        }
        else {
            notificationContent.body = "Incoming call..."
        }
        
        let identifier = self.request?.identifier ?? UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: notificationContent, trigger: nil)
        let semaphore = DispatchSemaphore(value: 0)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("[NotificationServiceExtension] Failed to add notification request due to error: \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        NSLog("[NotificationServiceExtension] Add remote notification request")
    }

    private func handleFailure(for content: UNMutableNotificationContent, error: NotificationError) {
        NSLog("[NotificationServiceExtension] Show generic failure message due to error: \(error)")
        Storage.suspendDatabaseAccess()
        
        content.title = "Session"
        content.body = "APN_Message".localized()
        let userInfo: [String: Any] = [ NotificationServiceExtension.isFromRemoteKey: true ]
        content.userInfo = userInfo
        contentHandler!(content)
    }
    
    // MARK: - Poll for open groups
    
    private func pollForOpenGroups(
        using dependencies: Dependencies
    ) -> [AnyPublisher<Void, Error>] {
        return dependencies[singleton: .storage]
            .read { db in
                // The default room promise creates an OpenGroup with an empty `roomToken` value,
                // we don't want to start a poller for this as the user hasn't actually joined a room
                try OpenGroup
                    .select(.server)
                    .filter(OpenGroup.Columns.roomToken != "")
                    .filter(OpenGroup.Columns.isActive)
                    .distinct()
                    .asRequest(of: String.self)
                    .fetchSet(db)
            }
            .defaulting(to: [])
            .map { server -> AnyPublisher<Void, Error> in
                OpenGroupAPI.Poller(for: server)
                    .poll(calledFromBackgroundPoller: true, isPostCapabilitiesRetry: false)
                    .timeout(
                        .seconds(20),
                        scheduler: DispatchQueue.global(qos: .default),
                        customError: { NotificationServiceError.timeout }
                    )
                    .eraseToAnyPublisher()
            }
    }
    
    private enum NotificationServiceError: Error {
        case timeout
    }
}
