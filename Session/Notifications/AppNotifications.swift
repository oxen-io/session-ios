// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit
import SessionSnodeKit

/// There are two primary components in our system notification integration:
///
///     1. The `NotificationPresenter` shows system notifications to the user.
///     2. The `NotificationActionHandler` handles the users interactions with these
///        notifications.
///
/// The NotificationPresenter is driven by the adapter pattern to provide a unified interface to
/// presenting notifications on iOS9, which uses UINotifications vs iOS10+ which supports
/// UNUserNotifications.
///
/// The `NotificationActionHandler`s also need slightly different integrations for UINotifications
/// vs. UNUserNotifications, but because they are integrated at separate system defined callbacks,
/// there is no need for an Adapter, and instead the appropriate NotificationActionHandler is
/// wired directly into the appropriate callback point.

let kAudioNotificationsThrottleCount = 2
let kAudioNotificationsThrottleInterval: TimeInterval = 5

protocol NotificationPresenterAdaptee: AnyObject {

    func registerNotificationSettings() -> AnyPublisher<Void, Never>

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
    )

    func cancelNotifications(threadId: String)
    func cancelNotifications(identifiers: [String])
    func clearAllNotifications()
}

extension NotificationPresenterAdaptee {
    func notify(
        category: AppNotificationCategory,
        title: String?,
        body: String,
        userInfo: [AnyHashable: Any],
        previewType: Preferences.NotificationPreviewType,
        sound: Preferences.Sound?,
        threadVariant: SessionThread.Variant,
        threadName: String,
        applicationState: UIApplication.State
    ) {
        notify(
            category: category,
            title: title,
            body: body,
            userInfo: userInfo,
            previewType: previewType,
            sound: sound,
            threadVariant: threadVariant,
            threadName: threadName,
            applicationState: applicationState,
            replacingIdentifier: nil
        )
    }
}

public class NotificationPresenter: NotificationsProtocol {
    private let adaptee: NotificationPresenterAdaptee = UserNotificationPresenterAdaptee()

    public init() {
        SwiftSingletons.register(self)
    }

    // MARK: - Presenting Notifications

    func registerNotificationSettings() -> AnyPublisher<Void, Never> {
        return adaptee.registerNotificationSettings()
    }

    public func notifyUser(
        _ db: Database,
        for interaction: Interaction,
        in thread: SessionThread,
        applicationState: UIApplication.State
    ) {
        let isMessageRequest: Bool = thread.isMessageRequest(db, includeNonVisible: true)
        
        // Ensure we should be showing a notification for the thread
        guard thread.shouldShowNotification(db, for: interaction, isMessageRequest: isMessageRequest) else {
            return
        }
        
        // Try to group notifications for interactions from open groups
        let identifier: String = interaction.notificationIdentifier(
            shouldGroupMessagesForThread: (thread.variant == .community)
        )

        // While batch processing, some of the necessary changes have not been commited.
        let rawMessageText = interaction.previewText(db)

        // iOS strips anything that looks like a printf formatting character from
        // the notification body, so if we want to dispay a literal "%" in a notification
        // it must be escaped.
        // see https://developer.apple.com/documentation/uikit/uilocalnotification/1616646-alertbody
        // for more details.
        let messageText: String? = String.filterNotificationText(rawMessageText)
        let notificationTitle: String?
        var notificationBody: String?
        
        let senderName = Profile.displayName(db, id: interaction.authorId, threadVariant: thread.variant)
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
                notificationTitle = "Session"
                
            case .nameNoPreview, .nameAndPreview:
                switch thread.variant {
                    case .contact:
                        notificationTitle = (isMessageRequest ? "Session" : senderName)
                        
                    case .legacyGroup, .group, .community:
                        notificationTitle = String(
                            format: NotificationStrings.incomingGroupMessageTitleFormat,
                            senderName,
                            groupName
                        )
                }
        }
        
        switch previewType {
            case .noNameNoPreview, .nameNoPreview: notificationBody = NotificationStrings.incomingMessageBody
            case .nameAndPreview: notificationBody = messageText
        }
        
        // If it's a message request then overwrite the body to be something generic (only show a notification
        // when receiving a new message request if there aren't any others or the user had hidden them)
        if isMessageRequest {
            notificationBody = "MESSAGE_REQUESTS_NOTIFICATION".localized()
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
        
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let userBlinded15Key: String? = SessionThread.getUserHexEncodedBlindedKey(
            db,
            threadId: thread.id,
            threadVariant: thread.variant,
            blindingPrefix: .blinded15
        )
        let userBlinded25Key: String? = SessionThread.getUserHexEncodedBlindedKey(
            db,
            threadId: thread.id,
            threadVariant: thread.variant,
            blindingPrefix: .blinded25
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
            currentUserPublicKey: userPublicKey,
            currentUserBlinded15PublicKey: userBlinded15Key,
            currentUserBlinded25PublicKey: userBlinded25Key
        )
        
        self.adaptee.notify(
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
        guard messageInfo.state == .missed || messageInfo.state == .permissionDenied else { return }
        
        let category = AppNotificationCategory.errorMessage
        let previewType: Preferences.NotificationPreviewType = db[.preferencesNotificationPreviewType]
            .defaulting(to: .nameAndPreview)
        
        let userInfo: [AnyHashable: Any] = [
            AppNotificationUserInfoKey.threadId: thread.id,
            AppNotificationUserInfoKey.threadVariantRaw: thread.variant.rawValue
        ]
        
        let notificationTitle: String = "Session"
        let senderName: String = Profile.displayName(db, id: interaction.authorId, threadVariant: thread.variant)
        let notificationBody: String? = {
            switch messageInfo.state {
                case .permissionDenied:
                    return String(
                        format: "modal_call_missed_tips_explanation".localized(),
                        senderName
                    )
                case .missed:
                    return String(
                        format: "call_missed".localized(),
                        senderName
                    )
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
        
        self.adaptee.notify(
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
        let isMessageRequest: Bool = thread.isMessageRequest(db, includeNonVisible: true)
        
        // No reaction notifications for muted, group threads or message requests
        guard Date().timeIntervalSince1970 > (thread.mutedUntilTimestamp ?? 0) else { return }
        guard
            thread.variant != .legacyGroup &&
            thread.variant != .group &&
            thread.variant != .community
        else { return }
        guard !isMessageRequest else { return }
        
        let senderName: String = Profile.displayName(db, id: reaction.authorId, threadVariant: thread.variant)
        let notificationTitle = "Session"
        var notificationBody = String(format: "EMOJI_REACTS_NOTIFICATION".localized(), senderName, reaction.emoji)
        
        // Title & body
        let previewType: Preferences.NotificationPreviewType = db[.preferencesNotificationPreviewType]
            .defaulting(to: .nameAndPreview)
        
        switch previewType {
            case .nameAndPreview: break
            default: notificationBody = NotificationStrings.incomingMessageBody
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
        
        self.adaptee.notify(
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
            isNoteToSelf: (thread.isNoteToSelf(db) == true),
            profile: try? Profile.fetchOne(db, id: thread.id)
        )
        
        switch previewType {
            case .noNameNoPreview: notificationTitle = nil
            case .nameNoPreview, .nameAndPreview: notificationTitle = threadName
        }

        let notificationBody = NotificationStrings.failedToSendBody

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
        
        self.adaptee.notify(
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
    
    @objc
    public func cancelNotifications(identifiers: [String]) {
        DispatchQueue.main.async {
            self.adaptee.cancelNotifications(identifiers: identifiers)
        }
    }

    @objc
    public func cancelNotifications(threadId: String) {
        self.adaptee.cancelNotifications(threadId: threadId)
    }

    @objc
    public func clearAllNotifications() {
        adaptee.clearAllNotifications()
    }

    // MARK: -

    var mostRecentNotifications: Atomic<TruncatedList<UInt64>> = Atomic(TruncatedList<UInt64>(maxLength: kAudioNotificationsThrottleCount))

    private func requestSound(
        thread: SessionThread,
        fallbackSound: Preferences.Sound,
        applicationState: UIApplication.State
    ) -> Preferences.Sound? {
        guard checkIfShouldPlaySound(applicationState: applicationState) else { return nil }
        
        return (thread.notificationSound ?? fallbackSound)
    }

    private func checkIfShouldPlaySound(applicationState: UIApplication.State) -> Bool {
        guard applicationState == .active else { return true }
        guard Storage.shared[.playNotificationSoundInForeground] else { return false }

        let nowMs: UInt64 = UInt64(floor(Date().timeIntervalSince1970 * 1000))
        let recentThreshold = nowMs - UInt64(kAudioNotificationsThrottleInterval * 1000)

        let recentNotifications = mostRecentNotifications.wrappedValue.filter { $0 > recentThreshold }

        guard recentNotifications.count < kAudioNotificationsThrottleCount else { return false }

        mostRecentNotifications.mutate { $0.append(nowMs) }
        return true
    }
}

class NotificationActionHandler {

    static let shared: NotificationActionHandler = NotificationActionHandler()

    // MARK: - Dependencies

    var notificationPresenter: NotificationPresenter {
        return AppEnvironment.shared.notificationPresenter
    }

    // MARK: -

    func markAsRead(userInfo: [AnyHashable: Any]) -> AnyPublisher<Void, Error> {
        guard let threadId: String = userInfo[AppNotificationUserInfoKey.threadId] as? String else {
            return Fail(error: NotificationError.failDebug("threadId was unexpectedly nil"))
                .eraseToAnyPublisher()
        }
        
        guard Storage.shared.read({ db in try SessionThread.exists(db, id: threadId) }) == true else {
            return Fail(error: NotificationError.failDebug("unable to find thread with id: \(threadId)"))
                .eraseToAnyPublisher()
        }

        return markAsRead(threadId: threadId)
    }

    func reply(
        userInfo: [AnyHashable: Any],
        replyText: String,
        applicationState: UIApplication.State,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        guard let threadId = userInfo[AppNotificationUserInfoKey.threadId] as? String else {
            return Fail<Void, Error>(error: NotificationError.failDebug("threadId was unexpectedly nil"))
                .eraseToAnyPublisher()
        }
        
        guard let thread: SessionThread = Storage.shared.read({ db in try SessionThread.fetchOne(db, id: threadId) }) else {
            return Fail<Void, Error>(error: NotificationError.failDebug("unable to find thread with id: \(threadId)"))
                .eraseToAnyPublisher()
        }
        
        return Storage.shared
            .writePublisher { db in
                let interaction: Interaction = try Interaction(
                    threadId: threadId,
                    threadVariant: thread.variant,
                    authorId: getUserHexEncodedPublicKey(db),
                    variant: .standardOutgoing,
                    body: replyText,
                    timestampMs: SnodeAPI.currentOffsetTimestampMs(),
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
                    )
                )
                
                return try MessageSender.preparedSendData(
                    db,
                    interaction: interaction,
                    threadId: threadId,
                    threadVariant: thread.variant,
                    using: dependencies
                )
            }
            .flatMap { MessageSender.sendImmediate(data: $0, using: dependencies) }
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure:
                            Storage.shared.read { [weak self] db in
                                self?.notificationPresenter.notifyForFailedSend(
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
        else { return showHomeVC(using: dependencies) }

        // If this happens when the the app is not, visible we skip the animation so the thread
        // can be visible to the user immediately upon opening the app, rather than having to watch
        // it animate in from the homescreen.
        SessionApp.presentConversationCreatingIfNeeded(
            for: threadId,
            variant: threadVariant,
            dismissing: nil,
            animated: (UIApplication.shared.applicationState == .active)
        )
        
        return Just(())
            .eraseToAnyPublisher()
    }
    
    func showHomeVC(using dependencies: Dependencies) -> AnyPublisher<Void, Never> {
        SessionApp.showHomeView(using: dependencies)
        return Just(())
            .eraseToAnyPublisher()
    }
    
    private func markAsRead(threadId: String) -> AnyPublisher<Void, Error> {
        return Storage.shared
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
                    )
                )
            }
            .eraseToAnyPublisher()
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
