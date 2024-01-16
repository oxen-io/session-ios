// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit
import SessionMessagingKit
import SignalCoreKit
import SessionUIKit

public struct SessionApp {
    // FIXME: Refactor this to be protocol based for unit testing (or even dynamic based on view hierarchy - do want to avoid needing to use the main thread to access them though)
    static let homeViewController: Atomic<HomeVC?> = Atomic(nil)
    static let currentlyOpenConversationViewController: Atomic<ConversationVC?> = Atomic(nil)
    
    static var versionInfo: String {
        let buildNumber: String = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
            .map { " (\($0))" }
            .defaulting(to: "")
        let appVersion: String? = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .map { "App: \($0)\(buildNumber)" }
        #if DEBUG
        let commitInfo: String? = (Bundle.main.infoDictionary?["GitCommitHash"] as? String).map { "Commit: \($0)" }
        #else
        let commitInfo: String? = nil
        #endif
        
        let versionInfo: [String] = [
            "iOS \(UIDevice.current.systemVersion)",
            appVersion,
            "libSession: \(LibSession.version)",
            commitInfo
        ].compactMap { $0 }
        
        return versionInfo.joined(separator: ", ")
    }
    
    // MARK: - View Convenience Methods
    
    public static func presentConversationCreatingIfNeeded(
        for threadId: String,
        variant: SessionThread.Variant,
        action: ConversationViewModel.Action = .none,
        dismissing presentingViewController: UIViewController?,
        animated: Bool,
        using dependencies: Dependencies
    ) {
        let threadInfo: (threadExists: Bool, isMessageRequest: Bool)? = dependencies[singleton: .storage].read { db in
            let isMessageRequest: Bool = {
                switch variant {
                    case .contact, .group:
                        return SessionThread
                            .isMessageRequest(
                                db,
                                threadId: threadId,
                                userSessionId: getUserSessionId(db, using: dependencies),
                                includeNonVisible: true
                            )
                        
                    default: return false
                }
            }()
            
            return (SessionThread.filter(id: threadId).isNotEmpty(db), isMessageRequest)
        }
        
        // Store the post-creation logic in a closure to avoid duplication
        let afterThreadCreated: () -> () = {
            presentingViewController?.dismiss(animated: true, completion: nil)
            
            homeViewController.wrappedValue?.show(
                threadId,
                variant: variant,
                isMessageRequest: (threadInfo?.isMessageRequest == true),
                with: action,
                focusedInteractionInfo: nil,
                animated: animated
            )
        }
        
        /// The thread should generally exist at the time of calling this method, but on the off chance it doesn't then we need to `fetchOrCreate` it and
        /// should do it on a background thread just in case something is keeping the DBWrite thread busy as in the past this could cause the app to hang
        guard threadInfo?.threadExists == true else {
            DispatchQueue.global(qos: .userInitiated).async {
                dependencies[singleton: .storage].write { db in
                    try SessionThread.fetchOrCreate(
                        db,
                        id: threadId,
                        variant: variant,
                        shouldBeVisible: nil,
                        calledFromConfigHandling: false,
                        using: dependencies
                    )
                }

                // Send back to main thread for UI transitions
                DispatchQueue.main.async {
                    afterThreadCreated()
                }
            }
            return
        }
        
        // Send to main thread if needed
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                afterThreadCreated()
            }
            return
        }
        
        afterThreadCreated()
    }

    // MARK: - Functions
    
    public static func resetAppData(using dependencies: Dependencies, onReset: (() -> ())? = nil) {
        // This _should_ be wiped out below.
        Logger.error("")
        DDLog.flushLog()
        
        LibSession.clearMemoryState(using: dependencies)
        Storage.resetAllStorage(using: dependencies)
        DisplayPictureManager.resetStorage(using: dependencies)
        Attachment.resetAttachmentStorage()
        dependencies[singleton: .notificationsManager].clearAllNotifications()
        dependencies[singleton: .keychain].removeAll()

        onReset?()
        exit(0)
    }
    
    public static func showHomeView() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.showHomeView()
            }
            return
        }
        
        let homeViewController: HomeVC = HomeVC()
        let navController: UINavigationController = StyledNavigationController(rootViewController: homeViewController)
        (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController = navController
    }
}
