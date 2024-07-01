// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import CallKit
import UserNotifications
import BackgroundTasks
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

public final class NotificationServiceExtension: UNNotificationServiceExtension {
    private var didPerformSetup = false
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var request: UNNotificationRequest?
    private var hasCompleted: Atomic<Bool> = Atomic(false)

    public static let isFromRemoteKey = "remote"                                                                   // stringlint:disable
    public static let threadIdKey = "Signal.AppNotificationsUserInfoKey.threadId"                                  // stringlint:disable
    public static let threadVariantRaw = "Signal.AppNotificationsUserInfoKey.threadVariantRaw"                     // stringlint:disable
    public static let threadNotificationCounter = "Session.AppNotificationsUserInfoKey.threadNotificationCounter"  // stringlint:disable
    private static let callPreOfferLargeNotificationSupressionDuration: TimeInterval = 30

    // MARK: Did receive a remote push notification request
    
    override public func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        self.request = request
        
        // Called via the OS so create a default 'Dependencies' instance
        let dependencies: Dependencies = Dependencies()

        // Abort if the main app is running
        guard !(UserDefaults.sharedLokiProject?[.isMainAppActive]).defaulting(to: false) else {
            Log.info("didReceive called while main app running.")
            return self.completeSilenty(isMainAppAndActive: true)
        }
        
        guard let notificationContent = request.content.mutableCopy() as? UNMutableNotificationContent else {
            Log.info("didReceive called with no content.")
            return self.completeSilenty()
        }
        
        Log.info("didReceive called.")
        
        /// Create the context if we don't have it (needed before _any_ interaction with the database)
        if !Singleton.hasAppContext {
            Singleton.setup(appContext: NotificationServiceExtensionContext())
        }
        
        let isCallOngoing: Bool = (UserDefaults.sharedLokiProject?[.isCallOngoing])
            .defaulting(to: false)

        // Perform main setup
        Storage.resumeDatabaseAccess()
        DispatchQueue.main.sync { self.setUpIfNecessary(using: dependencies) { } }

        // Handle the push notification
        Singleton.appReadiness.runNowOrWhenAppDidBecomeReady {
            let (maybeData, metadata, result) = PushNotificationAPI.processNotification(
                notificationContent: notificationContent
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
                        
                    // Just log if the notification was too long (a ~2k message should be able to fit so
                    // these will most commonly be call or config messages)
                    case .successTooLong:
                        Log.info("Received too long notification for namespace: \(metadata.namespace).")
                        return self.completeSilenty()
                        
                    case .legacyForceSilent, .failureNoContent: return self.completeSilenty()
                }
            }
            
            // HACK: It is important to use write synchronously here to avoid a race condition
            // where the completeSilenty() is called before the local notification request
            // is added to notification center
            Storage.shared.write { [weak self] db in
                do {
                    guard let processedMessage: ProcessedMessage = try Message.processRawReceivedMessageAsNotification(db, data: data, metadata: metadata) else {
                        throw NotificationError.messageProcessing
                    }
                    
                    switch processedMessage {
                        /// Custom handle config messages (as they don't get handled by the normal `MessageReceiver.handle` call
                        case .config(let publicKey, let namespace, let serverHash, let serverTimestampMs, let data):
                            try LibSession.handleConfigMessages(
                                db,
                                messages: [
                                    ConfigMessageReceiveJob.Details.MessageInfo(
                                        namespace: namespace,
                                        serverHash: serverHash,
                                        serverTimestampMs: serverTimestampMs,
                                        data: data
                                    )
                                ],
                                publicKey: publicKey
                            )
                            
                        /// Due to the way the `CallMessage` works we need to custom handle it's behaviour within the notification
                        /// extension, for all other message types we want to just use the standard `MessageReceiver.handle` call
                        case .standard(let threadId, let threadVariant, _, let messageInfo) where messageInfo.message is CallMessage:
                            guard let callMessage = messageInfo.message as? CallMessage else {
                                throw NotificationError.ignorableMessage
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
                                throw NotificationError.ignorableMessage
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
                                                shouldBeVisible: nil
                                            )

                                        // Notify the user if the call message wasn't already read
                                        if !interaction.wasRead {
                                            SessionEnvironment.shared?.notificationsManager.wrappedValue?
                                                .notifyUser(
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
                                    return self?.handleSuccessForIncomingCall(db, for: callMessage)
                            }
                            
                            // Perform any required post-handling logic
                            try MessageReceiver.postHandleMessage(
                                db,
                                threadId: threadId,
                                threadVariant: threadVariant,
                                message: messageInfo.message
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
                    
                    db.afterNextTransaction(
                        onCommit: { _ in self?.completeSilenty() },
                        onRollback: { _ in self?.completeSilenty() }
                    )
                }
                catch {
                    // If an error occurred we want to rollback the transaction (by throwing) and then handle
                    // the error outside of the database
                    let handleError = {
                        switch error {
                            case MessageReceiverError.invalidGroupPublicKey, MessageReceiverError.noGroupKeyPair,
                                MessageReceiverError.outdatedMessage, NotificationError.ignorableMessage:
                                self?.completeSilenty()
                                
                            case NotificationError.messageProcessing:
                                self?.handleFailure(for: notificationContent, error: .messageProcessing)
                                
                            case let msgError as MessageReceiverError:
                                self?.handleFailure(for: notificationContent, error: .messageHandling(msgError))
                                
                            default: self?.handleFailure(for: notificationContent, error: .other(error))
                        }
                    }
                    
                    db.afterNextTransactionNested(
                        onCommit: { _ in  handleError() },
                        onRollback: { _ in handleError() }
                    )
                    throw error
                }
            }
        }
    }

    // MARK: Setup

    private func setUpIfNecessary(using dependencies: Dependencies, completion: @escaping () -> Void) {
        Log.assertOnMainThread()

        // The NSE will often re-use the same process, so if we're
        // already set up we want to do nothing; we're already ready
        // to process new messages.
        guard !didPerformSetup else { return }

        Log.info("Performing setup.")
        didPerformSetup = true

        _ = AppVersion.shared

        AppSetup.setupEnvironment(
            retrySetupIfDatabaseInvalid: true,
            appSpecificBlock: {
                Log.setup(with: Logger(
                    primaryPrefix: "NotificationServiceExtension",                                               // stringlint:disable
                    customDirectory: "\(FileManager.default.appSharedDataDirectoryPath)/Logs/NotificationExtension", // stringlint:disable
                    forceNSLog: true
                ))
                
                SessionEnvironment.shared?.notificationsManager.mutate {
                    $0 = NSENotificationPresenter()
                }
                
                // Setup LibSession
                LibSession.addLogger()
                LibSession.createNetworkIfNeeded()
            },
            migrationsCompletion: { [weak self] result, needsConfigSync in
                switch result {
                    case .failure(let error):
                        Log.error("Failed to complete migrations: \(error).")
                        self?.completeSilenty()
                        
                    case .success:
                        // We should never receive a non-voip notification on an app that doesn't support
                        // app extensions since we have to inform the service we wanted these, so in theory
                        // this path should never occur. However, the service does have our push token
                        // so it is possible that could change in the future. If it does, do nothing
                        // and don't disturb the user. Messages will be processed when they open the app.
                        guard Storage.shared[.isReadyForAppExtensions] else {
                            Log.error("Not ready for extensions.")
                            self?.completeSilenty()
                            return
                        }
                        
                        DispatchQueue.main.async {
                            self?.versionMigrationsDidComplete(needsConfigSync: needsConfigSync)
                        }
                }
                
                completion()
            },
            using: dependencies
        )
    }
    
    private func versionMigrationsDidComplete(needsConfigSync: Bool) {
        Log.assertOnMainThread()

        // If we need a config sync then trigger it now
        if needsConfigSync {
            Storage.shared.write { db in
                ConfigurationSyncJob.enqueue(db, publicKey: getUserHexEncodedPublicKey(db))
            }
        }

        checkIsAppReady(migrationsCompleted: true)
    }

    private func checkIsAppReady(migrationsCompleted: Bool) {
        Log.assertOnMainThread()

        // Only mark the app as ready once.
        guard !Singleton.appReadiness.isAppReady else { return }

        // App isn't ready until storage is ready AND all version migrations are complete.
        guard Storage.shared.isValid && migrationsCompleted else {
            Log.error("Storage invalid.")
            self.completeSilenty()
            return
        }

        SignalUtilitiesKit.Configuration.performMainSetup()

        // Note that this does much more than set a flag; it will also run all deferred blocks.
        Singleton.appReadiness.setAppReady()
    }
    
    // MARK: Handle completion
    
    override public func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        Log.warn("Execution time expired.")
        completeSilenty()
    }
    
    private func completeSilenty(isMainAppAndActive: Bool = false) {
        // Ensure we only run this once
        guard
            hasCompleted.mutate({ hasCompleted in
                let wasCompleted: Bool = hasCompleted
                hasCompleted = true
                return wasCompleted
            }) == false
        else { return }
        
        let silentContent: UNMutableNotificationContent = UNMutableNotificationContent()
        silentContent.badge = Storage.shared
            .read { db in try Interaction.fetchUnreadCount(db) }
            .map { NSNumber(value: $0) }
            .defaulting(to: NSNumber(value: 0))
        
        Log.info("Complete silently.")
        if !isMainAppAndActive {
            Storage.suspendDatabaseAccess()
        }
        Log.flush()
        
        self.contentHandler!(silentContent)
    }
    
    private func handleSuccessForIncomingCall(_ db: Database, for callMessage: CallMessage) {
        if #available(iOSApplicationExtension 14.5, *), Preferences.isCallKitSupported {
            guard let caller: String = callMessage.sender, let timestamp = callMessage.sentTimestamp else { return }
            
            let reportCall: () -> () = { [weak self] in
                let payload: JSON = [
                    "uuid": callMessage.uuid,   // stringlint:disable
                    "caller": caller,           // stringlint:disable
                    "timestamp": timestamp      // stringlint:disable
                ]
                
                CXProvider.reportNewIncomingVoIPPushPayload(payload) { error in
                    if let error = error {
                        Log.error("Failed to notify main app of call message: \(error).")
                        Storage.shared.read { db in
                            self?.handleFailureForVoIP(db, for: callMessage)
                        }
                    }
                    else {
                        Log.info("Successfully notified main app of call message.")
                        UserDefaults.sharedLokiProject?[.lastCallPreOffer] = Date()
                        self?.completeSilenty()
                    }
                }
            }
            
            db.afterNextTransaction(
                onCommit: { _ in reportCall() },
                onRollback: { _ in reportCall() }
            )
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
                Log.error("Failed to add notification request due to error: \(error).")
            }
            semaphore.signal()
        }
        semaphore.wait()
        Log.info("Add remote notification request.")
        
        db.afterNextTransaction(
            onCommit: { [weak self] _ in self?.completeSilenty() },
            onRollback: { [weak self] _ in self?.completeSilenty() }
        )
    }

    private func handleFailure(for content: UNMutableNotificationContent, error: NotificationError) {
        Log.error("Show generic failure message due to error: \(error).")
        Storage.suspendDatabaseAccess()
        Log.flush()
        
        content.title = "Session"
        content.body = "APN_Message".localized()
        let userInfo: [String: Any] = [ NotificationServiceExtension.isFromRemoteKey: true ]
        content.userInfo = userInfo
        contentHandler!(content)
    }
}
