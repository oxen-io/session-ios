// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SignalCoreKit
import SignalUtilitiesKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let notificationActionHandler: SingletonConfig<NotificationActionHandler> = Dependencies.create(
        identifier: "notificationActionHandler",
        createInstance: { _ in NotificationActionHandler() }
    )
}

// MARK: - NotificationActionHandler

public class NotificationActionHandler {
    // MARK: - Handling
    
    func handleNotificationResponse(
        _ response: UNNotificationResponse,
        completionHandler: @escaping () -> Void,
        using dependencies: Dependencies
    ) {
        AssertIsOnMainThread()
        handleNotificationResponse(response, using: dependencies)
            .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
            .receive(on: DispatchQueue.main, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            completionHandler()
                            owsFailDebug("error: \(error)")
                            Logger.error("error: \(error)")
                    }
                },
                receiveValue: { _ in completionHandler() }
            )
    }

    func handleNotificationResponse(
        _ response: UNNotificationResponse,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        AssertIsOnMainThread()
        assert(dependencies[singleton: .appReadiness].isAppReady)

        let userInfo: [AnyHashable: Any] = response.notification.request.content.userInfo
        let applicationState: UIApplication.State = UIApplication.shared.applicationState

        switch response.actionIdentifier {
            case UNNotificationDefaultActionIdentifier:
                Logger.debug("default action")
                return showThread(userInfo: userInfo, using: dependencies)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
                
            case UNNotificationDismissActionIdentifier:
                // TODO - mark as read?
                Logger.debug("dismissed notification")
                return Just(())
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
                
            default:
                // proceed
                break
        }

        guard let action = UserNotificationConfig.action(identifier: response.actionIdentifier) else {
            return Fail(error: NotificationError.failDebug("unable to find action for actionIdentifier: \(response.actionIdentifier)"))
                .eraseToAnyPublisher()
        }

        switch action {
            case .markAsRead: return markAsRead(userInfo: userInfo, using: dependencies)
                
            case .reply:
                guard let textInputResponse = response as? UNTextInputNotificationResponse else {
                    return Fail(error: NotificationError.failDebug("response had unexpected type: \(response)"))
                        .eraseToAnyPublisher()
                }

                return reply(
                    userInfo: userInfo,
                    replyText: textInputResponse.userText,
                    applicationState: applicationState,
                    using: dependencies
                )
                    
            case .showThread:
                return showThread(userInfo: userInfo, using: dependencies)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
        }
    }

    // MARK: - Actions

    func markAsRead(userInfo: [AnyHashable: Any], using dependencies: Dependencies) -> AnyPublisher<Void, Error> {
        guard let threadId: String = userInfo[AppNotificationUserInfoKey.threadId] as? String else {
            return Fail(error: NotificationError.failDebug("threadId was unexpectedly nil"))
                .eraseToAnyPublisher()
        }
        
        guard dependencies[singleton: .storage].read({ db in try SessionThread.exists(db, id: threadId) }) == true else {
            return Fail(error: NotificationError.failDebug("unable to find thread with id: \(threadId)"))
                .eraseToAnyPublisher()
        }

        return markAsRead(threadId: threadId, using: dependencies)
    }

    func reply(
        userInfo: [AnyHashable: Any],
        replyText: String,
        applicationState: UIApplication.State,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        guard let threadId = userInfo[AppNotificationUserInfoKey.threadId] as? String else {
            return Fail<Void, Error>(error: NotificationError.failDebug("threadId was unexpectedly nil"))
                .eraseToAnyPublisher()
        }
        
        guard let thread: SessionThread = dependencies[singleton: .storage].read({ db in try SessionThread.fetchOne(db, id: threadId) }) else {
            return Fail<Void, Error>(error: NotificationError.failDebug("unable to find thread with id: \(threadId)"))
                .eraseToAnyPublisher()
        }
        
        return dependencies[singleton: .storage]
            .writePublisher { db -> HTTP.PreparedRequest<Void> in
                let interaction: Interaction = try Interaction(
                    threadId: threadId,
                    authorId: getUserSessionId(db, using: dependencies).hexString,
                    variant: .standardOutgoing,
                    body: replyText,
                    timestampMs: SnodeAPI.currentOffsetTimestampMs(using: dependencies),
                    hasMention: Interaction.isUserMentioned(db, threadId: threadId, body: replyText)
                ).inserted(db)
                
                try Interaction.markAsRead(
                    db,
                    interactionId: interaction.id,
                    threadId: threadId,
                    threadVariant: thread.variant,
                    includingOlder: true,
                    trySendReadReceipt: try SessionThread.canSendReadReceipt(
                        db,
                        threadId: threadId,
                        threadVariant: thread.variant
                    ),
                    using: dependencies
                )
                
                return try MessageSender.preparedSend(
                    db,
                    interaction: interaction,
                    fileIds: [],
                    threadId: threadId,
                    threadVariant: thread.variant,
                    using: dependencies
                )
            }
            .flatMap { $0.send(using: dependencies) }
            .map { _ in () }
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure:
                            dependencies[singleton: .storage].read { [dependencies] db in
                                dependencies[singleton: .notificationsManager].notifyForFailedSend(
                                    db,
                                    in: thread,
                                    applicationState: applicationState
                                )
                            }
                    }
                }
            )
            .eraseToAnyPublisher()
    }

    func showThread(userInfo: [AnyHashable: Any], using dependencies: Dependencies) -> AnyPublisher<Void, Never> {
        guard
            let threadId = userInfo[AppNotificationUserInfoKey.threadId] as? String,
            let threadVariantRaw = userInfo[AppNotificationUserInfoKey.threadVariantRaw] as? Int,
            let threadVariant: SessionThread.Variant = SessionThread.Variant(rawValue: threadVariantRaw)
        else { return showHomeVC() }

        // If this happens when the the app is not, visible we skip the animation so the thread
        // can be visible to the user immediately upon opening the app, rather than having to watch
        // it animate in from the homescreen.
        SessionApp.presentConversationCreatingIfNeeded(
            for: threadId,
            variant: threadVariant,
            dismissing: nil,
            animated: (UIApplication.shared.applicationState == .active),
            using: dependencies
        )
        
        return Just(()).eraseToAnyPublisher()
    }
    
    func showHomeVC() -> AnyPublisher<Void, Never> {
        SessionApp.showHomeView()
        return Just(()).eraseToAnyPublisher()
    }
    
    private func markAsRead(
        threadId: String,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        return dependencies[singleton: .storage]
            .writePublisher { db in
                guard
                    let threadVariant: SessionThread.Variant = try SessionThread
                        .filter(id: threadId)
                        .select(.variant)
                        .asRequest(of: SessionThread.Variant.self)
                        .fetchOne(db),
                    let lastInteractionId: Int64 = try Interaction
                        .select(.id)
                        .filter(Interaction.Columns.threadId == threadId)
                        .order(Interaction.Columns.timestampMs.desc)
                        .asRequest(of: Int64.self)
                        .fetchOne(db)
                else { throw NotificationError.failDebug("unable to required thread info: \(threadId)") }

                try Interaction.markAsRead(
                    db,
                    interactionId: lastInteractionId,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    includingOlder: true,
                    trySendReadReceipt: try SessionThread.canSendReadReceipt(
                        db,
                        threadId: threadId,
                        threadVariant: threadVariant
                    ),
                    using: dependencies
                )
            }
            .eraseToAnyPublisher()
    }
}
