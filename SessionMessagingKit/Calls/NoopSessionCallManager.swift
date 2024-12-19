// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CallKit

internal struct NoopSessionCallManager: CallManagerProtocol {
    var currentCall: CurrentCallProtocol?

    func setCurrentCall(_ call: CurrentCallProtocol?) {}
    func reportFakeCall(info: String) {}
    func reportIncomingCall(_ call: CurrentCallProtocol, callerName: String, completion: @escaping (Error?) -> Void) {}
    func reportCurrentCallEnded(reason: CXCallEndedReason?) {}
    func suspendDatabaseIfCallEndedInBackground() {}

    func startCall(_ call: CurrentCallProtocol?, completion: ((Error?) -> Void)?) {}
    func answerCall(_ call: CurrentCallProtocol?, completion: ((Error?) -> Void)?) {}
    func endCall(_ call: CurrentCallProtocol?, completion: ((Error?) -> Void)?) {}

    func showCallUIForCall(caller: String, uuid: String, mode: CallMode, interactionId: Int64?) {}
    func handleICECandidates(message: CallMessage, sdpMLineIndexes: [UInt32], sdpMids: [String]) {}
    func handleAnswerMessage(_ message: CallMessage) {}
    
    func currentWebRTCSessionMatches(callId: String) -> Bool { return false }
    
    func dismissAllCallUI() {}
}
