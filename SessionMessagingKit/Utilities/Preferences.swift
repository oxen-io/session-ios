// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

// stringlint:ignore_contents
public extension Setting.EnumKey {
    /// Controls how notifications should appear for the user (See `NotificationPreviewType` for the options)
    static let preferencesNotificationPreviewType: Setting.EnumKey = "preferencesNotificationPreviewType"
    
    /// Controls what the default sound for notifications is (See `Sound` for the options)
    static let defaultNotificationSound: Setting.EnumKey = "defaultNotificationSound"
}

// stringlint:ignore_contents
public extension Setting.BoolKey {
    /// Controls whether typing indicators are enabled
    ///
    /// **Note:** Only works if both participants in a "contact" thread have this setting enabled
    static let areReadReceiptsEnabled: Setting.BoolKey = "areReadReceiptsEnabled"
    
    /// Controls whether typing indicators are enabled
    ///
    /// **Note:** Only works if both participants in a "contact" thread have this setting enabled
    static let typingIndicatorsEnabled: Setting.BoolKey = "typingIndicatorsEnabled"
    
    /// Controls whether the device will automatically lock the screen
    static let isScreenLockEnabled: Setting.BoolKey = "isScreenLockEnabled"
    
    /// Controls whether Link Previews (image & title URL metadata) will be downloaded when the user enters a URL
    ///
    /// **Note:** Link Previews are only enabled for HTTPS urls
    static let areLinkPreviewsEnabled: Setting.BoolKey = "areLinkPreviewsEnabled"
    
    /// Controls whether Giphy search is enabled
    ///
    /// **Note:** Link Previews are only enabled for HTTPS urls
    static let isGiphyEnabled: Setting.BoolKey = "isGiphyEnabled"
    
    /// Controls whether Calls are enabled
    static let areCallsEnabled: Setting.BoolKey = "areCallsEnabled"
    
    /// Controls whether open group messages older than 6 months should be deleted
    static let trimOpenGroupMessagesOlderThanSixMonths: Setting.BoolKey = "trimOpenGroupMessagesOlderThanSixMonths"
    
    /// Controls whether the message requests item has been hidden on the home screen
    static let hasHiddenMessageRequests: Setting.BoolKey = "hasHiddenMessageRequests"
    
    /// Controls whether the notification sound should play while the app is in the foreground
    static let playNotificationSoundInForeground: Setting.BoolKey = "playNotificationSoundInForeground"
    
    /// A flag indicating whether the user has ever viewed their seed
    static let hasViewedSeed: Setting.BoolKey = "hasViewedSeed"
    
    /// A flag indicating whether the user hides the recovery password permanently
    static let hideRecoveryPasswordPermanently: Setting.BoolKey = "hideRecoveryPasswordPermanently"
    
    /// A flag indicating whether the user has ever saved a thread
    static let hasSavedThread: Setting.BoolKey = "hasSavedThread"
    
    /// A flag indicating whether the user has ever send a message
    static let hasSentAMessage: Setting.BoolKey = "hasSentAMessageKey"
    
    /// A flag indicating whether the app is ready for app extensions to run
    static let isReadyForAppExtensions: Setting.BoolKey = "isReadyForAppExtensions"
    
    /// Controls whether concurrent audio messages should automatically be played after the one the user starts
    /// playing finishes
    static let shouldAutoPlayConsecutiveAudioMessages: Setting.BoolKey = "shouldAutoPlayConsecutiveAudioMessages"
    
    /// Controls whether the device will poll for community message requests (SOGS `/inbox` endpoint)
    static let checkForCommunityMessageRequests: Setting.BoolKey = "checkForCommunityMessageRequests"
    
    /// Controls whether developer mode is enabled (this displays a section within the Settings screen which allows manual control of feature flags
    /// and system settings for better debugging)
    static let developerModeEnabled: Setting.BoolKey = "developerModeEnabled"
}

// stringlint:ignore_contents
public extension Setting.StringKey {
    /// This is the most recently recorded Push Notifications token
    static let lastRecordedPushToken: Setting.StringKey = "lastRecordedPushToken"
    
    /// This is the most recently recorded Voip token
    static let lastRecordedVoipToken: Setting.StringKey = "lastRecordedVoipToken"
    
    /// This is the last six emoji used by the user
    static let recentReactionEmoji: Setting.StringKey = "recentReactionEmoji"
    
    /// This is the preferred skin tones preference for the given emoji
    static func emojiPreferredSkinTones(emoji: String) -> Setting.StringKey {
        return Setting.StringKey("preferredSkinTones-\(emoji)")
    }
}

// stringlint:ignore_contents
public extension Setting.DoubleKey {
    /// The duration of the timeout for screen lock in seconds
    @available(*, unavailable, message: "Screen Lock should always be instant now")
    static let screenLockTimeoutSeconds: Setting.DoubleKey = "screenLockTimeoutSeconds"
}

// stringlint:ignore_contents
public extension Setting.IntKey {
    /// This is the number of times the app has successfully become active, it's not actually used for anything but allows us to make
    /// a database change on launch so the database will output an error if it fails to write
    static let activeCounter: Setting.IntKey = "activeCounter"
}

public enum Preferences {
    // stringlint:ignore_contents
    public static var isCallKitSupported: Bool {
#if targetEnvironment(simulator)
        /// The iOS simulator doesn't support CallKit, when receiving a call on the simulator and routing it via CallKit it
        /// will immediately trigger a hangup making it difficult to test - instead we just should just avoid using CallKit
        /// entirely on the simulator
        return false
#else
        guard let regionCode: String = NSLocale.current.regionCode else { return false }
        guard !regionCode.contains("CN") && !regionCode.contains("CHN") else { return false }
        
        return true
#endif
    }
}
