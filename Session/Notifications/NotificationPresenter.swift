// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

// MARK: - NotificationPresenter

public class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, NotificationsManagerType {
    private static let audioNotificationsThrottleCount = 2
    private static let audioNotificationsThrottleInterval: TimeInterval = 5
    
    private let dependencies: Dependencies
    private let notificationCenter: UNUserNotificationCenter = UNUserNotificationCenter.current()
    private var notifications: Atomic<[String: UNNotificationRequest]> = Atomic([:])
    private var mostRecentNotifications: Atomic<TruncatedList<UInt64>> = Atomic(TruncatedList<UInt64>(maxLength: NotificationPresenter.audioNotificationsThrottleCount))
    
    // MARK: - Initialization
    
    required public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Registration
    
    public func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        notificationCenter.delegate = delegate
    }
    
    public func registerNotificationSettings() -> AnyPublisher<Void, Never> {
        return Deferred { [notificationCenter] in
            Future { resolver in
                notificationCenter.requestAuthorization(options: [.badge, .sound, .alert]) { (granted, error) in
                    notificationCenter.setNotificationCategories(UserNotificationConfig.allNotificationCategories)
                    
                    switch (granted, error) {
                        case (true, _): break
                        case (false, .some(let error)): Log.error("[NotificationPresenter] Register settings failed with error: \(error)")
                        case (false, .none): Log.error("[NotificationPresenter] Register settings failed without error.")
                    }
                    
                    // Note that the promise is fulfilled regardless of if notification permssions were
                    // granted. This promise only indicates that the user has responded, so we can
                    // proceed with requesting push tokens and complete registration.
                    resolver(Result.success(()))
                }
            }
        }.eraseToAnyPublisher()
    }
    
    // MARK: - Presentation
    
    public func notifyUser(
        _ db: Database,
        for interaction: Interaction,
        in thread: SessionThread,
        applicationState: UIApplication.State
    ) {
        let isMessageRequest: Bool = SessionThread.isMessageRequest(
            db,
            threadId: thread.id,
            userSessionId: dependencies[cache: .general].sessionId,
            includeNonVisible: true
        )
        
        // Ensure we should be showing a notification for the thread
        guard thread.shouldShowNotification(db, for: interaction, isMessageRequest: isMessageRequest, using: dependencies) else {
            return
        }
        
        // Try to group notifications for interactions from open groups
        let identifier: String = Interaction.notificationIdentifier(
            for: (interaction.id ?? 0),
            threadId: thread.id,
            shouldGroupMessagesForThread: (thread.variant == .community)
        )
        
        // While batch processing, some of the necessary changes have not been commited.
        let rawMessageText: String = Interaction.notificationPreviewText(db, interaction: interaction, using: dependencies)
        
        // iOS strips anything that looks like a printf formatting character from
        // the notification body, so if we want to dispay a literal "%" in a notification
        // it must be escaped.
        // see https://developer.apple.com/documentation/uikit/uilocalnotification/1616646-alertbody
        // for more details.
        let messageText: String? = String.filterNotificationText(rawMessageText)
        let notificationTitle: String?
        var notificationBody: String?
        
        let senderName = Profile.displayName(db, id: interaction.authorId, threadVariant: thread.variant, using: dependencies)
        let previewType: Preferences.NotificationPreviewType = db[.preferencesNotificationPreviewType]
            .defaulting(to: .defaultPreviewType)
        let groupName: String = SessionThread.displayName(
            threadId: thread.id,
            variant: thread.variant,
            closedGroupName: try? thread.closedGroup
                .select(.name)
                .asRequest(of: String.self)
                .fetchOne(db),
            openGroupName: try? thread.openGroup
                .select(.name)
                .asRequest(of: String.self)
                .fetchOne(db)
        )
        
        switch previewType {
            case .noNameNoPreview:
                notificationTitle = Constants.app_name
                
            case .nameNoPreview, .nameAndPreview:
                switch (thread.variant, isMessageRequest) {
                    case (.contact, true), (.group, true): notificationTitle = Constants.app_name
                    case (.contact, false): notificationTitle = senderName
                        
                    case (.legacyGroup, _), (.group, false), (.community, _):
                        notificationTitle = "notificationsIosGroup"
                            .put(key: "name", value: senderName)
                            .put(key: "conversation_name", value: groupName)
                            .localized()
                }
        }
        
        switch previewType {
            case .noNameNoPreview, .nameNoPreview: notificationBody = "messageNewYouveGot"
                .putNumber(1)
                .localized()
            case .nameAndPreview: notificationBody = messageText
        }
        
        // If it's a message request then overwrite the body to be something generic (only show a notification
        // when receiving a new message request if there aren't any others or the user had hidden them)
        if isMessageRequest {
            notificationBody = "messageRequestsNew".localized()
        }
        
        guard notificationBody != nil || notificationTitle != nil else {
            SNLog("AppNotifications error: No notification content")
            return
        }
        
        // Don't reply from lockscreen if anyone in this conversation is
        // "no longer verified".
        let category = AppNotificationCategory.incomingMessage
        
        let userInfo: [AnyHashable: Any] = [
            AppNotificationUserInfoKey.threadId: thread.id,
            AppNotificationUserInfoKey.threadVariantRaw: thread.variant.rawValue
        ]
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let userBlinded15SessionId: SessionId? = SessionThread.getCurrentUserBlindedSessionId(
            db,
            threadId: thread.id,
            threadVariant: thread.variant,
            blindingPrefix: .blinded15,
            using: dependencies
        )
        let userBlinded25SessionId: SessionId? = SessionThread.getCurrentUserBlindedSessionId(
            db,
            threadId: thread.id,
            threadVariant: thread.variant,
            blindingPrefix: .blinded25,
            using: dependencies
        )
        let fallbackSound: Preferences.Sound = db[.defaultNotificationSound]
            .defaulting(to: Preferences.Sound.defaultNotificationSound)
        
        let sound: Preferences.Sound? = requestSound(
            thread: thread,
            fallbackSound: fallbackSound,
            applicationState: applicationState
        )
        
        notificationBody = MentionUtilities.highlightMentionsNoAttributes(
            in: (notificationBody ?? ""),
            threadVariant: thread.variant,
            currentUserSessionId: userSessionId.hexString,
            currentUserBlinded15SessionId: userBlinded15SessionId?.hexString,
            currentUserBlinded25SessionId: userBlinded25SessionId?.hexString,
            using: dependencies
        )
        
        notify(
            category: category,
            title: notificationTitle,
            body: (notificationBody ?? ""),
            userInfo: userInfo,
            previewType: previewType,
            sound: sound,
            threadVariant: thread.variant,
            threadName: groupName,
            applicationState: applicationState,
            replacingIdentifier: identifier
        )
    }
    
    public func notifyUser(
        _ db: Database,
        forIncomingCall interaction: Interaction,
        in thread: SessionThread,
        applicationState: UIApplication.State
    ) {
        // No call notifications for muted or group threads
        guard Date().timeIntervalSince1970 > (thread.mutedUntilTimestamp ?? 0) else { return }
        guard
            thread.variant != .legacyGroup &&
                thread.variant != .group &&
                thread.variant != .community
        else { return }
        guard
            interaction.variant == .infoCall,
            let infoMessageData: Data = (interaction.body ?? "").data(using: .utf8),
            let messageInfo: CallMessage.MessageInfo = try? JSONDecoder().decode(
                CallMessage.MessageInfo.self,
                from: infoMessageData
            )
        else { return }
        
        // Only notify missed calls
        switch messageInfo.state {
            case .missed, .permissionDenied, .permissionDeniedMicrophone: break
            default: return
        }
        
        let category = AppNotificationCategory.errorMessage
        let previewType: Preferences.NotificationPreviewType = db[.preferencesNotificationPreviewType]
            .defaulting(to: .nameAndPreview)
        
        let userInfo: [AnyHashable: Any] = [
            AppNotificationUserInfoKey.threadId: thread.id,
            AppNotificationUserInfoKey.threadVariantRaw: thread.variant.rawValue
        ]
        
        let notificationTitle: String = Constants.app_name
        let senderName: String = Profile.displayName(db, id: interaction.authorId, threadVariant: thread.variant, using: dependencies)
        let notificationBody: String? = {
            switch messageInfo.state {
                case .permissionDenied:
                    return "callsYouMissedCallPermissions"
                        .put(key: "name", value: senderName)
                        .localizedDeformatted()
                case .permissionDeniedMicrophone, .missed:
                    return "callsMissedCallFrom"
                        .put(key: "name", value: senderName)
                        .localized()
                default:
                    return nil
            }
        }()
        
        let fallbackSound: Preferences.Sound = db[.defaultNotificationSound]
            .defaulting(to: Preferences.Sound.defaultNotificationSound)
        let sound = self.requestSound(
            thread: thread,
            fallbackSound: fallbackSound,
            applicationState: applicationState
        )
        
        notify(
            category: category,
            title: notificationTitle,
            body: (notificationBody ?? ""),
            userInfo: userInfo,
            previewType: previewType,
            sound: sound,
            threadVariant: thread.variant,
            threadName: senderName,
            applicationState: applicationState,
            replacingIdentifier: UUID().uuidString
        )
    }
    
    public func notifyUser(
        _ db: Database,
        forReaction reaction: Reaction,
        in thread: SessionThread,
        applicationState: UIApplication.State
    ) {
        let isMessageRequest: Bool = SessionThread.isMessageRequest(
            db,
            threadId: thread.id,
            userSessionId: dependencies[cache: .general].sessionId,
            includeNonVisible: true
        )
        
        // No reaction notifications for muted, group threads or message requests
        guard dependencies.dateNow.timeIntervalSince1970 > (thread.mutedUntilTimestamp ?? 0) else { return }
        guard
            thread.variant != .legacyGroup &&
                thread.variant != .group &&
                thread.variant != .community
        else { return }
        guard !isMessageRequest else { return }
        
        let notificationTitle = Profile.displayName(db, id: reaction.authorId, threadVariant: thread.variant, using: dependencies)
        var notificationBody = "emojiReactsNotification"
            .put(key: "emoji", value: reaction.emoji)
            .localized()
        
        // Title & body
        let previewType: Preferences.NotificationPreviewType = db[.preferencesNotificationPreviewType]
            .defaulting(to: .nameAndPreview)
        
        switch previewType {
            case .nameAndPreview: break
            default: notificationBody = "messageNewYouveGot"
                .putNumber(1)
                .localized()
        }
        
        let category = AppNotificationCategory.incomingMessage
        
        let userInfo: [AnyHashable: Any] = [
            AppNotificationUserInfoKey.threadId: thread.id,
            AppNotificationUserInfoKey.threadVariantRaw: thread.variant.rawValue
        ]
        
        let threadName: String = SessionThread.displayName(
            threadId: thread.id,
            variant: thread.variant,
            closedGroupName: nil,       // Not supported
            openGroupName: nil          // Not supported
        )
        let fallbackSound: Preferences.Sound = db[.defaultNotificationSound]
            .defaulting(to: Preferences.Sound.defaultNotificationSound)
        let sound = self.requestSound(
            thread: thread,
            fallbackSound: fallbackSound,
            applicationState: applicationState
        )
        
        notify(
            category: category,
            title: notificationTitle,
            body: notificationBody,
            userInfo: userInfo,
            previewType: previewType,
            sound: sound,
            threadVariant: thread.variant,
            threadName: threadName,
            applicationState: applicationState,
            replacingIdentifier: UUID().uuidString
        )
    }
    
    public func notifyForFailedSend(
        _ db: Database,
        in thread: SessionThread,
        applicationState: UIApplication.State
    ) {
        let notificationTitle: String?
        let previewType: Preferences.NotificationPreviewType = db[.preferencesNotificationPreviewType]
            .defaulting(to: .defaultPreviewType)
        let threadName: String = SessionThread.displayName(
            threadId: thread.id,
            variant: thread.variant,
            closedGroupName: try? thread.closedGroup
                .select(.name)
                .asRequest(of: String.self)
                .fetchOne(db),
            openGroupName: try? thread.openGroup
                .select(.name)
                .asRequest(of: String.self)
                .fetchOne(db),
            isNoteToSelf: (thread.isNoteToSelf(db, using: dependencies) == true),
            profile: try? Profile.fetchOne(db, id: thread.id)
        )
        
        switch previewType {
            case .noNameNoPreview: notificationTitle = nil
            case .nameNoPreview, .nameAndPreview: notificationTitle = threadName
        }

        let notificationBody = "messageErrorDelivery".localized()
        let userInfo: [AnyHashable: Any] = [
            AppNotificationUserInfoKey.threadId: thread.id,
            AppNotificationUserInfoKey.threadVariantRaw: thread.variant.rawValue
        ]
        let fallbackSound: Preferences.Sound = db[.defaultNotificationSound]
            .defaulting(to: Preferences.Sound.defaultNotificationSound)
        let sound: Preferences.Sound? = self.requestSound(
            thread: thread,
            fallbackSound: fallbackSound,
            applicationState: applicationState
        )
        
        notify(
            category: .errorMessage,
            title: notificationTitle,
            body: notificationBody,
            userInfo: userInfo,
            previewType: previewType,
            sound: sound,
            threadVariant: thread.variant,
            threadName: threadName,
            applicationState: applicationState
        )
    }
    
    // MARK: - Clearing
    
    public func cancelNotifications(identifiers: [String]) {
        notifications.mutate { notifications in
            identifiers.forEach { notifications.removeValue(forKey: $0) }
        }
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    
    public func clearAllNotifications() {
        notificationCenter.removeAllPendingNotificationRequests()
        notificationCenter.removeAllDeliveredNotifications()
    }
}
 
// MARK: - Convenience

private extension NotificationPresenter {
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
        replacingIdentifier: String? = nil
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
            userInfo: userInfo,
            using: dependencies
        )
        var trigger: UNNotificationTrigger?

        if shouldPresentNotification {
            if let displayableTitle = title?.filteredForDisplay {
                content.title = displayableTitle
            }
            content.body = body.filteredForDisplay
            
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
                    content.body = "messageNewYouveGot"
                        .putNumber(numberOfNotifications)
                        .localized()
                }
                
                content.userInfo[AppNotificationUserInfoKey.threadNotificationCounter] = numberOfNotifications
            }
        }
        else {
            // Play sound and vibrate, but without a `body` no banner will show.
            Log.debug("supressing notification body")
        }

        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: trigger
        )

        Log.debug("presenting notification with identifier: \(notificationIdentifier)")
        
        if isReplacingNotification { cancelNotifications(identifiers: [notificationIdentifier]) }
        
        notificationCenter.add(request)
        notifications.mutate { $0[notificationIdentifier] = request }
    }
    
    private func requestSound(
        thread: SessionThread,
        fallbackSound: Preferences.Sound,
        applicationState: UIApplication.State
    ) -> Preferences.Sound? {
        guard checkIfShouldPlaySound(applicationState: applicationState) else { return nil }
        
        return (thread.notificationSound ?? fallbackSound)
    }
    
    private func shouldPresentNotification(
        category: AppNotificationCategory,
        applicationState: UIApplication.State,
        userInfo: [AnyHashable: Any],
        using dependencies: Dependencies
    ) -> Bool {
        guard applicationState == .active else { return true }
        guard category == .incomingMessage || category == .errorMessage else { return true }

        guard let notificationThreadId = userInfo[AppNotificationUserInfoKey.threadId] as? String else {
            Log.error("[UserNotificationPresenterAdaptee] threadId was unexpectedly nil")
            return true
        }
        
        /// Check whether the current `frontMostViewController` is a `ConversationVC` for the conversation this notification
        /// would belong to then we don't want to show the notification, so retrieve the `frontMostViewController` (from the main
        /// thread) and check
        guard
            let frontMostViewController: UIViewController = DispatchQueue.main.sync(execute: {
                dependencies[singleton: .appContext].frontMostViewController
            }),
            let conversationViewController: ConversationVC = frontMostViewController as? ConversationVC
        else { return true }
        
        /// Show notifications for any **other** threads
        return (conversationViewController.viewModel.threadData.threadId != notificationThreadId)
    }

    private func checkIfShouldPlaySound(applicationState: UIApplication.State) -> Bool {
        guard applicationState == .active else { return true }
        guard dependencies[singleton: .storage, key: .playNotificationSoundInForeground] else { return false }

        let nowMs: UInt64 = UInt64(floor(Date().timeIntervalSince1970 * 1000))
        let recentThreshold = nowMs - UInt64(NotificationPresenter.audioNotificationsThrottleInterval * 1000)

        let recentNotifications = mostRecentNotifications.wrappedValue.filter { $0 > recentThreshold }

        guard recentNotifications.count < NotificationPresenter.audioNotificationsThrottleCount else { return false }

        mostRecentNotifications.mutate { $0.append(nowMs) }
        return true
    }
}

enum NotificationError: Error {
    case assertionError(description: String)
}

extension NotificationError {
    static func failDebug(_ description: String) -> NotificationError {
        Log.error("[NotificationActionHandler] Failed with error: \(description)")
        return NotificationError.assertionError(description: description)
    }
}

// MARK: - TruncatedList

struct TruncatedList<Element> {
    let maxLength: Int
    private var contents: [Element] = []

    init(maxLength: Int) {
        self.maxLength = maxLength
    }

    mutating func append(_ newElement: Element) {
        var newElements = self.contents
        newElements.append(newElement)
        self.contents = Array(newElements.suffix(maxLength))
    }
}

extension TruncatedList: Collection {
    typealias Index = Int

    var startIndex: Index {
        return contents.startIndex
    }

    var endIndex: Index {
        return contents.endIndex
    }

    subscript (position: Index) -> Element {
        return contents[position]
    }

    func index(after i: Index) -> Index {
        return contents.index(after: i)
    }
}
