// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import UserNotifications
import GRDB
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit
import SignalCoreKit
import SessionSnodeKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let maxRootViewControllerInitialQueryDuration: TimeInterval = 10
    
    var window: UIWindow?
    var backgroundSnapshotBlockerWindow: UIWindow?
    var appStartupWindow: UIWindow?
    var initialLaunchFailed: Bool = false
    var hasInitialRootViewController: Bool = false
    var startTime: CFTimeInterval = 0
    private var loadingViewController: LoadingViewController?
    
    /// This needs to be a lazy variable to ensure it doesn't get initialized before it actually needs to be used
    lazy var poller: CurrentUserPoller = CurrentUserPoller()
    
    // MARK: - Lifecycle

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Log.info("[AppDelegate] didFinishLaunchingWithOptions called.")
        startTime = CACurrentMediaTime()
        
        // These should be the first things we do (the startup process can fail without them)
        Singleton.setup(appContext: MainAppContext())
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
        
        AppSetup.setupEnvironment(
            appSpecificBlock: {
                Log.setup(with: Logger(primaryPrefix: "Session"))
                Log.info("[AppDelegate] Setting up environment.")
                
                // Setup LibSession
                LibSession.addLogger()
                LibSession.createNetworkIfNeeded()
                
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
                    DispatchQueue.main.async {
                        self?.initialLaunchFailed = true
                        self?.showFailedStartupAlert(calledFrom: .finishLaunching, error: .databaseError(error))
                    }
                    return
                }
                
                /// Store a weak reference in the ThemeManager so it can properly apply themes as needed
                ///
                /// **Note:** Need to do this after the db migrations because theme preferences are stored in the database and
                /// we don't want to access it until after the migrations run
                ThemeManager.mainWindow = mainWindow
                self?.completePostMigrationSetup(calledFrom: .finishLaunching, needsConfigSync: needsConfigSync)
            }
        )
        
        if SessionEnvironment.shared?.callManager.wrappedValue?.currentCall == nil {
            UserDefaults.sharedLokiProject?[.isCallOngoing] = false
            UserDefaults.sharedLokiProject?[.lastCallPreOffer] = nil
        }
        
        // No point continuing if we are running tests
        guard !SNUtilitiesKit.isRunningTests else { return true }

        self.window = mainWindow
        Singleton.appContext.setMainWindow(mainWindow)
        
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
        
        Log.info("[AppDelegate] didFinishLaunchingWithOptions completed.")
        return true
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        Log.appResumedExecution()
        Log.info("[AppDelegate] applicationWillEnterForeground.")
        
        /// **Note:** We _shouldn't_ need to call this here but for some reason the OS doesn't seems to
        /// be calling the `userNotificationCenter(_:,didReceive:withCompletionHandler:)`
        /// method when the device is locked while the app is in the foreground (or if the user returns to the
        /// springboard without swapping to another app) - adding this here in addition to the one in
        /// `appDidFinishLaunching` seems to fix this odd behaviour (even though it doesn't match
        /// Apple's documentation on the matter)
        UNUserNotificationCenter.current().delegate = self
        
        Storage.resumeDatabaseAccess()
        LibSession.resumeNetworkAccess()
        
        // Reset the 'startTime' (since it would be invalid from the last launch)
        startTime = CACurrentMediaTime()
        
        // If we've already completed migrations at least once this launch then check
        // to see if any "delayed" migrations now need to run
        if Storage.shared.hasCompletedMigrations {
            Log.info("Checking for pending migrations")
            let initialLaunchFailed: Bool = self.initialLaunchFailed
            
            Singleton.appReadiness.invalidate()
            
            // If the user went to the background too quickly then the database can be suspended before
            // properly starting up, in this case an alert will be shown but we can recover from it so
            // dismiss any alerts that were shown
            if initialLaunchFailed {
                self.window?.rootViewController?.dismiss(animated: false)
            }
            
            // Dispatch async so things can continue to be progressed if a migration does need to run
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                AppSetup.runPostSetupMigrations(
                    migrationProgressChanged: { progress, minEstimatedTotalTime in
                        self?.loadingViewController?.updateProgress(
                            progress: progress,
                            minEstimatedTotalTime: minEstimatedTotalTime
                        )
                    },
                    migrationsCompletion: { result, needsConfigSync in
                        if case .failure(let error) = result {
                            DispatchQueue.main.async {
                                self?.showFailedStartupAlert(
                                    calledFrom: .enterForeground(initialLaunchFailed: initialLaunchFailed),
                                    error: .databaseError(error)
                                )
                            }
                            return
                        }
                        
                        self?.completePostMigrationSetup(
                            calledFrom: .enterForeground(initialLaunchFailed: initialLaunchFailed),
                            needsConfigSync: needsConfigSync
                        )
                    }
                )
            }
        }
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        if !hasInitialRootViewController { Log.info("Entered background before startup was completed") }
        Log.info("[AppDelegate] applicationDidEnterBackground.")
        Log.flush()
        
        // NOTE: Fix an edge case where user taps on the callkit notification
        // but answers the call on another device
        stopPollers(shouldStopUserPoller: !self.hasCallOngoing())
        
        // FIXME: Move this to be initialised as part of `AppDelegate`
        let dependencies: Dependencies = Dependencies()
        
        // Stop all jobs except for message sending and when completed suspend the database
        JobRunner.stopAndClearPendingJobs(exceptForVariant: .messageSend, using: dependencies) {
            if !self.hasCallOngoing() {
                LibSession.suspendNetworkAccess()
                Storage.suspendDatabaseAccess()
                Log.info("[AppDelegate] completed network and database shutdowns.")
                Log.flush()
            }
        }
    }
    
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        Log.warn("applicationDidReceiveMemoryWarning")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        Log.info("[AppDelegate] applicationWillTerminate.")
        Log.flush()

        stopPollers()
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        Log.info("[AppDelegate] applicationDidBecomeActive.")
        guard !SNUtilitiesKit.isRunningTests else { return }
        
        UserDefaults.sharedLokiProject?[.isMainAppActive] = true
        
        ensureRootViewController(calledFrom: .didBecomeActive)

        Singleton.appReadiness.runNowOrWhenAppDidBecomeReady { [weak self] in
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
        guard Singleton.hasAppContext else { return }
        
        Singleton.appContext.clearOldTemporaryDirectories()
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        Log.info("[AppDelegate] applicationWillResignActive.")
        clearAllNotificationsAndRestoreBadgeCount()
        
        UserDefaults.sharedLokiProject?[.isMainAppActive] = false

        Log.flush()
    }
    
    // MARK: - Orientation

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.isIPad {
            return .all
        }
        
        return .portrait
    }
    
    // MARK: - Background Fetching
    
    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Log.appResumedExecution()
        Log.info("Starting background fetch.")
        Storage.resumeDatabaseAccess()
        LibSession.resumeNetworkAccess()
        
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
            
            Log.info("Background poll failed due to manual timeout.")
            BackgroundPoller.isValid = false
            
            if Singleton.hasAppContext && Singleton.appContext.isInBackground {
                LibSession.suspendNetworkAccess()
                Storage.suspendDatabaseAccess()
                Log.flush()
            }
            
            completionHandler(.failed)
        }
        
        // Flag the background poller as valid first and then trigger it to poll once the app is
        // ready (we do this here rather than in `BackgroundPoller.poll` to avoid the rare edge-case
        // that could happen when the timeout triggers before the app becomes ready which would have
        // incorrectly set this 'isValid' flag to true after it should have timed out)
        BackgroundPoller.isValid = true
        
        Singleton.appReadiness.runNowOrWhenAppDidBecomeReady {
            // If the 'AppReadiness' process takes too long then it's possible for the user to open
            // the app after this closure is registered but before it's actually triggered - this can
            // result in the `BackgroundPoller` incorrectly getting called in the foreground, this check
            // is here to prevent that
            guard Singleton.hasAppContext && Singleton.appContext.isInBackground else {
                BackgroundPoller.isValid = false
                return
            }
            
            BackgroundPoller.poll { result in
                guard BackgroundPoller.isValid else { return }
                
                BackgroundPoller.isValid = false
                
                if Singleton.hasAppContext && Singleton.appContext.isInBackground {
                    LibSession.suspendNetworkAccess()
                    Storage.suspendDatabaseAccess()
                    Log.flush()
                }
                
                cancelTimer.invalidate()
                completionHandler(result)
            }
        }
    }
    
    // MARK: - App Readiness
    
    private func completePostMigrationSetup(calledFrom lifecycleMethod: LifecycleMethod, needsConfigSync: Bool) {
        Log.info("Migrations completed, performing setup and ensuring rootViewController")
        Configuration.performMainSetup()
        JobRunner.setExecutor(SyncPushTokensJob.self, for: .syncPushTokens)
        
        /// We need to do a clean up for disappear after send messages that are received by push notifications before
        /// the app set up the main screen and load initial data to prevent a case when the PagedDatabaseObserver
        /// hasn't been setup yet then the conversation screen can show stale (ie. deleted) interactions incorrectly
        DisappearingMessagesJob.cleanExpiredMessagesOnLaunch()
        
        // Setup the UI if needed, then trigger any post-UI setup actions
        self.ensureRootViewController(calledFrom: lifecycleMethod) { [weak self] success in
            // If we didn't successfully ensure the rootViewController then don't continue as
            // the user is in an invalid state (and should have already been shown a modal)
            guard success else { return }
            
            Log.info("RootViewController ready for state: \(Onboarding.State.current), readying remaining processes")
            self?.initialLaunchFailed = false
            
            /// Trigger any launch-specific jobs and start the JobRunner with `JobRunner.appDidFinishLaunching()` some
            /// of these jobs (eg. DisappearingMessages job) can impact the interactions which get fetched to display on the home
            /// screen, if the PagedDatabaseObserver hasn't been setup yet then the home screen can show stale (ie. deleted)
            /// interactions incorrectly
            if lifecycleMethod == .finishLaunching {
                JobRunner.appDidFinishLaunching()
            }
            
            /// Flag that the app is ready via `AppReadiness.setAppIsReady()`
            ///
            /// If we are launching the app from a push notification we need to ensure we wait until after the `HomeVC` is setup
            /// otherwise it won't open the related thread
            ///
            /// **Note:** This this does much more than set a flag - it will also run all deferred blocks (including the JobRunner
            /// `appDidBecomeActive` method hence why it **must** also come after calling
            /// `JobRunner.appDidFinishLaunching()`)
            Singleton.appReadiness.setAppReady()
            
            /// Remove the sleep blocking once the startup is done (needs to run on the main thread and sleeping while
            /// doing the startup could suspend the database causing errors/crashes
            DeviceSleepManager.sharedInstance.removeBlock(blockObject: self)
            
            /// App launch hasn't really completed until the main screen is loaded so wait until then to register it
            AppVersion.sharedInstance().mainAppLaunchDidComplete()
            
            /// App won't be ready for extensions and no need to enqueue a config sync unless we successfully completed startup
            Storage.shared.writeAsync { db in
                // Increment the launch count (guaranteed to change which results in the write actually
                // doing something and outputting and error if the DB is suspended)
                db[.activeCounter] = ((db[.activeCounter] ?? 0) + 1)
                
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
            
            // Add a log to track the proper startup time of the app so we know whether we need to
            // improve it in the future from user logs
            let startupDuration: CFTimeInterval = ((self?.startTime).map { CACurrentMediaTime() - $0 } ?? -1)
            Log.info("\(lifecycleMethod.timingName) completed in \(.seconds(startupDuration), unit: .ms).")
        }
        
        // May as well run these on the background thread
        SessionEnvironment.shared?.audioSession.setup()
    }
    
    private func showFailedStartupAlert(
        calledFrom lifecycleMethod: LifecycleMethod,
        error: StartupError,
        animated: Bool = true,
        presentationCompletion: (() -> ())? = nil
    ) {
        /// This **must** be a standard `UIAlertController` instead of a `ConfirmationModal` because we may not
        /// have access to the database when displaying this so can't extract theme information for styling purposes
        let alert: UIAlertController = UIAlertController(
            title: "Session",
            message: error.message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "HELP_REPORT_BUG_ACTION_TITLE".localized(), style: .default) { _ in
            HelpViewModel.shareLogs(viewControllerToDismiss: alert) { [weak self] in
                // Don't bother showing the "Failed Startup" modal again if we happen to now
                // have an initial view controller (this most likely means that the startup
                // completed while the user was sharing logs so we can just let the user use
                // the app)
                guard self?.hasInitialRootViewController == false else { return }
                
                self?.showFailedStartupAlert(calledFrom: lifecycleMethod, error: error)
            }
        })
        
        switch error {
            // Don't offer the 'Restore' option if it was a 'startupFailed' error as a restore is unlikely to
            // resolve it (most likely the database is locked or the key was somehow lost - safer to get them
            // to restart and manually reinstall/restore)
            case .databaseError(StorageError.startupFailed), .databaseError(DatabaseError.SQLITE_LOCKED): break
                
            // Offer the 'Restore' option if it was a migration error
            case .databaseError:
                alert.addAction(UIAlertAction(title: "vc_restore_title".localized(), style: .destructive) { _ in
                    // Reset the current database for a clean migration
                    Storage.resetForCleanMigration()
                    
                    // Hide the top banner if there was one
                    TopBannerController.hide()
                    
                    // The re-run the migration (should succeed since there is no data)
                    AppSetup.runPostSetupMigrations(
                        migrationProgressChanged: { [weak self] progress, minEstimatedTotalTime in
                            self?.loadingViewController?.updateProgress(
                                progress: progress,
                                minEstimatedTotalTime: minEstimatedTotalTime
                            )
                        },
                        migrationsCompletion: { [weak self] result, needsConfigSync in
                            switch result {
                                case .failure:
                                    DispatchQueue.main.async {
                                        self?.showFailedStartupAlert(calledFrom: lifecycleMethod, error: .failedToRestore)
                                    }
                                    
                                case .success:
                                    self?.completePostMigrationSetup(calledFrom: lifecycleMethod, needsConfigSync: needsConfigSync)
                            }
                        }
                    )
                })
                
            default: break
        }
        
        alert.addAction(UIAlertAction(title: "APP_STARTUP_EXIT".localized(), style: .default) { _ in
            Log.flush()
            exit(0)
        })
        
        Log.info("Showing startup alert due to error: \(error.name)")
        self.window?.rootViewController?.present(alert, animated: animated, completion: presentationCompletion)
    }
    
    /// The user must unlock the device once after reboot before the database encryption key can be accessed.
    private func verifyDBKeysAvailableBeforeBackgroundLaunch() {
        guard UIApplication.shared.applicationState == .background else { return }
        
        guard !Storage.isDatabasePasswordAccessible else { return }    // All good
        
        Log.info("Exiting because we are in the background and the database password is not accessible.")
        
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
        
        Log.flush()
        exit(0)
    }
    
    private func enableBackgroundRefreshIfNecessary() {
        Singleton.appReadiness.runNowOrWhenAppDidBecomeReady {
            UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        }
    }

    private func handleActivation() {
        /// There is a _fun_ behaviour here where if the user launches the app, sends it to the background at the right time and then
        /// opens it again the `AppReadiness` closures can be triggered before `applicationDidBecomeActive` has been
        /// called again - this can result in odd behaviours so hold off on running this logic until it's properly called again
        guard UserDefaults.sharedLokiProject?[.isMainAppActive] == true else { return }
        
        /// There is a warning which can happen on launch because the Database read can be blocked by another database operation
        /// which could result in this blocking the main thread, as a result we want to check the identity exists on a background thread
        /// and then return to the main thread only when required
        DispatchQueue.global(qos: .default).async { [weak self] in
            guard Identity.userExists() else { return }
            
            self?.enableBackgroundRefreshIfNecessary()
            JobRunner.appDidBecomeActive()
            
            self?.startPollersIfNeeded()
            
            if Singleton.hasAppContext && Singleton.appContext.isMainApp {
                DispatchQueue.main.async {
                    self?.handleAppActivatedWithOngoingCallIfNeeded()
                }
            }
        }
    }
    
    private func ensureRootViewController(
        calledFrom lifecycleMethod: LifecycleMethod,
        onComplete: @escaping ((Bool) -> ()) = { _ in }
    ) {
        let hasInitialRootViewController: Bool = self.hasInitialRootViewController
        
        // Always call the completion block and indicate whether we successfully created the UI
        guard
            Storage.shared.isValid &&
            (
                Singleton.appReadiness.isAppReady ||
                lifecycleMethod == .finishLaunching ||
                lifecycleMethod == .enterForeground(initialLaunchFailed: true)
            ) &&
            !hasInitialRootViewController
        else { return DispatchQueue.main.async { onComplete(hasInitialRootViewController) } }
        
        /// Start a timeout for the creation of the rootViewController setup process (if it takes too long then we want to give the user
        /// the option to export their logs)
        let populateHomeScreenTimer: Timer = Timer.scheduledTimerOnMainThread(
            withTimeInterval: AppDelegate.maxRootViewControllerInitialQueryDuration,
            repeats: false
        ) { [weak self] timer in
            timer.invalidate()
            self?.showFailedStartupAlert(calledFrom: lifecycleMethod, error: .startupTimeout)
        }
        
        // All logic which needs to run after the 'rootViewController' is created
        let rootViewControllerSetupComplete: (UIViewController) -> () = { [weak self] rootViewController in
            let presentedViewController: UIViewController? = self?.window?.rootViewController?.presentedViewController
            let targetRootViewController: UIViewController = TopBannerController(
                child: StyledNavigationController(rootViewController: rootViewController),
                cachedWarning: UserDefaults.sharedLokiProject?[.topBannerWarningToShow]
                    .map { rawValue in TopBannerController.Warning(rawValue: rawValue) }
            )
            
            /// Insert the `targetRootViewController` below the current view and trigger a layout without animation before properly
            /// swapping the `rootViewController` over so we can avoid any weird initial layout behaviours
            UIView.performWithoutAnimation {
                self?.window?.rootViewController = targetRootViewController
            }
            
            self?.hasInitialRootViewController = true
            UIViewController.attemptRotationToDeviceOrientation()
            
            /// **Note:** There is an annoying case when starting the app by interacting with a push notification where
            /// the `HomeVC` won't have completed loading it's view which means the `SessionApp.homeViewController`
            /// won't have been set - we set the value directly here to resolve this edge case
            if let homeViewController: HomeVC = rootViewController as? HomeVC {
                SessionApp.homeViewController.mutate { $0 = homeViewController }
            }
            
            /// If we were previously presenting a viewController but are no longer preseting it then present it again
            ///
            /// **Note:** Looks like the OS will throw an exception if we try to present a screen which is already (or
            /// was previously?) presented, even if it's not attached to the screen it seems...
            switch presentedViewController {
                case is UIAlertController, is ConfirmationModal:
                    /// If the viewController we were presenting happened to be the "failed startup" modal then we can dismiss it
                    /// automatically (while this seems redundant it's less jarring for the user than just instantly having it disappear)
                    self?.showFailedStartupAlert(calledFrom: lifecycleMethod, error: .startupTimeout, animated: false) {
                        self?.window?.rootViewController?.dismiss(animated: true)
                    }
                
                case is UIActivityViewController: HelpViewModel.shareLogs(animated: false)
                default: break
            }
            
            // Setup is completed so run any post-setup tasks
            onComplete(true)
        }
        
        // Navigate to the approriate screen depending on the onboarding state
        switch Onboarding.State.current {
            case .newUser:
                DispatchQueue.main.async {
                    let viewController = SessionHostingViewController(rootView: LandingScreen())
                    viewController.setUpNavBarSessionIcon()
                    populateHomeScreenTimer.invalidate()
                    rootViewControllerSetupComplete(viewController)
                }
                
            case .missingName:
                DispatchQueue.main.async {
                    let viewController = SessionHostingViewController(rootView: DisplayNameScreen(flow: .register))
                    viewController.setUpNavBarSessionIcon()
                    populateHomeScreenTimer.invalidate()
                    rootViewControllerSetupComplete(viewController)
                }
                
            case .completed:
                DispatchQueue.main.async {
                    let viewController: HomeVC = HomeVC()
                    
                    /// We want to start observing the changes for the 'HomeVC' and want to wait until we actually get data back before we
                    /// continue as we don't want to show a blank home screen
                    DispatchQueue.global(qos: .userInitiated).async {
                        viewController.startObservingChanges() {
                            populateHomeScreenTimer.invalidate()
                            
                            DispatchQueue.main.async {
                                rootViewControllerSetupComplete(viewController)
                            }
                        }
                    }
                }
        }
    }
    
    // MARK: - Notifications
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistrationManager.shared.didReceiveVanillaPushToken(deviceToken)
        Log.info("Registering for push notifications.")
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.error("Failed to register push token with error: \(error).")
        
        #if DEBUG
        Log.warn("We're in debug mode. Faking success for remote registration with a fake push identifier.")
        PushRegistrationManager.shared.didReceiveVanillaPushToken(Data(count: 32))
        #else
        PushRegistrationManager.shared.didFailToReceiveVanillaPushToken(error: error)
        #endif
    }
    
    private func clearAllNotificationsAndRestoreBadgeCount() {
        Singleton.appReadiness.runNowOrWhenAppDidBecomeReady {
            AppEnvironment.shared.notificationPresenter.clearAllNotifications()
            
            guard Singleton.hasAppContext && Singleton.appContext.isMainApp else { return }
            
            /// On application startup the `Storage.read` can be slightly slow while GRDB spins up it's database
            /// read pools (up to a few seconds), since this read is blocking we want to dispatch it to run async to ensure
            /// we don't block user interaction while it's running
            DispatchQueue.global(qos: .default).async {
                let unreadCount: Int = Storage.shared
                    .read { db in try Interaction.fetchUnreadCount(db) }
                    .defaulting(to: 0)
                
                DispatchQueue.main.async {
                    UIApplication.shared.applicationIconBadgeNumber = unreadCount
                }
            }
        }
    }
    
    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        Singleton.appReadiness.runNowOrWhenAppDidBecomeReady {
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
            Log.info("Ignoring remote notifications while the app is in the foreground.")
            return
        }
        
        Singleton.appReadiness.runNowOrWhenAppDidBecomeReady {
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
        Singleton.appReadiness.runNowOrWhenAppDidBecomeReady {
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
        guard
            Singleton.hasAppContext,
            let presentingVC = Singleton.appContext.frontmostViewController
        else { preconditionFailure() }
        
        let callMissedTipsModal: CallMissedTipsModal = CallMissedTipsModal(
            caller: Profile.displayName(id: callerId)
        )
        presentingVC.present(callMissedTipsModal, animated: true, completion: nil)
        
        UserDefaults.standard[.hasSeenCallMissedTips] = true
    }
    
    // MARK: - Polling
    
    public func startPollersIfNeeded(shouldStartGroupPollers: Bool = true) {
        guard Identity.userExists() else { return }
        
        /// There is a fun issue where if you launch without any valid paths then the pollers are guaranteed to fail their first poll due to
        /// trying and failing to build paths without having the `SnodeAPI.snodePool` populated, by waiting for the
        /// `JobRunner.blockingQueue` to complete we can have more confidence that paths won't fail to build incorrectly
        JobRunner.afterBlockingQueue { [weak self] in
            self?.poller.start()
            
            guard shouldStartGroupPollers else { return }
            
            ClosedGroupPoller.shared.start()
            OpenGroupManager.shared.startPolling()
        }
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
            MiniCallView.current == nil,
            Singleton.hasAppContext
        else { return }
        
        if let callVC = Singleton.appContext.frontmostViewController as? CallVC, callVC.call.uuid == call.uuid {
            return
        }
        
        // FIXME: Handle more gracefully
        guard let presentingVC = Singleton.appContext.frontmostViewController else { preconditionFailure() }
        
        let callVC: CallVC = CallVC(for: call)
        
        if
            let conversationVC: ConversationVC = (presentingVC as? TopBannerController)?.wrappedViewController() as? ConversationVC,
            conversationVC.viewModel.threadData.threadId == call.sessionId
        {
            callVC.conversationVC = conversationVC
            conversationVC.inputAccessoryView?.isHidden = true
            conversationVC.inputAccessoryView?.alpha = 0
        }
        
        presentingVC.present(callVC, animated: true, completion: nil)
    }
}

// MARK: - LifecycleMethod

private enum LifecycleMethod: Equatable {
    case finishLaunching
    case enterForeground(initialLaunchFailed: Bool)
    case didBecomeActive
    
    var timingName: String {
        switch self {
            case .finishLaunching: return "Launch"              // stringlint:disable
            case .enterForeground: return "EnterForeground"     // stringlint:disable
            case .didBecomeActive: return "BecomeActive"        // stringlint:disable
        }
    }
    
    static func == (lhs: LifecycleMethod, rhs: LifecycleMethod) -> Bool {
        switch (lhs, rhs) {
            case (.finishLaunching, .finishLaunching): return true
            case (.enterForeground(let lhsFailed), .enterForeground(let rhsFailed)): return (lhsFailed == rhsFailed)
            case (.didBecomeActive, .didBecomeActive): return true
            default: return false
        }
    }
}

// MARK: - StartupError

private enum StartupError: Error {
    case databaseError(Error)
    case failedToRestore
    case startupTimeout
    
    var name: String {
        switch self {
            case .databaseError(StorageError.startupFailed), .databaseError(DatabaseError.SQLITE_LOCKED):
                return "Database startup failed"
            
            case .databaseError(StorageError.migrationNoLongerSupported): return "Unsupported version"
            case .failedToRestore: return "Failed to restore"
            case .databaseError: return "Database error"
            case .startupTimeout: return "Startup timeout"
        }
    }
    
    var message: String {
        switch self {
            case .databaseError(StorageError.startupFailed), .databaseError(DatabaseError.SQLITE_LOCKED):
                return "DATABASE_STARTUP_FAILED".localized()

            case .databaseError(StorageError.migrationNoLongerSupported):
                return "DATABASE_UNSUPPORTED_MIGRATION".localized()
            
            case .failedToRestore: return "DATABASE_RESTORE_FAILED".localized()
            case .databaseError: return "DATABASE_MIGRATION_FAILED".localized()
            case .startupTimeout: return "APP_STARTUP_TIMEOUT".localized()
        }
    }
}
