// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public class AppVersion {
    private static var _shared: AppVersion?
    public static var shared: AppVersion {
        let result: AppVersion = (_shared ?? AppVersion())
        _shared = result
        return result
    }
    
    public var isFirstLaunch: Bool { self.firstAppVersion != nil }
    
    public let isValid: Bool
    public let currentAppVersion: String
    
    /// The version of the app when it was first launched (`nil` if the app has never been launched before)
    public var firstAppVersion: String?
    
    /// The version of the app the last time it was launched (`nil` if the app has never been launched before)
    public var lastAppVersion: String?
    
    public var lastCompletedLaunchAppVersion: String?
    public var lastCompletedLaunchMainAppVersion: String?
    public var lastCompletedLaunchSAEAppVersion: String?
    
    // MARK: - Initialization
    
    private init(using dependencies: Dependencies = Dependencies()) {
        guard let currentAppVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            self.isValid = false
            self.currentAppVersion = ""
            self.firstAppVersion = nil
            self.lastAppVersion = nil
            self.lastCompletedLaunchAppVersion = nil
            self.lastCompletedLaunchMainAppVersion = nil
            self.lastCompletedLaunchSAEAppVersion = nil
            return
        }
        
        let oldFirstAppVersion: String? = dependencies[defaults: .appGroup, key: .firstAppVersion]
        
        self.isValid = true
        self.currentAppVersion = currentAppVersion
        self.firstAppVersion = dependencies[defaults: .appGroup, key: .firstAppVersion]
            .defaulting(to: currentAppVersion)
        self.lastAppVersion = dependencies[defaults: .appGroup, key: .lastAppVersion]
        self.lastCompletedLaunchAppVersion = dependencies[defaults: .appGroup, key: .lastCompletedLaunchAppVersion]
        self.lastCompletedLaunchMainAppVersion = dependencies[defaults: .appGroup, key: .lastCompletedLaunchMainAppVersion]
        self.lastCompletedLaunchSAEAppVersion = dependencies[defaults: .appGroup, key: .lastCompletedLaunchSAEAppVersion]

        // Ensure the value for the "first launched version".
        if oldFirstAppVersion == nil {
            dependencies[defaults: .appGroup, key: .firstAppVersion] = currentAppVersion
        }

        // Update the value for the "most recently launched version".
        dependencies[defaults: .appGroup, key: .lastAppVersion] = currentAppVersion
    }
    
    // MARK: - Functions
    
    public static func configure(using dependencies: Dependencies) {
        _shared = AppVersion(using: dependencies)
    }
    
    private func appLaunchDidComplete(using dependencies: Dependencies) {
        lastCompletedLaunchAppVersion = currentAppVersion

        // Update the value for the "most recently launch-completed version".
        dependencies[defaults: .appGroup, key: .lastCompletedLaunchAppVersion] = currentAppVersion
    }

    public func mainAppLaunchDidComplete(using dependencies: Dependencies) {
        lastCompletedLaunchMainAppVersion = currentAppVersion
        
        dependencies[defaults: .appGroup, key: .lastCompletedLaunchMainAppVersion] = currentAppVersion
        appLaunchDidComplete(using: dependencies)
    }

    public func saeLaunchDidComplete(using dependencies: Dependencies) {
        lastCompletedLaunchSAEAppVersion = currentAppVersion
        dependencies[defaults: .appGroup, key: .lastCompletedLaunchSAEAppVersion] = currentAppVersion
        appLaunchDidComplete(using: dependencies)
    }
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
