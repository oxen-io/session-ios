// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import AVFAudio
import Combine
import GRDB
import CallKit
import UserNotifications
import BackgroundTasks
import SessionMessagingKit
import SessionSnodeKit
import SignalUtilitiesKit
import SessionUtilitiesKit

public final class NotificationServiceExtension: UNNotificationServiceExtension {
    // Called via the OS so create a default 'Dependencies' instance
    private var dependencies: Dependencies = Dependencies.createEmpty()
    private var startTime: CFTimeInterval = 0
    private var didPerformSetup = false
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var request: UNNotificationRequest?
    private var hasCompleted: Atomic<Bool> = Atomic(false)

    // stringlint:ignore_start
    public static let isFromRemoteKey = "remote"
    public static let threadIdKey = "Signal.AppNotificationsUserInfoKey.threadId"
    public static let threadVariantRaw = "Signal.AppNotificationsUserInfoKey.threadVariantRaw"
    public static let threadNotificationCounter = "Session.AppNotificationsUserInfoKey.threadNotificationCounter"
    private static let callPreOfferLargeNotificationSupressionDuration: TimeInterval = 30
    // stringlint:ignore_stop

    // MARK: Did receive a remote push notification request
    
    override public func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.startTime = CACurrentMediaTime()
        self.contentHandler = contentHandler
        self.request = request
        
        /// Create a new `Dependencies` instance each time so we don't need to worry about state from previous
        /// notifications causing issues with new notifications
        self.dependencies = Dependencies.createEmpty()
        
        // It's technically possible for 'completeSilently' to be called twice due to the NSE timeout so
        self.hasCompleted.mutate { $0 = false }
        
        // Abort if the main app is running
        guard !dependencies[defaults: .appGroup, key: .isMainAppActive] else {
            return self.completeSilenty(handledNotification: false, isMainAppAndActive: true)
        }
        
        guard let notificationContent = request.content.mutableCopy() as? UNMutableNotificationContent else {
            return self.completeSilenty(handledNotification: false, noContent: true)
        }
        
        Log.info("didReceive called.")
        
        /// Create the context if we don't have it (needed before _any_ interaction with the database)
        if !dependencies[singleton: .appContext].isValid {
            dependencies.set(singleton: .appContext, to: NotificationServiceExtensionContext(using: dependencies))
            Dependencies.setIsRTLRetriever(requiresMainThread: false) {
                NotificationServiceExtensionContext.determineDeviceRTL()
            }
        }
        
        /// Actually perform the setup
        DispatchQueue.main.sync {
            self.performSetup { [weak self] in
                self?.handleNotification(notificationContent, isPerformingResetup: false)
            }
        }
    }
    
    private func handleNotification(_ notificationContent: UNMutableNotificationContent, isPerformingResetup: Bool) {
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
                    
                // Just log if the notification was too long (a ~2k message should be able to fit so
                // these will most commonly be call or config messages)
                case .successTooLong:
                    Log.info("Received too long notification for namespace: \(metadata.namespace), dataLength: \(metadata.dataLength).")
                    return self.completeSilenty(handledNotification: false)
                    
                case .legacyForceSilent:
                    Log.info("Ignoring non-group legacy notification.")
                    return self.completeSilenty(handledNotification: false)
                    
                case .failureNoContent:
                    Log.warn("Failed due to missing notification content.")
                    return self.completeSilenty(handledNotification: false)
            }
        }
        
        let isCallOngoing: Bool = dependencies[defaults: .appGroup, key: .isCallOngoing]
        
        // HACK: It is important to use write synchronously here to avoid a race condition
        // where the completeSilenty() is called before the local notification request
        // is added to notification center
        dependencies[singleton: .storage].write { [weak self, dependencies] db in
            do {
                let processedMessage: ProcessedMessage = try Message.processRawReceivedMessageAsNotification(
                    db,
                    data: data,
                    metadata: metadata,
                    using: dependencies
                )
                
                switch processedMessage {
                    /// Custom handle config messages (as they don't get handled by the normal `MessageReceiver.handle` call
                    case .config(let swarmPublicKey, let namespace, let serverHash, let serverTimestampMs, let data):
                        try dependencies.mutate(cache: .libSession) { cache in
                            try cache.handleConfigMessages(
                                db,
                                swarmPublicKey: swarmPublicKey,
                                messages: [
                                    ConfigMessageReceiveJob.Details.MessageInfo(
                                        namespace: namespace,
                                        serverHash: serverHash,
                                        serverTimestampMs: serverTimestampMs,
                                        data: data
                                    )
                                ]
                            )
                        }
                    
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
                            threadVariant: threadVariant,
                            using: dependencies
                        )
                        
                        try MessageReceiver.handleCallMessage(
                            db,
                            threadId: threadId,
                            threadVariant: threadVariant,
                            message: callMessage,
                            using: dependencies
                        )
                        
                        guard case .preOffer = callMessage.kind else {
                            throw NotificationError.ignorableMessage
                        }
                        
                        let hasMicrophonePermission: Bool = (AVAudioSession.sharedInstance().recordPermission == .granted)
                        switch ((db[.areCallsEnabled] && hasMicrophonePermission), isCallOngoing) {
                            case (false, _):
                                if
                                    let sender: String = callMessage.sender,
                                    let interaction: Interaction = try MessageReceiver.insertCallInfoMessage(
                                        db,
                                        for: callMessage,
                                        state: (db[.areCallsEnabled] ? .permissionDeniedMicrophone : .permissionDenied),
                                        using: dependencies
                                    )
                                {
                                    let thread: SessionThread = try SessionThread
                                        .fetchOrCreate(
                                            db,
                                            id: sender,
                                            variant: .contact,
                                            creationDateTimestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000),
                                            shouldBeVisible: nil,
                                            calledFromConfig: nil,
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
                                    message: callMessage,
                                    using: dependencies
                                )
                                
                            case (true, false):
                                try MessageReceiver.insertCallInfoMessage(db, for: callMessage, using: dependencies)
                                
                                // Perform any required post-handling logic
                                try MessageReceiver.postHandleMessage(
                                    db,
                                    threadId: threadId,
                                    threadVariant: threadVariant,
                                    message: messageInfo.message,
                                    using: dependencies
                                )
                                
                                return self?.handleSuccessForIncomingCall(db, for: callMessage)
                        }
                        
                        // Perform any required post-handling logic
                        try MessageReceiver.postHandleMessage(
                            db,
                            threadId: threadId,
                            threadVariant: threadVariant,
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
                            associatedWithProto: proto,
                            using: dependencies
                        )
                }
                
                db.afterNextTransaction(
                    onCommit: { _ in self?.completeSilenty(handledNotification: true) },
                    onRollback: { _ in self?.completeSilenty(handledNotification: false) }
                )
            }
            catch {
                // If an error occurred we want to rollback the transaction (by throwing) and then handle
                // the error outside of the database
                let handleError = {
                    // Dispatch to the next run loop to ensure we are out of the database write thread before
                    // handling the result (and suspending the database)
                    DispatchQueue.main.async {
                        switch error {
                            case MessageReceiverError.noGroupKeyPair:
                                Log.warn("Failed due to having no legacy group decryption keys.")
                                self?.completeSilenty(handledNotification: false)
                                
                            case MessageReceiverError.outdatedMessage:
                                Log.info("Ignoring notification for already seen message.")
                                self?.completeSilenty(handledNotification: false)
                                
                            case NotificationError.ignorableMessage:
                                Log.info("Ignoring message which requires no notification.")
                                self?.completeSilenty(handledNotification: false)
                                
                            case MessageReceiverError.duplicateMessage, MessageReceiverError.duplicateControlMessage,
                                MessageReceiverError.duplicateMessageNewSnode:
                                Log.info("Ignoring duplicate message (probably received it just before going to the background).")
                                self?.completeSilenty(handledNotification: false)
                                
                            case let msgError as MessageReceiverError:
                                self?.handleFailure(for: notificationContent, error: .messageHandling(msgError))
                                
                            default: self?.handleFailure(for: notificationContent, error: .other(error))
                        }
                    }
                }
                
                db.afterNextTransaction(
                    onCommit: { _ in  handleError() },
                    onRollback: { _ in handleError() }
                )
                throw error
            }
        }
    }

    // MARK: Setup

    private func performSetup(completion: @escaping () -> Void) {
        Log.info("Performing setup.")

        dependencies.warmCache(cache: .appVersion)
        
        // FIXME: Remove these once the database instance is fully managed via `Dependencies`
        if AppSetup.hasRun {
            dependencies[singleton: .storage].resumeDatabaseAccess()
            dependencies[singleton: .storage].reconfigureDatabase()
            
            /// If we had already done a setup then `libSession` won't have been re-setup so
            /// we need to do so now (this ensures it has the correct user keys as well)
            dependencies.remove(cache: .libSession)
            
            dependencies[singleton: .storage].read { [dependencies] db in
                guard let userKeyPair: KeyPair = Identity.fetchUserKeyPair(db) else {
                    dependencies.mutate(cache: .general) { $0.setCachedSessionId(sessionId: .invalid) }
                    dependencies.set(
                        cache: .libSession,
                        to: LibSession.Cache(
                            userSessionId: .invalid,
                            using: dependencies
                        )
                    )
                    return
                }
                
                dependencies.mutate(cache: .general) {
                    $0.setCachedSessionId(sessionId: SessionId(.standard, publicKey: userKeyPair.publicKey))
                }
                dependencies.set(
                    cache: .libSession,
                    to: LibSession.Cache(
                        userSessionId: SessionId(.standard, publicKey: userKeyPair.publicKey),
                        using: dependencies
                    )
                )
                dependencies.mutate(cache: .libSession) { $0.loadState(db) }
            }
        }

        AppSetup.setupEnvironment(
            retrySetupIfDatabaseInvalid: true,
            appSpecificBlock: { [dependencies] in
                // stringlint:ignore_start
                Log.setup(with: Logger(
                    primaryPrefix: "NotificationServiceExtension",
                    level: .info,
                    customDirectory: "\(dependencies[singleton: .fileManager].appSharedDataDirectoryPath)/Logs/NotificationExtension",
                    using: dependencies
                ))
                // stringlint:ignore_stop
                
                /// The `NotificationServiceExtension` needs custom behaviours for it's notification presenter so set it up here
                dependencies.set(singleton: .notificationsManager, to: NSENotificationPresenter(using: dependencies))
                
                // Setup LibSession
                LibSession.setupLogger(using: dependencies)
                
                // Configure the different targets
                SNUtilitiesKit.configure(
                    networkMaxFileSize: Network.maxFileSize,
                    localizedFormatted: { helper, font in NSAttributedString() },
                    localizedDeformatted: { helper in NSENotificationPresenter.localizedDeformatted(helper) },
                    using: dependencies
                )
                SNMessagingKit.configure(using: dependencies)
            },
            migrationsCompletion: { [weak self, dependencies] result, _ in
                switch result {
                    case .failure(let error):
                        Log.error("Failed to complete migrations: \(error).")
                        self?.completeSilenty(handledNotification: false)
                        
                    case .success:
                        DispatchQueue.main.async {
                            // Ensure storage is actually valid
                            guard dependencies[singleton: .storage].isValid else {
                                Log.error("Storage invalid.")
                                self?.completeSilenty(handledNotification: false)
                                return
                            }
                            
                            // We should never receive a non-voip notification on an app that doesn't support
                            // app extensions since we have to inform the service we wanted these, so in theory
                            // this path should never occur. However, the service does have our push token
                            // so it is possible that could change in the future. If it does, do nothing
                            // and don't disturb the user. Messages will be processed when they open the app.
                            guard dependencies[singleton: .storage, key: .isReadyForAppExtensions] else {
                                Log.error("Not ready for extensions.")
                                self?.completeSilenty(handledNotification: false)
                                return
                            }
                            
                            // If the app wasn't ready then mark it as ready now
                            if !dependencies[singleton: .appReadiness].isAppReady {
                                // Note that this does much more than set a flag; it will also run all deferred blocks.
                                dependencies[singleton: .appReadiness].setAppReady()
                            }

                            completion()
                        }
                }
            },
            using: dependencies
        )
    }
    
    // MARK: Handle completion
    
    override public func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        Log.warn("Execution time expired.")
        completeSilenty(handledNotification: false)
    }
    
    private func completeSilenty(handledNotification: Bool, isMainAppAndActive: Bool = false, noContent: Bool = false) {
        // Ensure we only run this once
        guard
            hasCompleted.mutate({ hasCompleted in
                let wasCompleted: Bool = hasCompleted
                hasCompleted = true
                return wasCompleted
            }) == false
        else { return }
        
        let silentContent: UNMutableNotificationContent = UNMutableNotificationContent()
        
        if !isMainAppAndActive {
            silentContent.badge = dependencies[singleton: .storage]
                .read { [dependencies] db in try Interaction.fetchUnreadCount(db, using: dependencies) }
                .map { NSNumber(value: $0) }
                .defaulting(to: NSNumber(value: 0))
            dependencies[singleton: .storage].suspendDatabaseAccess()
        }
        
        let duration: CFTimeInterval = (CACurrentMediaTime() - startTime)
        switch (isMainAppAndActive, handledNotification, noContent) {
            case (true, _, _): Log.info("Called while main app running, ignoring after \(.seconds(duration), unit: .ms).")
            case (_, _, true): Log.info("Called with no content, ignoring after \(.seconds(duration), unit: .ms).")
            case (_, true, _): Log.info("Completed after handling notification in \(.seconds(duration), unit: .ms).")
            default: Log.info("Completed silently after \(.seconds(duration), unit: .ms).")
        }
        Log.flush()
        
        self.contentHandler!(silentContent)
    }
    
    private func handleSuccessForIncomingCall(
        _ db: Database,
        for callMessage: CallMessage
    ) {
        if #available(iOSApplicationExtension 14.5, *), Preferences.isCallKitSupported {
            guard let caller: String = callMessage.sender, let timestamp = callMessage.sentTimestampMs else { return }
            
            let reportCall: () -> () = { [weak self, dependencies] in
                // stringlint:ignore_start
                let payload: [String: Any] = [
                    "uuid": callMessage.uuid,
                    "caller": caller,
                    "timestamp": timestamp
                ]
                // stringlint:ignore_stop
                
                CXProvider.reportNewIncomingVoIPPushPayload(payload) { error in
                    if let error = error {
                        Log.error("Failed to notify main app of call message: \(error).")
                        dependencies[singleton: .storage].read { db in
                            self?.handleFailureForVoIP(db, for: callMessage)
                        }
                    }
                    else {
                        Log.info("Successfully notified main app of call message.")
                        dependencies[defaults: .appGroup, key: .lastCallPreOffer] = Date()
                        self?.completeSilenty(handledNotification: true)
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
        notificationContent.title = Constants.app_name
        notificationContent.badge = (try? Interaction.fetchUnreadCount(db, using: dependencies))
            .map { NSNumber(value: $0) }
            .defaulting(to: NSNumber(value: 0))
        
        if let sender: String = callMessage.sender {
            let senderDisplayName: String = Profile.displayName(db, id: sender, threadVariant: .contact, using: dependencies)
            notificationContent.body = "callsIncoming"
                .put(key: "name", value: senderDisplayName)
                .localized()
        }
        else {
            notificationContent.body = "callsIncomingUnknown".localized()
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
            onCommit: { [weak self] _ in self?.completeSilenty(handledNotification: true) },
            onRollback: { [weak self] _ in self?.completeSilenty(handledNotification: false) }
        )
    }

    private func handleFailure(for content: UNMutableNotificationContent, error: NotificationError) {
        let duration: CFTimeInterval = (CACurrentMediaTime() - startTime)
        Log.error("Show generic failure message after \(.seconds(duration), unit: .ms) due to error: \(error).")
        Log.flush()
        
        if !dependencies[defaults: .appGroup, key: .isMainAppActive] {
            dependencies[singleton: .storage].suspendDatabaseAccess()
        }
        
        content.title = Constants.app_name
        content.body = "messageNewYouveGot"
            .putNumber(1)
            .localized()
        let userInfo: [String: Any] = [ NotificationServiceExtension.isFromRemoteKey: true ]
        content.userInfo = userInfo
        contentHandler!(content)
        hasCompleted.mutate { $0 = true }
    }
}
