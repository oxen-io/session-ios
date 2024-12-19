// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import CallKit
import GRDB
import WebRTC
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

// MARK: - CXProviderConfiguration

public extension CXProviderConfiguration {
    static func defaultConfiguration(_ useSystemCallLog: Bool = false) -> CXProviderConfiguration {
        let iconMaskImage: UIImage = #imageLiteral(resourceName: "SessionGreen32")
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.iconTemplateImageData = iconMaskImage.pngData()
        configuration.includesCallsInRecents = useSystemCallLog
        
        return configuration
    }
}

// MARK: - SessionCallManager

public final class SessionCallManager: NSObject, CallManagerProtocol {
    let dependencies: Dependencies
    
    let provider: CXProvider?
    let callController: CXCallController?
    
    public var currentCall: CurrentCallProtocol? = nil {
        willSet {
            if (newValue != nil) {
                DispatchQueue.main.async {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
            } else {
                DispatchQueue.main.async {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
        }
    }
    
    // MARK: - Initialization
    
    init(useSystemCallLog: Bool = false, using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        if Preferences.isCallKitSupported {
            self.provider = CXProvider(configuration: .defaultConfiguration(useSystemCallLog))
            self.callController = CXCallController()
        }
        else {
            self.provider = nil
            self.callController = nil
        }
        
        super.init()
        
        // We cannot assert singleton here, because this class gets rebuilt when the user changes relevant call settings
        self.provider?.setDelegate(self, queue: nil)
    }
    
    // MARK: - Report calls
    
    public func reportFakeCall(info: String) {
        let callId = UUID()
        self.provider?.reportNewIncomingCall(
            with: callId,
            update: CXCallUpdate()
        ) { _ in
            Log.error(.calls, "Reported fake incoming call to CallKit due to: \(info)")
        }
        self.provider?.reportCall(
            with: callId,
            endedAt: nil,
            reason: .failed
        )
    }
    
    public func setCurrentCall(_ call: CurrentCallProtocol?) {
        self.currentCall = call
    }
    
    public func reportOutgoingCall(_ call: SessionCall) {
        Log.assertOnMainThread()
        dependencies[defaults: .appGroup, key: .isCallOngoing] = true
        dependencies[defaults: .appGroup, key: .lastCallPreOffer] = Date()
        
        call.stateDidChange = {
            if call.hasStartedConnecting {
                self.provider?.reportOutgoingCall(with: call.callId, startedConnectingAt: call.connectingDate)
            }
            
            if call.hasConnected {
                self.provider?.reportOutgoingCall(with: call.callId, connectedAt: call.connectedDate)
            }
        }
    }
    
    public func reportIncomingCall(_ call: CurrentCallProtocol, callerName: String, completion: @escaping (Error?) -> Void) {
        // Construct a CXCallUpdate describing the incoming call, including the caller.
        let update = CXCallUpdate()
        update.localizedCallerName = callerName
        update.remoteHandle = CXHandle(type: .generic, value: call.sessionId)
        update.hasVideo = false

        disableUnsupportedFeatures(callUpdate: update)

        // Report the incoming call to the system
        self.provider?.reportNewIncomingCall(with: call.callId, update: update) { [dependencies] error in
            guard error == nil else {
                self.reportCurrentCallEnded(reason: .failed)
                completion(error)
                return
            }
            dependencies[defaults: .appGroup, key: .isCallOngoing] = true
            dependencies[defaults: .appGroup, key: .lastCallPreOffer] = Date()
            completion(nil)
        }
    }
    
    public func reportCurrentCallEnded(reason: CXCallEndedReason?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.reportCurrentCallEnded(reason: reason)
            }
            return
        }
        
        func handleCallEnded() {
            SNLog("[Calls] Call ended.")
            WebRTCSession.current = nil
            dependencies[defaults: .appGroup, key: .isCallOngoing] = false
            dependencies[defaults: .appGroup, key: .lastCallPreOffer] = nil
            
            if dependencies[singleton: .appContext].isInBackground {
                (UIApplication.shared.delegate as? AppDelegate)?.stopPollers()
                Log.flush()
            }
        }
        
        guard let call = currentCall else {
            handleCallEnded()
            suspendDatabaseIfCallEndedInBackground()
            return
        }
        
        if let reason = reason {
            self.provider?.reportCall(with: call.callId, endedAt: nil, reason: reason)
            
            switch (reason) {
                case .answeredElsewhere: call.updateCallMessage(mode: .answeredElsewhere, using: dependencies)
                case .unanswered: call.updateCallMessage(mode: .unanswered, using: dependencies)
                case .declinedElsewhere: call.updateCallMessage(mode: .local, using: dependencies)
                default: call.updateCallMessage(mode: .remote, using: dependencies)
            }
        }
        else {
            call.updateCallMessage(mode: .local, using: dependencies)
        }
        
        (call as? SessionCall)?.webRTCSession.dropConnection()
        self.currentCall = nil
        handleCallEnded()
    }
    
    public func currentWebRTCSessionMatches(callId: String) -> Bool {
        return (
            WebRTCSession.current != nil &&
            WebRTCSession.current?.uuid == callId
        )
    }
    
    // MARK: - Util
    
    private func disableUnsupportedFeatures(callUpdate: CXCallUpdate) {
        // Call Holding is failing to restart audio when "swapping" calls on the CallKit screen
        // until user returns to in-app call screen.
        callUpdate.supportsHolding = false

        // Not yet supported
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false

        // Is there any reason to support this?
        callUpdate.supportsDTMF = false
    }
    
    public func suspendDatabaseIfCallEndedInBackground() {
        Log.info(.calls, "Called suspendDatabaseIfCallEndedInBackground.")
        
        if dependencies[singleton: .appContext].isInBackground {
            // Stop all jobs except for message sending and when completed suspend the database
            dependencies[singleton: .jobRunner].stopAndClearPendingJobs(exceptForVariant: .messageSend) { [dependencies] _ in
                dependencies.mutate(cache: .libSessionNetwork) { $0.suspendNetworkAccess() }
                dependencies[singleton: .storage].suspendDatabaseAccess()
                Log.flush()
            }
        }
    }
    
    // MARK: - UI
    
    public func showCallUIForCall(caller: String, uuid: String, mode: CallMode, interactionId: Int64?) {
        guard
            let call: SessionCall = dependencies[singleton: .storage].read({ [dependencies] db in
                SessionCall(db, for: caller, uuid: uuid, mode: mode, using: dependencies)
            })
        else { return }
        
        call.callInteractionId = interactionId
        call.reportIncomingCallIfNeeded { [dependencies] error in
            if let error = error {
                Log.error(.calls, "Failed to report incoming call to CallKit due to error: \(error)")
                return
            }
            
            DispatchQueue.main.async {
                guard
                    dependencies[singleton: .appContext].isMainAppAndActive,
                    let presentingVC: UIViewController = dependencies[singleton: .appContext].frontMostViewController
                else { return }
                
                if
                    let conversationVC: ConversationVC = (presentingVC as? TopBannerController)?.wrappedViewController() as? ConversationVC,
                    conversationVC.viewModel.threadData.threadId == call.sessionId
                {
                    let callVC = CallVC(for: call, using: dependencies)
                    callVC.conversationVC = conversationVC
                    conversationVC.hideInputAccessoryView()
                    presentingVC.present(callVC, animated: true, completion: nil)
                }
                else if !Preferences.isCallKitSupported {
                    let incomingCallBanner = IncomingCallBanner(for: call, using: dependencies)
                    incomingCallBanner.show()
                }
            }
        }
    }
    
    public func handleICECandidates(message: CallMessage, sdpMLineIndexes: [UInt32], sdpMids: [String]) {
        guard
            let currentWebRTCSession = WebRTCSession.current,
            currentWebRTCSession.uuid == message.uuid
        else { return }
        
        var candidates: [RTCIceCandidate] = []
        let sdps = message.sdps
        for i in 0..<sdps.count {
            let sdp = sdps[i]
            let sdpMLineIndex = sdpMLineIndexes[i]
            let sdpMid = sdpMids[i]
            let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(sdpMLineIndex), sdpMid: sdpMid)
            candidates.append(candidate)
        }
        currentWebRTCSession.handleICECandidates(candidates)
    }
    
    public func handleAnswerMessage(_ message: CallMessage) {
        guard dependencies[singleton: .appContext].isValid else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.handleAnswerMessage(message)
            }
            return
        }
        
        (dependencies[singleton: .appContext].frontMostViewController as? CallVC)?.handleAnswerMessage(message)
    }
    
    public func dismissAllCallUI() {
        guard dependencies[singleton: .appContext].isValid else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.dismissAllCallUI()
            }
            return
        }
        
        IncomingCallBanner.current?.dismiss()
        (dependencies[singleton: .appContext].frontMostViewController as? CallVC)?.handleEndCallMessage()
        MiniCallView.current?.dismiss()
    }
}
