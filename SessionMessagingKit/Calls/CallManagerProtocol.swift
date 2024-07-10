// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CallKit

public protocol CallManagerProtocol {
    var currentCall: CurrentCallProtocol? { get set }
    
    func reportCurrentCallEnded(reason: CXCallEndedReason?)
    
    func showCallUIForCall(caller: String, uuid: String, mode: CallMode, interactionId: Int64?)
    func handleICECandidates(message: CallMessage, sdpMLineIndexes: [UInt32], sdpMids: [String])
    func handleAnswerMessage(_ message: CallMessage)
    
    func currentWebRTCSessionMatches(callId: String) -> Bool
    
    func dismissAllCallUI()
}
