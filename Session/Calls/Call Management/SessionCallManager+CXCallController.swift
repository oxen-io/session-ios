// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CallKit
import SessionMessagingKit
import SessionUtilitiesKit

extension SessionCallManager {
    public func startCall(_ call: CurrentCallProtocol?, completion: ((Error?) -> Void)?) {
        guard
            let call: SessionCall = call as? SessionCall,
            case .offer = call.mode,
            !call.hasConnected
        else { return }
        
        reportOutgoingCall(call)
        
        if callController != nil {
            let handle = CXHandle(type: .generic, value: call.sessionId)
            let startCallAction = CXStartCallAction(call: call.callId, handle: handle)
            
            startCallAction.isVideo = false
            
            let transaction = CXTransaction()
            transaction.addAction(startCallAction)
            
            requestTransaction(transaction, completion: completion)
        }
        else {
            startCallAction()
            completion?(nil)
        }
    }
    
    public func answerCall(_ call: CurrentCallProtocol?, completion: ((Error?) -> Void)?) {
        if callController != nil, let callId: UUID = call?.callId {
            let answerCallAction = CXAnswerCallAction(call: callId)
            let transaction = CXTransaction()
            transaction.addAction(answerCallAction)

            requestTransaction(transaction, completion: completion)
        }
        else {
            answerCallAction()
            completion?(nil)
        }
    }
    
    public func endCall(_ call: CurrentCallProtocol?, completion: ((Error?) -> Void)?) {
        if callController != nil, let callId: UUID = call?.callId {
            let endCallAction = CXEndCallAction(call: callId)
            let transaction = CXTransaction()
            transaction.addAction(endCallAction)

            requestTransaction(transaction, completion: completion)
        }
        else {
            endCallAction()
            completion?(nil)
        }
    }
    
    // Not currently in use
    public func setOnHoldStatus(for call: SessionCall) {
        if callController != nil {
            let setHeldCallAction = CXSetHeldCallAction(call: call.callId, onHold: true)
            let transaction = CXTransaction()
            transaction.addAction(setHeldCallAction)

            requestTransaction(transaction)
        }
    }
    
    private func requestTransaction(_ transaction: CXTransaction, completion: ((Error?) -> Void)? = nil) {
        callController?.request(transaction) { error in
            if let error = error {
                SNLog("Error requesting transaction: \(error)")
            }
            else {
                SNLog("Requested transaction successfully")
            }
            
            completion?(error)
        }
    }
}
