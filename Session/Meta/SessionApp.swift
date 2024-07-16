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
                    dismissing: presentingViewController,
                    homeViewController: homeViewController,
                    animated: animated
                )
            }
        )
    }
    
    public func createNewConversation() {
        guard let homeViewController: HomeVC = self.homeViewController else { return }
        
        let newConversationVC = NewConversationVC(using: dependencies)
        let navigationController = StyledNavigationController(rootViewController: newConversationVC)
        if UIDevice.current.isIPad {
            navigationController.modalPresentationStyle = .fullScreen
        }
        navigationController.modalPresentationCapturesStatusBarAppearance = true
        homeViewController.present(navigationController, animated: true, completion: nil)
    }
    
    public func resetData(onReset: (() -> ())) {
        homeViewController = nil
        LibSession.clearMemoryState(using: dependencies)
        dependencies.mutate(cache: .libSessionNetwork) {
            $0.clearSnodeCache()
            $0.suspendNetworkAccess()
        }
        PushNotificationAPI.deleteKeys(using: dependencies)
        Storage.resetAllStorage(using: dependencies)
        DisplayPictureManager.resetStorage(using: dependencies)
        Attachment.resetAttachmentStorage()
        dependencies[singleton: .notificationsManager].clearAllNotifications()
        try? dependencies[singleton: .keychain].removeAll()
        Log.flush()

        onReset()
        exit(0)
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
            try SessionThread.fetchOrCreate(
                db,
                id: threadId,
                variant: variant,
                shouldBeVisible: nil,
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
        dismissing presentingViewController: UIViewController?,
        homeViewController: HomeVC,
        animated: Bool
    ) {
        presentingViewController?.dismiss(animated: true, completion: nil)
        
        homeViewController.navigationController?.setViewControllers(
            [
                homeViewController,
                (!isMessageRequest ? nil :
                    SessionTableViewController(viewModel: MessageRequestsViewModel(using: dependencies))
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
        dismissing presentingViewController: UIViewController?,
        animated: Bool
    )
    func createNewConversation()
    func resetData(onReset: (() -> ()))
}

public extension SessionAppType {
    func resetData() { resetData(onReset: {}) }
}
