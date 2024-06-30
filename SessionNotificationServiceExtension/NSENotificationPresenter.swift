// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import UserNotifications
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

public class NSENotificationPresenter: NSObject, NotificationsProtocol {
    private var notifications: [String: UNNotificationRequest] = [:]
     
    public func notifyUser(_ db: Database, for interaction: Interaction, in thread: SessionThread, applicationState: UIApplication.State) {
        let isMessageRequest: Bool = thread.isMessageRequest(db, includeNonVisible: true)
        
        // Ensure we should be showing a notification for the thread
        guard thread.shouldShowNotification(db, for: interaction, isMessageRequest: isMessageRequest) else {
            return
        }
        
        let senderName: String = Profile.displayName(db, id: interaction.authorId, threadVariant: thread.variant)
        let groupName: String = SessionThread.displayName(
            threadId: thread.id,
            variant: thread.variant,
            closedGroupName: (try? thread.closedGroup.fetchOne(db))?.name,
            openGroupName: (try? thread.openGroup.fetchOne(db))?.name
        )
        var notificationTitle: String = senderName
        
        if thread.variant == .legacyGroup || thread.variant == .group || thread.variant == .community {
            if thread.onlyNotifyForMentions && !interaction.hasMention {
                // Ignore PNs if the group is set to only notify for mentions
                return
            }
            
            notificationTitle = "notificationsIosGroup"
                .put(key: "name", value: senderName)
                .put(key: "conversation_name", value: groupName)
                .localized()
        }
        
        let snippet: String = (interaction.previewText(db)
            .filterForDisplay?
            .replacingMentions(for: thread.id))
            .defaulting(to: "messageNewYouveGotA".localized())
        
        let userInfo: [String: Any] = [
            NotificationServiceExtension.isFromRemoteKey: true,
            NotificationServiceExtension.threadIdKey: thread.id,
            NotificationServiceExtension.threadVariantRaw: thread.variant.rawValue
        ]
        
        let notificationContent = UNMutableNotificationContent()
        notificationContent.userInfo = userInfo
        notificationContent.sound = thread.notificationSound
            .defaulting(to: db[.defaultNotificationSound] ?? Preferences.Sound.defaultNotificationSound)
            .notificationSound(isQuiet: false)
        notificationContent.badge = (try? Interaction.fetchUnreadCount(db))
            .map { NSNumber(value: $0) }
            .defaulting(to: NSNumber(value: 0))
        
        // Title & body
        let previewType: Preferences.NotificationPreviewType = db[.preferencesNotificationPreviewType]
            .defaulting(to: .defaultPreviewType)
        
        switch previewType {
            case .nameAndPreview:
                notificationContent.title = notificationTitle
                notificationContent.body = snippet
        
            case .nameNoPreview:
                notificationContent.title = notificationTitle
                notificationContent.body = "messageNewYouveGotA".localized()
                
            case .noNameNoPreview:
                notificationContent.title = Singleton.appName
                notificationContent.body = "messageNewYouveGotA".localized()
        }
        
        // If it's a message request then overwrite the body to be something generic (only show a notification
        // when receiving a new message request if there aren't any others or the user had hidden them)
        if isMessageRequest {
            notificationContent.title = Singleton.appName
            notificationContent.body = "messageRequestsNew".localized()
        }
        
        // Add request (try to group notifications for interactions from open groups)
        let identifier: String = interaction.notificationIdentifier(
            shouldGroupMessagesForThread: (thread.variant == .community)
        )
        var trigger: UNNotificationTrigger?
        
        if thread.variant == .community {
            trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: Notifications.delayForGroupedNotifications,
                repeats: false
            )
            
            let numberExistingNotifications: Int? = notifications[identifier]?
                .content
                .userInfo[NotificationServiceExtension.threadNotificationCounter]
                .asType(Int.self)
            var numberOfNotifications: Int = (numberExistingNotifications ?? 1)
            
            if numberExistingNotifications != nil {
                numberOfNotifications += 1  // Add one for the current notification
                
                notificationContent.title = (previewType == .noNameNoPreview ?
                    notificationContent.title :
                    groupName
                )
                notificationContent.body = "messageNewYouveGotMany"
                    .put(key: "count", value: numberOfNotifications)
                    .localized()
            }
            
            notificationContent.userInfo[NotificationServiceExtension.threadNotificationCounter] = numberOfNotifications
        }
        
        addNotifcationRequest(
            identifier: identifier,
            notificationContent: notificationContent,
            trigger: trigger
        )
    }
    
    public func notifyUser(_ db: Database, forIncomingCall interaction: Interaction, in thread: SessionThread, applicationState: UIApplication.State) {
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
        
        let userInfo: [String: Any] = [
            NotificationServiceExtension.isFromRemoteKey: true,
            NotificationServiceExtension.threadIdKey: thread.id,
            NotificationServiceExtension.threadVariantRaw: thread.variant.rawValue
        ]
        
        let notificationContent = UNMutableNotificationContent()
        notificationContent.userInfo = userInfo
        notificationContent.sound = thread.notificationSound
            .defaulting(to: db[.defaultNotificationSound] ?? Preferences.Sound.defaultNotificationSound)
            .notificationSound(isQuiet: false)
        notificationContent.badge = (try? Interaction.fetchUnreadCount(db))
            .map { NSNumber(value: $0) }
            .defaulting(to: NSNumber(value: 0))
        
        notificationContent.title = Singleton.appName
        notificationContent.body = ""
        
        let senderName: String = Profile.displayName(db, id: interaction.authorId, threadVariant: thread.variant)
        
        if messageInfo.state == .permissionDenied {
            notificationContent.body = "callsYouMissedCallPermissions"
                .put(key: "name", value: senderName)
                .localizedDeformatted()
        }
        
        addNotifcationRequest(
            identifier: UUID().uuidString,
            notificationContent: notificationContent,
            trigger: nil
        )
    }
    
    public func notifyUser(_ db: Database, forReaction reaction: Reaction, in thread: SessionThread, applicationState: UIApplication.State) {
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
        let notificationTitle = Singleton.appName
        var notificationBody = "emojiReactsHoverName"
            .put(key: "name", value: senderName)
            .put(key: "emoji", value: reaction.emoji)
            .localized()
        
        // Title & body
        let previewType: Preferences.NotificationPreviewType = db[.preferencesNotificationPreviewType]
            .defaulting(to: .nameAndPreview)
        
        switch previewType {
            case .nameAndPreview: break
            default: notificationBody = "messageNewYouveGotA".localized()
        }

        let userInfo: [String: Any] = [
            NotificationServiceExtension.isFromRemoteKey: true,
            NotificationServiceExtension.threadIdKey: thread.id,
            NotificationServiceExtension.threadVariantRaw: thread.variant.rawValue
        ]
        
        let notificationContent = UNMutableNotificationContent()
        notificationContent.userInfo = userInfo
        notificationContent.sound = thread.notificationSound
            .defaulting(to: db[.defaultNotificationSound] ?? Preferences.Sound.defaultNotificationSound)
            .notificationSound(isQuiet: false)
        notificationContent.title = notificationTitle
        notificationContent.body = notificationBody
        
        addNotifcationRequest(identifier: UUID().uuidString, notificationContent: notificationContent, trigger: nil)
    }
    
    public func cancelNotifications(identifiers: [String]) {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    
    public func clearAllNotifications() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeAllPendingNotificationRequests()
        notificationCenter.removeAllDeliveredNotifications()
    }
    
    private func addNotifcationRequest(identifier: String, notificationContent: UNNotificationContent, trigger: UNNotificationTrigger?) {
        let request = UNNotificationRequest(identifier: identifier, content: notificationContent, trigger: trigger)
        
        SNLog("Add remote notification request: \(identifier)")
        let semaphore = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                SNLog("Failed to add notification request '\(identifier)' due to error: \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        SNLog("Finish adding remote notification request '\(identifier)")
    }
}

private extension String {
    
    func replacingMentions(for threadID: String) -> String {
        var result = self
        let regex = try! NSRegularExpression(pattern: "@[0-9a-fA-F]{66}", options: [])
        var mentions: [(range: NSRange, publicKey: String)] = []
        var m0 = regex.firstMatch(in: result, options: .withoutAnchoringBounds, range: NSRange(location: 0, length: result.utf16.count))
        while let m1 = m0 {
            let publicKey = String((result as NSString).substring(with: m1.range).dropFirst()) // Drop the @
            var matchEnd = m1.range.location + m1.range.length
            
            if let displayName: String = Profile.displayNameNoFallback(id: publicKey) {
                result = (result as NSString).replacingCharacters(in: m1.range, with: "@\(displayName)") // stringlint:disable
                mentions.append((range: NSRange(location: m1.range.location, length: displayName.utf16.count + 1), publicKey: publicKey)) // + 1 to include the @
                matchEnd = m1.range.location + displayName.utf16.count
            }
            m0 = regex.firstMatch(in: result, options: .withoutAnchoringBounds, range: NSRange(location: matchEnd, length: result.utf16.count - matchEnd))
        }
        return result
    }
}

