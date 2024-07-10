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
    
    private init() {
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
        
        let oldFirstAppVersion: String? = UserDefaults.sharedLokiProject?.string(forKey: AppVersion.firstAppVersion)
        
        self.isValid = true
        self.currentAppVersion = currentAppVersion
        self.firstAppVersion = UserDefaults.sharedLokiProject?
            .string(forKey: AppVersion.firstAppVersion)
            .defaulting(to: currentAppVersion)
        self.lastAppVersion = UserDefaults.sharedLokiProject?.string(forKey: AppVersion.lastAppVersion)
        self.lastCompletedLaunchAppVersion = UserDefaults.sharedLokiProject?.string(forKey: AppVersion.lastCompletedLaunchAppVersion)
        self.lastCompletedLaunchMainAppVersion = UserDefaults.sharedLokiProject?.string(forKey: AppVersion.lastCompletedLaunchMainAppVersion)
        self.lastCompletedLaunchSAEAppVersion = UserDefaults.sharedLokiProject?.string(forKey: AppVersion.lastCompletedLaunchSAEAppVersion)
        
        // Ensure the value for the "first launched version".
        if oldFirstAppVersion == nil {
            UserDefaults.sharedLokiProject?.setValue(currentAppVersion, forKey: AppVersion.firstAppVersion)
        }

        // Update the value for the "most recently launched version".
        UserDefaults.sharedLokiProject?.setValue(currentAppVersion, forKey: AppVersion.lastAppVersion)
    }
    
    // MARK: - Functions
    
    public static func configure() {
        _shared = AppVersion()
    }
    
    private func appLaunchDidComplete() {
        lastCompletedLaunchAppVersion = currentAppVersion

        // Update the value for the "most recently launch-completed version".
        UserDefaults.sharedLokiProject?.setValue(currentAppVersion, forKey: AppVersion.lastCompletedLaunchAppVersion)
    }

    public func mainAppLaunchDidComplete() {
        lastCompletedLaunchMainAppVersion = currentAppVersion
        
        UserDefaults.sharedLokiProject?.setValue(currentAppVersion, forKey: AppVersion.lastCompletedLaunchMainAppVersion)
        appLaunchDidComplete()
    }

    public func saeLaunchDidComplete() {
        lastCompletedLaunchSAEAppVersion = currentAppVersion
        UserDefaults.sharedLokiProject?.setValue(currentAppVersion, forKey: AppVersion.lastCompletedLaunchSAEAppVersion)
        appLaunchDidComplete()
    }
}

// MARK: - UserDefaults Keys

private extension AppVersion {
    /// The version of the app when it was first launched
    static let firstAppVersion: String = "kNSUserDefaults_FirstAppVersion"
    
    /// The version of the app when it was last launched
    static let lastAppVersion: String = "kNSUserDefaults_LastVersion"
    
    static let lastCompletedLaunchAppVersion: String = "kNSUserDefaults_LastCompletedLaunchAppVersion"
    static let lastCompletedLaunchMainAppVersion: String = "kNSUserDefaults_LastCompletedLaunchAppVersion_MainApp"
    static let lastCompletedLaunchSAEAppVersion: String = "kNSUserDefaults_LastCompletedLaunchAppVersion_SAE"
}
