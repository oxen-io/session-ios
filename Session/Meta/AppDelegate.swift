// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import UserNotifications
import GRDB
import WebRTC
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit
import SignalCoreKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?
    var backgroundSnapshotBlockerWindow: UIWindow?
    var appStartupWindow: UIWindow?
    var hasInitialRootViewController: Bool = false
    private var loadingViewController: LoadingViewController?
    
    enum LifecycleMethod {
        case finishLaunching
        case enterForeground
    }
    
    /// This needs to be a lazy variable to ensure it doesn't get initialized before it actually needs to be used
    lazy var poller: CurrentUserPoller = CurrentUserPoller()
    
    // MARK: - Lifecycle

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // These should be the first things we do (the startup process can fail without them)
        SetCurrentAppContext(MainAppContext())
        verifyDBKeysAvailableBeforeBackgroundLaunch()

        Cryptography.seedRandom()
        AppVersion.sharedInstance()
        AppEnvironment.shared.pushRegistrationManager.createVoipRegistryIfNecessary()

        // Prevent the device from sleeping during database view async registration
        // (e.g. long database upgrades).
        //
        // This block will be cleared in storageIsReady.
        DeviceSleepManager.sharedInstance.addBlock(blockObject: self)
        
        let mainWindow: UIWindow = TraitObservingWindow(frame: UIScreen.main.bounds)
        self.loadingViewController = LoadingViewController()
        
        // Store a weak reference in the ThemeManager so it can properly apply themes as needed
        ThemeManager.mainWindow = mainWindow
        
        AppSetup.setupEnvironment(
            appSpecificBlock: {
                // Create AppEnvironment
                AppEnvironment.shared.setup()
                
                // Note: Intentionally dispatching sync as we want to wait for these to complete before
                // continuing
                DispatchQueue.main.sync {
                    ScreenLockUI.shared.setupWithRootWindow(rootWindow: mainWindow)
                    OWSWindowManager.shared().setup(
                        withRootWindow: mainWindow,
                        screenBlockingWindow: ScreenLockUI.shared.screenBlockingWindow
                    )
                    ScreenLockUI.shared.startObserving()
                }
            },
            migrationProgressChanged: { [weak self] progress, minEstimatedTotalTime in
                self?.loadingViewController?.updateProgress(
                    progress: progress,
                    minEstimatedTotalTime: minEstimatedTotalTime
                )
            },
            migrationsCompletion: { [weak self] result, needsConfigSync in
                if case .failure(let error) = result {
                    self?.showDatabaseSetupFailureModal(calledFrom: .finishLaunching, error: error)
                    return
                }
                
                self?.completePostMigrationSetup(calledFrom: .finishLaunching, needsConfigSync: needsConfigSync)
            }
        )
        
        if Environment.shared?.callManager.wrappedValue?.currentCall == nil {
            UserDefaults.sharedLokiProject?.set(false, forKey: "isCallOngoing")
        }
        
        // No point continuing if we are running tests
        guard !CurrentAppContext().isRunningTests else { return true }

        self.window = mainWindow
        CurrentAppContext().mainWindow = mainWindow
        
        // Show LoadingViewController until the async database view registrations are complete.
        mainWindow.rootViewController = self.loadingViewController
        mainWindow.makeKeyAndVisible()

        // This must happen in appDidFinishLaunching or earlier to ensure we don't
        // miss notifications.
        // Setting the delegate also seems to prevent us from getting the legacy notification
        // notification callbacks upon launch e.g. 'didReceiveLocalNotification'
        UNUserNotificationCenter.current().delegate = self
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(registrationStateDidChange),
            name: .registrationStateDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showMissedCallTipsIfNeeded(_:)),
            name: .missedCall,
            object: nil
        )
        
        Logger.info("application: didFinishLaunchingWithOptions completed.")

        return true
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        /// **Note:** We _shouldn't_ need to call this here but for some reason the OS doesn't seems to
        /// be calling the `userNotificationCenter(_:,didReceive:withCompletionHandler:)`
        /// method when the device is locked while the app is in the foreground (or if the user returns to the
        /// springboard without swapping to another app) - adding this here in addition to the one in
        /// `appDidFinishLaunching` seems to fix this odd behaviour (even though it doesn't match
        /// Apple's documentation on the matter)
        UNUserNotificationCenter.current().delegate = self
        
        // Resume database
        NotificationCenter.default.post(name: Database.resumeNotification, object: self)
        
        // If we've already completed migrations at least once this launch then check
        // to see if any "delayed" migrations now need to run
        if Storage.shared.hasCompletedMigrations {
            AppReadiness.invalidate()
            AppSetup.runPostSetupMigrations(
                migrationProgressChanged: { [weak self] progress, minEstimatedTotalTime in
                    self?.loadingViewController?.updateProgress(
                        progress: progress,
                        minEstimatedTotalTime: minEstimatedTotalTime
                    )
                },
                migrationsCompletion: { [weak self] result, needsConfigSync in
                    if case .failure(let error) = result {
                        self?.showDatabaseSetupFailureModal(calledFrom: .enterForeground, error: error)
                        return
                    }
                    
                    self?.completePostMigrationSetup(calledFrom: .enterForeground, needsConfigSync: needsConfigSync)
                }
            )
        }
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        DDLog.flushLog()
        
        // NOTE: Fix an edge case where user taps on the callkit notification
        // but answers the call on another device
        stopPollers(shouldStopUserPoller: !self.hasCallOngoing())
        
        // Stop all jobs except for message sending and when completed suspend the database
        JobRunner.stopAndClearPendingJobs(exceptForVariant: .messageSend) {
            if !self.hasCallOngoing() {
                NotificationCenter.default.post(name: Database.suspendNotification, object: self)
            }
        }
    }
    
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        Logger.info("applicationDidReceiveMemoryWarning")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        DDLog.flushLog()

        stopPollers()
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        guard !CurrentAppContext().isRunningTests else { return }
        
        UserDefaults.sharedLokiProject?[.isMainAppActive] = true
        
        ensureRootViewController()

        AppReadiness.runNowOrWhenAppDidBecomeReady { [weak self] in
            self?.handleActivation()
            
            /// Clear all notifications whenever we become active once the app is ready
            ///
            /// **Note:** It looks like when opening the app from a notification, `userNotificationCenter(didReceive)` is
            /// no longer always called before `applicationDidBecomeActive` we need to trigger the "clear notifications" logic
            /// within the `runNowOrWhenAppDidBecomeReady` callback and dispatch to the next run loop to ensure it runs after
            /// the notification has actually been handled
            DispatchQueue.main.async { [weak self] in
                self?.clearAllNotificationsAndRestoreBadgeCount()
            }
        }

        // On every activation, clear old temp directories.
        ClearOldTemporaryDirectories()
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        clearAllNotificationsAndRestoreBadgeCount()
        
        UserDefaults.sharedLokiProject?[.isMainAppActive] = false

        DDLog.flushLog()
    }
    
    // MARK: - Orientation

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.isIPad {
            return .allButUpsideDown
        }
        
        return .portrait
    }
    
    // MARK: - Background Fetching
    
    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // Resume database
        NotificationCenter.default.post(name: Database.resumeNotification, object: self)
        
        // Background tasks only last for a certain amount of time (which can result in a crash and a
        // prompt appearing for the user), we want to avoid this and need to make sure to suspend the
        // database again before the background task ends so we start a timer that expires 1 second
        // before the background task is due to expire in order to do so
        let cancelTimer: Timer = Timer.scheduledTimerOnMainThread(
            withTimeInterval: (application.backgroundTimeRemaining - 1),
            repeats: false
        ) { timer in
            timer.invalidate()
            
            guard BackgroundPoller.isValid else { return }
            
            BackgroundPoller.isValid = false
            
            if CurrentAppContext().isInBackground() {
                // Suspend database
                NotificationCenter.default.post(name: Database.suspendNotification, object: self)
            }
            
            SNLog("Background poll failed due to manual timeout")
            completionHandler(.failed)
        }
        
        // Flag the background poller as valid first and then trigger it to poll once the app is
        // ready (we do this here rather than in `BackgroundPoller.poll` to avoid the rare edge-case
        // that could happen when the timeout triggers before the app becomes ready which would have
        // incorrectly set this 'isValid' flag to true after it should have timed out)
        BackgroundPoller.isValid = true
        
        AppReadiness.runNowOrWhenAppDidBecomeReady {
            BackgroundPoller.poll { result in
                guard BackgroundPoller.isValid else { return }
                
                BackgroundPoller.isValid = false
                
                if CurrentAppContext().isInBackground() {
                    // Suspend database
                    NotificationCenter.default.post(name: Database.suspendNotification, object: self)
                }
                
                cancelTimer.invalidate()
                completionHandler(result)
            }
        }
    }
    
    // MARK: - App Readiness
    
    private func completePostMigrationSetup(calledFrom lifecycleMethod: LifecycleMethod, needsConfigSync: Bool) {
        Configuration.performMainSetup()
        JobRunner.add(executor: SyncPushTokensJob.self, for: .syncPushTokens)
        
        /// Setup the UI
        ///
        /// **Note:** This **MUST** be run before calling:
        /// - `AppReadiness.setAppIsReady()`:
        ///    If we are launching the app from a push notification the HomeVC won't be setup yet
        ///    and it won't open the related thread
        ///
        /// - `JobRunner.appDidFinishLaunching()`:
        ///    The jobs which run on launch (eg. DisappearingMessages job) can impact the interactions
        ///    which get fetched to display on the home screen, if the PagedDatabaseObserver hasn't
        ///    been setup yet then the home screen can show stale (ie. deleted) interactions incorrectly
        self.ensureRootViewController(isPreAppReadyCall: true)
        
        // Trigger any launch-specific jobs and start the JobRunner
        if lifecycleMethod == .finishLaunching {
            JobRunner.appDidFinishLaunching()
        }
        
        // Note that this does much more than set a flag;
        // it will also run all deferred blocks (including the JobRunner
        // 'appDidBecomeActive' method)
        AppReadiness.setAppIsReady()
        
        DeviceSleepManager.sharedInstance.removeBlock(blockObject: self)
        AppVersion.sharedInstance().mainAppLaunchDidComplete()
        Environment.shared?.audioSession.setup()
        Environment.shared?.reachabilityManager.setup()
        
        Storage.shared.writeAsync { db in
            // Disable the SAE until the main app has successfully completed launch process
            // at least once in the post-SAE world.
            db[.isReadyForAppExtensions] = true
            
            if Identity.userCompletedRequiredOnboarding(db) {
                let appVersion: AppVersion = AppVersion.sharedInstance()
                
                // If the device needs to sync config or the user updated to a new version
                if
                    needsConfigSync || (
                        (appVersion.lastAppVersion?.count ?? 0) > 0 &&
                        appVersion.lastAppVersion != appVersion.currentAppVersion
                    )
                {
                    ConfigurationSyncJob.enqueue(db, publicKey: getUserHexEncodedPublicKey(db))
                }
            }
        }
    }
    
    private func showDatabaseSetupFailureModal(calledFrom lifecycleMethod: LifecycleMethod, error: Error?) {
        let alert = UIAlertController(
            title: "Session",
            message: {
                switch (error as? StorageError) {
                    case .databaseInvalid: return "DATABASE_SETUP_FAILED".localized()
                    default: return "DATABASE_MIGRATION_FAILED".localized()
                }
            }(),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "HELP_REPORT_BUG_ACTION_TITLE".localized(), style: .default) { _ in
            HelpViewModel.shareLogs(viewControllerToDismiss: alert) { [weak self] in
                self?.showDatabaseSetupFailureModal(calledFrom: lifecycleMethod, error: error)
            }
        })
        alert.addAction(UIAlertAction(title: "vc_restore_title".localized(), style: .destructive) { _ in
            // Remove the legacy database and any message hashes that have been migrated to the new DB
            try? SUKLegacy.deleteLegacyDatabaseFilesAndKey()
            
            Storage.shared.write { db in
                try SnodeReceivedMessageInfo.deleteAll(db)
            }
            
            // The re-run the migration (should succeed since there is no data)
            AppSetup.runPostSetupMigrations(
                migrationProgressChanged: { [weak self] progress, minEstimatedTotalTime in
                    self?.loadingViewController?.updateProgress(
                        progress: progress,
                        minEstimatedTotalTime: minEstimatedTotalTime
                    )
                },
                migrationsCompletion: { [weak self] result, needsConfigSync in
                    if case .failure(let error) = result {
                        self?.showDatabaseSetupFailureModal(calledFrom: lifecycleMethod, error: error)
                        return
                    }
                    
                    self?.completePostMigrationSetup(calledFrom: lifecycleMethod, needsConfigSync: needsConfigSync)
                }
            )
        })
        
        alert.addAction(UIAlertAction(title: "Close", style: .default) { _ in
            DDLog.flushLog()
            exit(0)
        })
        
        self.window?.rootViewController?.present(alert, animated: true, completion: nil)
    }
    
    /// The user must unlock the device once after reboot before the database encryption key can be accessed.
    private func verifyDBKeysAvailableBeforeBackgroundLaunch() {
        guard UIApplication.shared.applicationState == .background else { return }
        
        guard !Storage.isDatabasePasswordAccessible else { return }    // All good
        
        Logger.info("Exiting because we are in the background and the database password is not accessible.")
        
        let notificationContent: UNMutableNotificationContent = UNMutableNotificationContent()
        notificationContent.body = String(
            format: NSLocalizedString("NOTIFICATION_BODY_PHONE_LOCKED_FORMAT", comment: ""),
            UIDevice.current.localizedModel
        )
        let notificationRequest: UNNotificationRequest = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: notificationContent,
            trigger: nil
        )
        
        // Make sure we clear any existing notifications so that they don't start stacking up
        // if the user receives multiple pushes.
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UIApplication.shared.applicationIconBadgeNumber = 0
        
        UNUserNotificationCenter.current().add(notificationRequest, withCompletionHandler: nil)
        UIApplication.shared.applicationIconBadgeNumber = 1
        
        DDLog.flushLog()
        exit(0)
    }
    
    private func enableBackgroundRefreshIfNecessary() {
        AppReadiness.runNowOrWhenAppDidBecomeReady {
            UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        }
    }

    private func handleActivation() {
        guard Identity.userExists() else { return }
        
        enableBackgroundRefreshIfNecessary()
        JobRunner.appDidBecomeActive()
        
        startPollersIfNeeded()
        
        if CurrentAppContext().isMainApp {
            syncConfigurationIfNeeded()
            handleAppActivatedWithOngoingCallIfNeeded()
        }
    }
    
    private func ensureRootViewController(isPreAppReadyCall: Bool = false) {
        guard (AppReadiness.isAppReady() || isPreAppReadyCall) && Storage.shared.isValid && !hasInitialRootViewController else {
            return
        }
        
        self.hasInitialRootViewController = true
        self.window?.rootViewController = TopBannerController(
            child: StyledNavigationController(
                rootViewController: {
                    guard Identity.userExists() else { return LandingVC() }
                    guard !Profile.fetchOrCreateCurrentUser().name.isEmpty else {
                        // If we have no display name then collect one (this can happen if the
                        // app crashed during onboarding which would leave the user in an invalid
                        // state with no display name)
                        return DisplayNameVC(flow: .register)
                    }
                    
                    return HomeVC()
                }()
            ),
            cachedWarning: UserDefaults.sharedLokiProject?[.topBannerWarningToShow]
                .map { rawValue in TopBannerController.Warning(rawValue: rawValue) }
        )
        UIViewController.attemptRotationToDeviceOrientation()
        
        /// **Note:** There is an annoying case when starting the app by interacting with a push notification where
        /// the `HomeVC` won't have completed loading it's view which means the `SessionApp.homeViewController`
        /// won't have been set - we set the value directly here to resolve this edge case
        if let homeViewController: HomeVC = (self.window?.rootViewController as? UINavigationController)?.viewControllers.first as? HomeVC {
            SessionApp.homeViewController.mutate { $0 = homeViewController }
        }
    }
    
    // MARK: - Notifications
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistrationManager.shared.didReceiveVanillaPushToken(deviceToken)
        Logger.info("Registering for push notifications with token: \(deviceToken).")
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Logger.error("Failed to register push token with error: \(error).")
        
        #if DEBUG
        Logger.warn("We're in debug mode. Faking success for remote registration with a fake push identifier.")
        PushRegistrationManager.shared.didReceiveVanillaPushToken(Data(count: 32))
        #else
        PushRegistrationManager.shared.didFailToReceiveVanillaPushToken(error: error)
        #endif
    }
    
    private func clearAllNotificationsAndRestoreBadgeCount() {
        AppReadiness.runNowOrWhenAppDidBecomeReady {
            AppEnvironment.shared.notificationPresenter.clearAllNotifications()
            
            guard CurrentAppContext().isMainApp else { return }
            
            /// On application startup the `Storage.read` can be slightly slow while GRDB spins up it's database
            /// read pools (up to a few seconds), since this read is blocking we want to dispatch it to run async to ensure
            /// we don't block user interaction while it's running
            DispatchQueue.global(qos: .default).async {
                let unreadCount: Int = Storage.shared
                    .read { db in
                        let userPublicKey: String = getUserHexEncodedPublicKey(db)
                        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
                        
                        return try Interaction
                            .filter(Interaction.Columns.wasRead == false)
                            .filter(Interaction.Variant.variantsToIncrementUnreadCount.contains(Interaction.Columns.variant))
                            .filter(
                                // Only count mentions if 'onlyNotifyForMentions' is set
                                thread[.onlyNotifyForMentions] == false ||
                                Interaction.Columns.hasMention == true
                            )
                            .joining(
                                required: Interaction.thread
                                    .aliased(thread)
                                    .joining(optional: SessionThread.contact)
                                    .filter(
                                        // Ignore muted threads
                                        SessionThread.Columns.mutedUntilTimestamp == nil ||
                                        SessionThread.Columns.mutedUntilTimestamp < Date().timeIntervalSince1970
                                    )
                                    .filter(
                                        // Ignore message request threads
                                        SessionThread.Columns.variant != SessionThread.Variant.contact ||
                                        !SessionThread.isMessageRequest(userPublicKey: userPublicKey)
                                    )
                            )
                            .fetchCount(db)
                    }
                    .defaulting(to: 0)
                
                DispatchQueue.main.async {
                    CurrentAppContext().setMainAppBadgeNumber(unreadCount)
                }
            }
        }
    }
    
    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        AppReadiness.runNowOrWhenAppDidBecomeReady {
            guard Identity.userCompletedRequiredOnboarding() else { return }
            
            SessionApp.homeViewController.wrappedValue?.createNewConversation()
            completionHandler(true)
        }
    }

    /// The method will be called on the delegate only if the application is in the foreground. If the method is not implemented or the
    /// handler is not called in a timely manner then the notification will not be presented. The application can choose to have the
    /// notification presented as a sound, badge, alert and/or in the notification list.
    ///
    /// This decision should be based on whether the information in the notification is otherwise visible to the user.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.content.userInfo["remote"] != nil {
            Logger.info("[Loki] Ignoring remote notifications while the app is in the foreground.")
            return
        }
        
        AppReadiness.runNowOrWhenAppDidBecomeReady {
            // We need to respect the in-app notification sound preference. This method, which is called
            // for modern UNUserNotification users, could be a place to do that, but since we'd still
            // need to handle this behavior for legacy UINotification users anyway, we "allow" all
            // notification options here, and rely on the shared logic in NotificationPresenter to
            // honor notification sound preferences for both modern and legacy users.
            completionHandler([.alert, .badge, .sound])
        }
    }

    /// The method will be called on the delegate when the user responded to the notification by opening the application, dismissing
    /// the notification or choosing a UNNotificationAction. The delegate must be set before the application returns from
    /// application:didFinishLaunchingWithOptions:.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        AppReadiness.runNowOrWhenAppDidBecomeReady {
            AppEnvironment.shared.userNotificationActionHandler.handleNotificationResponse(response, completionHandler: completionHandler)
        }
    }

    /// The method will be called on the delegate when the application is launched in response to the user's request to view in-app
    /// notification settings. Add UNAuthorizationOptionProvidesAppNotificationSettings as an option in
    /// requestAuthorizationWithOptions:completionHandler: to add a button to inline notification settings view and the notification
    /// settings view in Settings. The notification will be nil when opened from Settings.
    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
    }
    
    // MARK: - Notification Handling
    
    @objc private func registrationStateDidChange() {
        handleActivation()
    }
    
    @objc public func showMissedCallTipsIfNeeded(_ notification: Notification) {
        guard !UserDefaults.standard[.hasSeenCallMissedTips] else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.showMissedCallTipsIfNeeded(notification)
            }
            return
        }
        guard let callerId: String = notification.userInfo?[Notification.Key.senderId.rawValue] as? String else {
            return
        }
        guard let presentingVC = CurrentAppContext().frontmostViewController() else { preconditionFailure() }
        
        let callMissedTipsModal: CallMissedTipsModal = CallMissedTipsModal(
            caller: Profile.displayName(id: callerId)
        )
        presentingVC.present(callMissedTipsModal, animated: true, completion: nil)
        
        UserDefaults.standard[.hasSeenCallMissedTips] = true
    }
    
    // MARK: - Polling
    
    public func startPollersIfNeeded(shouldStartGroupPollers: Bool = true) {
        guard Identity.userExists() else { return }
        
        poller.start()
        
        guard shouldStartGroupPollers else { return }
        
        ClosedGroupPoller.shared.start()
        OpenGroupManager.shared.startPolling()
    }
    
    public func stopPollers(shouldStopUserPoller: Bool = true) {
        if shouldStopUserPoller {
            poller.stopAllPollers()
        }
        
        ClosedGroupPoller.shared.stopAllPollers()
        OpenGroupManager.shared.stopPolling()
    }
    
    // MARK: - App Link

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        guard let components: URLComponents = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return false
        }
        
        // URL Scheme is sessionmessenger://DM?sessionID=1234
        // We can later add more parameters like message etc.
        if components.host == "DM" {
            let matches: [URLQueryItem] = (components.queryItems ?? [])
                .filter { item in item.name == "sessionID" }
            
            if let sessionId: String = matches.first?.value {
                createNewDMFromDeepLink(sessionId: sessionId)
                return true
            }
        }
        
        return false
    }

    private func createNewDMFromDeepLink(sessionId: String) {
        guard let homeViewController: HomeVC = (window?.rootViewController as? UINavigationController)?.visibleViewController as? HomeVC else {
            return
        }
        
        homeViewController.createNewDMFromDeepLink(sessionId: sessionId)
    }
        
    // MARK: - Call handling
        
    func hasIncomingCallWaiting() -> Bool {
        guard let call = AppEnvironment.shared.callManager.currentCall else { return false }
        
        return !call.hasStartedConnecting
    }
    
    func hasCallOngoing() -> Bool {
        guard let call = AppEnvironment.shared.callManager.currentCall else { return false }
        
        return !call.hasEnded
    }
    
    func handleAppActivatedWithOngoingCallIfNeeded() {
        guard
            let call: SessionCall = (AppEnvironment.shared.callManager.currentCall as? SessionCall),
            MiniCallView.current == nil
        else { return }
        
        if let callVC = CurrentAppContext().frontmostViewController() as? CallVC, callVC.call.uuid == call.uuid {
            return
        }
        
        // FIXME: Handle more gracefully
        guard let presentingVC = CurrentAppContext().frontmostViewController() else { preconditionFailure() }
        
        let callVC: CallVC = CallVC(for: call)
        
        if let conversationVC: ConversationVC = presentingVC as? ConversationVC, conversationVC.viewModel.threadData.threadId == call.sessionId {
            callVC.conversationVC = conversationVC
            conversationVC.inputAccessoryView?.isHidden = true
            conversationVC.inputAccessoryView?.alpha = 0
        }
        
        presentingVC.present(callVC, animated: true, completion: nil)
    }
    
    // MARK: - Config Sync
    
    func syncConfigurationIfNeeded() {
        // FIXME: Remove this once `useSharedUtilForUserConfig` is permanent
        guard !SessionUtil.userConfigsEnabled else { return }
        
        let lastSync: Date = (UserDefaults.standard[.lastConfigurationSync] ?? .distantPast)
        
        guard Date().timeIntervalSince(lastSync) > (7 * 24 * 60 * 60) else { return } // Sync every 2 days
        
        Storage.shared
            .writeAsync(
                updates: { db in
                    ConfigurationSyncJob.enqueue(db, publicKey: getUserHexEncodedPublicKey(db))
                },
                completion: { _, result in
                    switch result {
                        case .failure: break
                        case .success:
                            // Only update the 'lastConfigurationSync' timestamp if we have done the
                            // first sync (Don't want a new device config sync to override config
                            // syncs from other devices)
                            if UserDefaults.standard[.hasSyncedInitialConfiguration] {
                                UserDefaults.standard[.lastConfigurationSync] = Date()
                            }
                    }
                }
            )
    }
}
