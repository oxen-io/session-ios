// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit

// MARK: - Cache

public extension Cache {
    static let appVersion: CacheConfig<AppVersionCacheType, AppVersionImmutableCacheType> = Dependencies.create(
        identifier: "appVersion",
        createInstance: { dependencies in AppVersion(using: dependencies) },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - AppVersion

public class AppVersion: AppVersionCacheType {
    private let dependencies: Dependencies
    public let isValid: Bool
    public let appVersion: String
    public let buildNumber: String
    public let commitHash: String
    public let libSessionVersion: String
    
    public var firstAppVersion: String?
    public var lastAppVersion: String?
    public var lastCompletedLaunchAppVersion: String?
    public var lastCompletedLaunchMainAppVersion: String?
    public var lastCompletedLaunchSAEAppVersion: String?
    
    public var isFirstLaunch: Bool { self.firstAppVersion != nil }
    public var didJustUpdate: Bool {
        (lastAppVersion?.count ?? 0) > 0 &&
        lastAppVersion != appVersion
    }
    public var versionInfo: String {
        return [
            "iOS \(UIDevice.current.systemVersion)",
            [
                "App: \(appVersion)",
                [buildNumber.nullIfEmpty, commitHash.nullIfEmpty]
                    .compactMap { $0 }
                    .joined(separator: " - ")
                    .nullIfEmpty
                    .map { "(\($0))" }
            ].compactMap { $0 }.joined(separator: " "),
            "libSession: \(LibSession.version)"
        ].joined(separator: ", ")
    }
    
    // MARK: - Initialization
    
    fileprivate init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        guard let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            self.isValid = false
            self.appVersion = ""
            self.buildNumber = ""
            self.commitHash = ""
            self.libSessionVersion = ""
            
            self.firstAppVersion = nil
            self.lastAppVersion = nil
            self.lastCompletedLaunchAppVersion = nil
            self.lastCompletedLaunchMainAppVersion = nil
            self.lastCompletedLaunchSAEAppVersion = nil
            return
        }
        
        let oldFirstAppVersion: String? = dependencies[defaults: .appGroup, key: .firstAppVersion]
        
        self.isValid = true
        self.appVersion = appVersion
        self.buildNumber = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).defaulting(to: "")
        self.commitHash = (Bundle.main.infoDictionary?["GitCommitHash"] as? String).defaulting(to: "")
        self.libSessionVersion = LibSession.version
        
        self.firstAppVersion = dependencies[defaults: .appGroup, key: .firstAppVersion]
            .defaulting(to: appVersion)
        self.lastAppVersion = dependencies[defaults: .appGroup, key: .lastAppVersion]
        self.lastCompletedLaunchAppVersion = dependencies[defaults: .appGroup, key: .lastCompletedLaunchAppVersion]
        self.lastCompletedLaunchMainAppVersion = dependencies[defaults: .appGroup, key: .lastCompletedLaunchMainAppVersion]
        self.lastCompletedLaunchSAEAppVersion = dependencies[defaults: .appGroup, key: .lastCompletedLaunchSAEAppVersion]

        // Ensure the value for the "first launched version".
        if oldFirstAppVersion == nil {
            dependencies[defaults: .appGroup, key: .firstAppVersion] = appVersion
        }

        // Update the value for the "most recently launched version".
        dependencies[defaults: .appGroup, key: .lastAppVersion] = appVersion
    }
    
    // MARK: - Functions
    
    private func anyLaunchDidComplete() {
        lastCompletedLaunchAppVersion = appVersion

        // Update the value for the "most recently launch-completed version".
        dependencies[defaults: .appGroup, key: .lastCompletedLaunchAppVersion] = appVersion
    }

    public func mainAppLaunchDidComplete() {
        lastCompletedLaunchMainAppVersion = appVersion
        
        dependencies[defaults: .appGroup, key: .lastCompletedLaunchMainAppVersion] = appVersion
        anyLaunchDidComplete()
    }

    public func saeLaunchDidComplete() {
        lastCompletedLaunchSAEAppVersion = appVersion
        dependencies[defaults: .appGroup, key: .lastCompletedLaunchSAEAppVersion] = appVersion
        anyLaunchDidComplete()
    }
}

// MARK: - AppVersionCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol AppVersionImmutableCacheType: ImmutableCacheType {
    /// Flag indicating whether the version information is valid
    var isValid: Bool { get }
    
    /// The current app version
    var appVersion: String { get }
    
    /// The current build number
    var buildNumber: String { get }
    
    /// The commit hash for the current build
    var commitHash: String { get }
    
    /// The current `libSession` version
    var libSessionVersion: String { get }
    
    /// The version of the app when it was first launched (`nil` if the app has never been launched before)
    var firstAppVersion: String? { get }
    
    /// The version of the app the last time it was launched (`nil` if the app has never been launched before)
    var lastAppVersion: String? { get }
    
    /// The last app version where is successfully launched the main app
    var lastCompletedLaunchAppVersion: String? { get }
    
    /// The last app version where is successfully launched the main app
    var lastCompletedLaunchMainAppVersion: String? { get }
    
    /// The last app version where is successfully launched the main app
    var lastCompletedLaunchSAEAppVersion: String? { get }
    
    /// Flag indicating whether this is the first app launch
    var isFirstLaunch: Bool { get }
    
    /// Flag indicating whether the app was just updated
    var didJustUpdate: Bool { get }
    
    /// The full version information for the current version
    var versionInfo: String { get }
}

public protocol AppVersionCacheType: AppVersionImmutableCacheType, MutableCacheType {
    /// Function to call when the main app successfully completed a launch
    func mainAppLaunchDidComplete()
    
    /// Function to call when the share extension successfully completed a launch
    func saeLaunchDidComplete()
}

// MARK: - UserDefaults Keys

private extension UserDefaults.StringKey {
    /// The version of the app when it was first launched
    static let firstAppVersion: UserDefaults.StringKey = "kNSUserDefaults_FirstAppVersion"
    
    /// The version of the app when it was last launched
    static let lastAppVersion: UserDefaults.StringKey = "kNSUserDefaults_LastVersion"
    
    static let lastCompletedLaunchAppVersion: UserDefaults.StringKey = "kNSUserDefaults_LastCompletedLaunchAppVersion"
    static let lastCompletedLaunchMainAppVersion: UserDefaults.StringKey = "kNSUserDefaults_LastCompletedLaunchAppVersion_MainApp"
    static let lastCompletedLaunchSAEAppVersion: UserDefaults.StringKey = "kNSUserDefaults_LastCompletedLaunchAppVersion_SAE"
}
