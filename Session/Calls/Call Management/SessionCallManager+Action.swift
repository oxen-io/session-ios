// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import SessionMessagingKit
import SessionUtilitiesKit

extension SessionCallManager {
    @discardableResult
    public func startCallAction() -> Bool {
        guard let call: CurrentCallProtocol = self.currentCall else { return false }
        
        dependencies[singleton: .storage].writeAsync { db in
            call.startSessionCall(db)
        }
        
        return true
    }
    
    public func answerCallAction() {
        guard let call: SessionCall = (self.currentCall as? SessionCall) else { return }
        
        if dependencies[singleton: .appContext].frontMostViewController is CallVC {
            call.answerSessionCall()
        }
        else {
            guard let presentingVC = dependencies[singleton: .appContext].frontMostViewController else { return } // FIXME: Handle more gracefully
            let callVC = CallVC(for: call, using: dependencies)

            if let conversationVC = presentingVC as? ConversationVC {
                callVC.conversationVC = conversationVC
                conversationVC.inputAccessoryView?.isHidden = true
                conversationVC.inputAccessoryView?.alpha = 0
            }
            
            presentingVC.present(callVC, animated: true) {
                call.answerSessionCall()
            }
        }
    }
    
    @discardableResult
    public func endCallAction() -> Bool {
        guard let call: SessionCall = (self.currentCall as? SessionCall) else { return false }
        
        call.endSessionCall()
        
        if call.didTimeout {
            reportCurrentCallEnded(reason: .unanswered)
        }
        else {
            reportCurrentCallEnded(reason: nil)
        }
        
        return true
    }
    
    @discardableResult
    public func setMutedCallAction(isMuted: Bool) -> Bool {
        guard let call: SessionCall = (self.currentCall as? SessionCall) else { return false }
        
        call.isMuted = isMuted
        
        return true
    }
}
