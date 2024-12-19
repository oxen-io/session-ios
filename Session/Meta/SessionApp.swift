// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit
import SessionMessagingKit
import SessionUIKit

// MARK: - Singleton

public extension Singleton {
    static let app: SingletonConfig<SessionAppType> = Dependencies.create(
        identifier: "app",
        createInstance: { dependencies in SessionApp(using: dependencies) }
    )
}

// MARK: - SessionApp

public class SessionApp: SessionAppType {
    private let dependencies: Dependencies
    private var homeViewController: HomeVC?
    
    static var versionInfo: String {
        let buildNumber: String = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
            .map { " (\($0))" }
            .defaulting(to: "")
        let appVersion: String? = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .map { "App: \($0)\(buildNumber)" }
        let commitInfo: String? = (Bundle.main.infoDictionary?["GitCommitHash"] as? String).map { "Commit: \($0)" }
        
        let versionInfo: [String] = [
            "iOS \(UIDevice.current.systemVersion)",
            appVersion,
            "libSession: \(LibSession.version)",
            commitInfo
        ].compactMap { $0 }
        
        return versionInfo.joined(separator: ", ")
    }
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Functions
    
    public func setHomeViewController(_ homeViewController: HomeVC) {
        self.homeViewController = homeViewController
    }
    
    public func showHomeView() {
        guard Thread.isMainThread else {
            return DispatchQueue.main.async {
                self.showHomeView()
            }
        }
        
        let homeViewController: HomeVC = HomeVC(using: dependencies)
        let navController: UINavigationController = StyledNavigationController(rootViewController: homeViewController)
        (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController = navController
        self.homeViewController = homeViewController
    }
    
    public func presentConversationCreatingIfNeeded(
        for threadId: String,
        variant: SessionThread.Variant,
        action: ConversationViewModel.Action = .none,
        dismissing presentingViewController: UIViewController?,
        animated: Bool
    ) {
        guard let homeViewController: HomeVC = self.homeViewController else {
            Log.error("[SessionApp] Unable to present conversation due to missing HomeVC.")
            return
        }
        
        let threadInfo: (threadExists: Bool, isMessageRequest: Bool)? = dependencies[singleton: .storage].read { [dependencies] db in
            let isMessageRequest: Bool = {
                switch variant {
                    case .contact, .group:
                        return SessionThread
                            .isMessageRequest(
                                db,
                                threadId: threadId,
                                userSessionId: dependencies[cache: .general].sessionId,
                                includeNonVisible: true
                            )
                        
                    default: return false
                }
            }()
            
            return (SessionThread.filter(id: threadId).isNotEmpty(db), isMessageRequest)
        }
        
        /// The thread should generally exist at the time of calling this method, but on the off chance it doesn't then we need to `fetchOrCreate` it and
        /// should do it on a background thread just in case something is keeping the DBWrite thread busy as in the past this could cause the app to hang
        creatingThreadIfNeededThenRunOnMain(
            threadId: threadId,
            variant: variant,
            threadExists: (threadInfo?.threadExists == true),
            onComplete: { [weak self] in
                self?.showConversation(
                    threadId: threadId,
                    threadVariant: variant,
                    isMessageRequest: (threadInfo?.isMessageRequest == true),
                    action: action,
                    dismissing: presentingViewController,
                    homeViewController: homeViewController,
                    animated: animated
                )
            }
        )
    }
    
    public func createNewConversation() {
        guard let homeViewController: HomeVC = self.homeViewController else { return }
        
        let viewController = SessionHostingViewController(
            rootView: StartConversationScreen(using: dependencies),
            customizedNavigationBackground: .backgroundSecondary
        )
        viewController.setNavBarTitle("conversationsStart".localized())
        viewController.setUpDismissingButton(on: .right)
        
        let navigationController = StyledNavigationController(rootViewController: viewController)
        if UIDevice.current.isIPad {
            navigationController.modalPresentationStyle = .fullScreen
        }
        navigationController.modalPresentationCapturesStatusBarAppearance = true
        homeViewController.present(navigationController, animated: true, completion: nil)
    }
    
    public func resetData(onReset: (() -> ())) {
        homeViewController = nil
        LibSession.clearLoggers()
        dependencies.remove(cache: .libSession)
        dependencies.mutate(cache: .libSessionNetwork) {
            $0.clearSnodeCache()
            $0.suspendNetworkAccess()
        }
        dependencies[singleton: .storage].resetAllStorage()
        DisplayPictureManager.resetStorage(using: dependencies)
        Attachment.resetAttachmentStorage(using: dependencies)
        dependencies[singleton: .notificationsManager].clearAllNotifications()
        try? dependencies[singleton: .keychain].removeAll()
        
        onReset()
        Log.info("Data Reset Complete.")
        Log.flush()
        
        /// Wait until the next run loop to kill the app (hoping to avoid a crash due to the connection closes
        /// triggering logs)
        DispatchQueue.main.async {
            exit(0)
        }
    }
    
    // MARK: - Internal Functions
    
    private func creatingThreadIfNeededThenRunOnMain(
        threadId: String,
        variant: SessionThread.Variant,
        threadExists: Bool,
        onComplete: @escaping () -> Void
    ) {
        guard !threadExists else {
            switch Thread.isMainThread {
                case true: return onComplete()
                case false: return DispatchQueue.main.async(using: dependencies) { onComplete() }
            }
        }
        guard !Thread.isMainThread else {
            return DispatchQueue.global(qos: .userInitiated).async(using: dependencies) { [weak self] in
                self?.creatingThreadIfNeededThenRunOnMain(
                    threadId: threadId,
                    variant: variant,
                    threadExists: threadExists,
                    onComplete: onComplete
                )
            }
        }
        
        dependencies[singleton: .storage].write { [dependencies] db in
            try SessionThread.upsert(
                db,
                id: threadId,
                variant: variant,
                values: SessionThread.TargetValues(
                    shouldBeVisible: .useLibSession,
                    isDraft: (threadExists ? .useExisting : .setTo(true))
                ),
                calledFromConfig: nil,
                using: dependencies
            )
        }
        
        DispatchQueue.main.async(using: dependencies) {
            onComplete()
        }
    }
    
    private func showConversation(
        threadId: String,
        threadVariant: SessionThread.Variant,
        isMessageRequest: Bool,
        action: ConversationViewModel.Action,
        dismissing presentingViewController: UIViewController?,
        homeViewController: HomeVC,
        animated: Bool
    ) {
        presentingViewController?.dismiss(animated: true, completion: nil)
        
        homeViewController.navigationController?.setViewControllers(
            [
                homeViewController,
                (isMessageRequest && action != .compose ?
                    SessionTableViewController(viewModel: MessageRequestsViewModel(using: dependencies)) :
                    nil
                ),
                ConversationVC(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    focusedInteractionInfo: nil,
                    using: dependencies
                )
            ].compactMap { $0 },
            animated: animated
        )
    }
}

// MARK: - SessionAppType

public protocol SessionAppType {
    func setHomeViewController(_ homeViewController: HomeVC)
    func showHomeView()
    func presentConversationCreatingIfNeeded(
        for threadId: String,
        variant: SessionThread.Variant,
        action: ConversationViewModel.Action,
        dismissing presentingViewController: UIViewController?,
        animated: Bool
    )
    func createNewConversation()
    func resetData(onReset: (() -> ()))
}

public extension SessionAppType {
    func resetData() { resetData(onReset: {}) }
}
