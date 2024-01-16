// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CallKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let callManager: SingletonConfig<CallManagerProtocol> = Dependencies.create(
        identifier: "sessionCallManager",
        createInstance: { _ in NoopSessionCallManager() }
    )
}

// MARK: - CallManagerProtocol

public protocol CallManagerProtocol {
    var currentCall: CurrentCallProtocol? { get }
    
    func setCurrentCall(_ call: CurrentCallProtocol?)
    func reportIncomingCall(_ call: CurrentCallProtocol, callerName: String, completion: @escaping (Error?) -> Void)
    func reportCurrentCallEnded(reason: CXCallEndedReason?)
    func suspendDatabaseIfCallEndedInBackground()
    
    func startCall(_ call: CurrentCallProtocol?, completion: ((Error?) -> Void)?)
    func answerCall(_ call: CurrentCallProtocol?, completion: ((Error?) -> Void)?)
    func endCall(_ call: CurrentCallProtocol?, completion: ((Error?) -> Void)?)
    
    func showCallUIForCall(caller: String, uuid: String, mode: CallMode, interactionId: Int64?)
    func handleAnswerMessage(_ message: CallMessage)
    func dismissAllCallUI()
}
