// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public extension UserDefaultsStorage {
    static var standard: UserDefaultsConfig = Dependencies.create(identifier: "standard") { _ in
        UserDefaults.standard
    }
    static var appGroup: UserDefaultsConfig = Dependencies.create(identifier: UserDefaults.applicationGroup) { _ in
        UserDefaults(suiteName: UserDefaults.applicationGroup)!
    }
}

// MARK: - UserDefaultsType

public protocol UserDefaultsType: AnyObject {
    var allKeys: [String] { get }
    
    func object(forKey defaultName: String) -> Any?
    func string(forKey defaultName: String) -> String?
    func array(forKey defaultName: String) -> [Any]?
    func dictionary(forKey defaultName: String) -> [String : Any]?
    func data(forKey defaultName: String) -> Data?
    func stringArray(forKey defaultName: String) -> [String]?
    func integer(forKey defaultName: String) -> Int
    func float(forKey defaultName: String) -> Float
    func double(forKey defaultName: String) -> Double
    func bool(forKey defaultName: String) -> Bool
    func url(forKey defaultName: String) -> URL?

    func set(_ value: Any?, forKey defaultName: String)
    func set(_ value: Int, forKey defaultName: String)
    func set(_ value: Float, forKey defaultName: String)
    func set(_ value: Double, forKey defaultName: String)
    func set(_ value: Bool, forKey defaultName: String)
    func set(_ url: URL?, forKey defaultName: String)
    
    func removeAll()
}

extension UserDefaults: UserDefaultsType {}

// MARK: - Convenience

public extension UserDefaults {
    static let applicationGroup: String = "group.com.loki-project.loki-messenger"
    
    var allKeys: [String] { Array(self.dictionaryRepresentation().keys) }
    
    static func removeAll(using dependencies: Dependencies) {
        UserDefaultsStorage.standard.createInstance(dependencies).removeAll()
        UserDefaultsStorage.appGroup.createInstance(dependencies).removeAll()
    }
    
    func removeAll() {
        let data: [String: Any] = self.dictionaryRepresentation()
        data.forEach { key, _ in self.removeObject(forKey: key) }
        self.synchronize()  // Shouldn't be needed but better safe than sorry
    }
}

// MARK: - UserDefault Values

public extension UserDefaults.BoolKey {
    /// Indicates whether the user has synced an initial config message from this device
    static let hasSyncedInitialConfiguration: UserDefaults.BoolKey = "hasSyncedConfiguration"
    
    /// Indicates whether the user has seen the suggestion to enable link previews
    static let hasSeenLinkPreviewSuggestion: UserDefaults.BoolKey = "hasSeenLinkPreviewSuggestion"
    
    /// Indicates whether the user has seen the IP exposure warning when enabling calls
    ///
    /// **Note:** This is currently not in use (it was decided that it's better to warn the user every time they enable calls instead
    /// of just the first time)
    static let hasSeenCallIPExposureWarning: UserDefaults.BoolKey = "hasSeenCallIPExposureWarning"
    
    /// Indicates whether the user has seen the missed call tips modal
    static let hasSeenCallMissedTips: UserDefaults.BoolKey = "hasSeenCallMissedTips"
    
    /// Indicates whether the user is registered for APNS (ie. "Fast Mode" notifications)
    static let isUsingFullAPNs: UserDefaults.BoolKey = "isUsingFullAPNs"
    
    /// Indicates whether the device was unlinked from an account
    ///
    /// **Note:** This doesn't seem to be properly used (we basically just maintain the existing value)
    static let wasUnlinked: UserDefaults.BoolKey = "wasUnlinked"
    
    /// Indicates whether the main app is active, this is set to `true` while the app is in the foreground and `false` when
    /// the app is in the background
    static let isMainAppActive: UserDefaults.BoolKey = "isMainAppActive"
    
    /// Indicates whether there is an ongoing call
    static let isCallOngoing: UserDefaults.BoolKey = "isCallOngoing"
}

public extension UserDefaults.DateKey {
    /// The date/time when the users profile picture was last uploaded to the server (used to rate-limit re-uploading)
    static let lastProfilePictureUpload: UserDefaults.DateKey = "lastProfilePictureUpload"
    
    /// The date/time when any open group last had a successful poll (used as a fallback date/time if the open group hasn't been polled
    /// this session)
    static let lastOpen: UserDefaults.DateKey = "lastOpen"
    
    /// The date/time when the last garbage collection was performed (used to rate-limit garbage collection)
    static let lastGarbageCollection: UserDefaults.DateKey = "lastGarbageCollection"
    
    /// The date/time when we received a call pre-offer (used to suppress call notifications which are too old)
    static let lastCallPreOffer: UserDefaults.DateKey = "lastCallPreOffer"
}

public extension UserDefaults.DoubleKey {
    /// The timestamp when we last successfully uploaded the users push token (used to rate-limit calling our subscription endpoint)
    static let lastDeviceTokenUpload: UserDefaults.DoubleKey = "lastDeviceTokenUploadTime"
}

public extension UserDefaults.IntKey {
    /// The latest hardfork value returned when interacting with a service node
    static let hardfork: UserDefaults.IntKey = "hardfork"
    
    /// The latest softfork value returned when interacting with a service node
    static let softfork: UserDefaults.IntKey = "softfork"
}

public extension UserDefaults.StringKey {
    /// The most recently subscribed APNS token
    static let deviceToken: UserDefaults.StringKey = "deviceToken"
    
    /// The warning to show at the top of the app
    static let topBannerWarningToShow: UserDefaults.StringKey = "topBannerWarningToShow"
}

// MARK: - Keys

public extension UserDefaults {
    struct BoolKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
    
    struct DateKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
    
    struct DoubleKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
    
    struct IntKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
    
    struct StringKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
}
