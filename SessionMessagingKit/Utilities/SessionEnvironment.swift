// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public class SessionEnvironment {
    public static var shared: SessionEnvironment?
    
    public let audioSession: OWSAudioSession
    public let proximityMonitoringManager: OWSProximityMonitoringManager
    public let windowManager: OWSWindowManager
    public var isRequestingPermission: Bool
    
    // MARK: - Initialization
    
    public init(
        audioSession: OWSAudioSession,
        proximityMonitoringManager: OWSProximityMonitoringManager,
        windowManager: OWSWindowManager
    ) {
        self.audioSession = audioSession
        self.proximityMonitoringManager = proximityMonitoringManager
        self.windowManager = windowManager
        self.isRequestingPermission = false
        
        if SessionEnvironment.shared == nil {
            SessionEnvironment.shared = self
        }
    }
    
    // MARK: - Functions
    
    public static func clearSharedForTests() {
        shared = nil
    }
}

// MARK: - Objective C Support

@objc(SMKEnvironment)
public class SMKEnvironment: NSObject {
    @objc public static let shared: SMKEnvironment = SMKEnvironment()
    
    @objc public var audioSession: OWSAudioSession? { SessionEnvironment.shared?.audioSession }
    @objc public var windowManager: OWSWindowManager? { SessionEnvironment.shared?.windowManager }
}
