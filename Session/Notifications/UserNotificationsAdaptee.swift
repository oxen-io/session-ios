// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import UserNotifications
import SessionMessagingKit
import SignalCoreKit
import SignalUtilitiesKit
import SessionUtilitiesKit

class UserNotificationConfig {

    class var allNotificationCategories: Set<UNNotificationCategory> {
        let categories = AppNotificationCategory.allCases.map { notificationCategory($0) }
        return Set(categories)
    }

    class func notificationActions(for category: AppNotificationCategory) -> [UNNotificationAction] {
        return category.actions.map { notificationAction($0) }
    }

    class func notificationCategory(_ category: AppNotificationCategory) -> UNNotificationCategory {
        return UNNotificationCategory(
            identifier: category.identifier,
            actions: notificationActions(for: category),
            intentIdentifiers: [],
            options: []
        )
    }

    class func notificationAction(_ action: AppNotificationAction) -> UNNotificationAction {
        switch action {
            case .markAsRead:
                return UNNotificationAction(
                    identifier: action.identifier,
                    title: MessageStrings.markAsReadNotificationAction,
                    options: []
                )
                
            case .reply:
                return UNTextInputNotificationAction(
                    identifier: action.identifier,
                    title: MessageStrings.replyNotificationAction,
                    options: [],
                    textInputButtonTitle: MessageStrings.sendButton,
                    textInputPlaceholder: ""
                )
                
            case .showThread:
                return UNNotificationAction(
                    identifier: action.identifier,
                    title: CallStrings.showThreadButtonTitle,
                    options: [.foreground]
                )
        }
    }

    class func action(identifier: String) -> AppNotificationAction? {
        return AppNotificationAction.allCases.first { notificationAction($0).identifier == identifier }
    }
}

class UserNotificationPresenterAdaptee: NSObject, UNUserNotificationCenterDelegate {
    private let notificationCenter: UNUserNotificationCenter
    private var notifications: Atomic<[String: UNNotificationRequest]> = Atomic([:])

    override init() {
        self.notificationCenter = UNUserNotificationCenter.current()
        
        super.init()
        
        SwiftSingletons.register(self)
    }
}

extension UserNotificationPresenterAdaptee: NotificationPresenterAdaptee {
    func registerNotificationSettings() -> AnyPublisher<Void, Never> {
        return Deferred {
            Future { [weak self] resolver in
                self?.notificationCenter.requestAuthorization(options: [.badge, .sound, .alert]) { (granted, error) in
                    self?.notificationCenter.setNotificationCategories(UserNotificationConfig.allNotificationCategories)
                    
                    if granted {}
                    else if let error: Error = error {
                        Logger.error("failed with error: \(error)")
                    }
                    else {
                        Logger.error("failed without error.")
                    }
                    
                    // Note that the promise is fulfilled regardless of if notification permssions were
                    // granted. This promise only indicates that the user has responded, so we can
                    // proceed with requesting push tokens and complete registration.
                    resolver(Result.success(()))
                }
            }
        }.eraseToAnyPublisher()
    }

    func notify(
        category: AppNotificationCategory,
        title: String?,
        body: String,
        userInfo: [AnyHashable: Any],
        previewType: Preferences.NotificationPreviewType,
        sound: Preferences.Sound?,
        threadVariant: SessionThread.Variant,
        threadName: String,
        applicationState: UIApplication.State,
        replacingIdentifier: String?
    ) {
        let threadIdentifier: String? = (userInfo[AppNotificationUserInfoKey.threadId] as? String)
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = category.identifier
        content.userInfo = userInfo
        content.threadIdentifier = (threadIdentifier ?? content.threadIdentifier)
        
        let shouldGroupNotification: Bool = (
            threadVariant == .community &&
            replacingIdentifier == threadIdentifier
        )
        if let sound = sound, sound != .none {
            content.sound = sound.notificationSound(isQuiet: (applicationState == .active))
        }
        
        let notificationIdentifier: String = (replacingIdentifier ?? UUID().uuidString)
        let isReplacingNotification: Bool = (notifications.wrappedValue[notificationIdentifier] != nil)
        let shouldPresentNotification: Bool = shouldPresentNotification(
            category: category,
            applicationState: applicationState,
            frontMostViewController: SessionApp.currentlyOpenConversationViewController.wrappedValue,
            userInfo: userInfo
        )
        var trigger: UNNotificationTrigger?

        if shouldPresentNotification {
            if let displayableTitle = title?.filterForDisplay {
                content.title = displayableTitle
            }
            if let displayableBody = body.filterForDisplay {
                content.body = displayableBody
            }
            
            if shouldGroupNotification {
                trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: Notifications.delayForGroupedNotifications,
                    repeats: false
                )
                
                let numberExistingNotifications: Int? = notifications.wrappedValue[notificationIdentifier]?
                    .content
                    .userInfo[AppNotificationUserInfoKey.threadNotificationCounter]
                    .asType(Int.self)
                var numberOfNotifications: Int = (numberExistingNotifications ?? 1)
                
                if numberExistingNotifications != nil {
                    numberOfNotifications += 1  // Add one for the current notification
                    
                    content.title = (previewType == .noNameNoPreview ?
                        content.title :
                        threadName
                    )
                    content.body = String(
                        format: NotificationStrings.incomingCollapsedMessagesBody,
                        "\(numberOfNotifications)"
                    )
                }
                
                content.userInfo[AppNotificationUserInfoKey.threadNotificationCounter] = numberOfNotifications
            }
        }
        else {
            // Play sound and vibrate, but without a `body` no banner will show.
            Logger.debug("supressing notification body")
        }

        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: trigger
        )

        Logger.debug("presenting notification with identifier: \(notificationIdentifier)")
        
        if isReplacingNotification { cancelNotifications(identifiers: [notificationIdentifier]) }
        
        notificationCenter.add(request)
        notifications.mutate { $0[notificationIdentifier] = request }
    }

    func cancelNotifications(identifiers: [String]) {
        notifications.mutate { notifications in
            identifiers.forEach { notifications.removeValue(forKey: $0) }
        }
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func cancelNotification(_ notification: UNNotificationRequest) {
        cancelNotifications(identifiers: [notification.identifier])
    }

    func cancelNotifications(threadId: String) {
        let notificationsIdsToCancel: [String] = notifications.wrappedValue
            .values
            .compactMap { notification in
                guard
                    let notificationThreadId: String = notification.content.userInfo[AppNotificationUserInfoKey.threadId] as? String,
                    notificationThreadId == threadId
                else { return nil }
                
                return notification.identifier
            }
        
        cancelNotifications(identifiers: notificationsIdsToCancel)
    }

    func clearAllNotifications() {
        notificationCenter.removeAllPendingNotificationRequests()
        notificationCenter.removeAllDeliveredNotifications()
    }

    func shouldPresentNotification(
        category: AppNotificationCategory,
        applicationState: UIApplication.State,
        frontMostViewController: UIViewController?,
        userInfo: [AnyHashable: Any]
    ) -> Bool {
        guard applicationState == .active else { return true }

        guard category == .incomingMessage || category == .errorMessage else {
            return true
        }

        guard let notificationThreadId = userInfo[AppNotificationUserInfoKey.threadId] as? String else {
            owsFailDebug("threadId was unexpectedly nil")
            return true
        }
        
        guard let conversationViewController: ConversationVC = frontMostViewController as? ConversationVC else {
            return true
        }
        
        /// Show notifications for any **other** threads
        return (conversationViewController.viewModel.threadData.threadId != notificationThreadId)
    }
}

@objc(OWSUserNotificationActionHandler)
public class UserNotificationActionHandler: NSObject {

    var actionHandler: NotificationActionHandler {
        return NotificationActionHandler.shared
    }

    @objc
    func handleNotificationResponse( _ response: UNNotificationResponse, completionHandler: @escaping () -> Void) {
        AssertIsOnMainThread()
        handleNotificationResponse(response)
            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
            .receive(on: DispatchQueue.main)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            completionHandler()
                            OWSLogger.error("Failed to handle notification response: \(error)")
                    }
                },
                receiveValue: { _ in completionHandler() }
            )
    }

    func handleNotificationResponse( _ response: UNNotificationResponse) -> AnyPublisher<Void, Error> {
        AssertIsOnMainThread()
        assert(Singleton.appReadiness.isAppReady)

        let userInfo: [AnyHashable: Any] = response.notification.request.content.userInfo
        let applicationState: UIApplication.State = UIApplication.shared.applicationState

        switch response.actionIdentifier {
            case UNNotificationDefaultActionIdentifier:
                OWSLogger.debug("Notification response: default action")
                return actionHandler.showThread(userInfo: userInfo)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
                
            case UNNotificationDismissActionIdentifier:
                // TODO - mark as read?
                OWSLogger.debug("Notification response: dismissed notification")
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
            case .markAsRead:
                return actionHandler.markAsRead(userInfo: userInfo)
                
            case .reply:
                guard let textInputResponse = response as? UNTextInputNotificationResponse else {
                    return Fail(error: NotificationError.failDebug("response had unexpected type: \(response)"))
                        .eraseToAnyPublisher()
                }

                return actionHandler.reply(userInfo: userInfo, replyText: textInputResponse.userText, applicationState: applicationState)
                    
            case .showThread:
                return actionHandler.showThread(userInfo: userInfo)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
        }
    }
}
