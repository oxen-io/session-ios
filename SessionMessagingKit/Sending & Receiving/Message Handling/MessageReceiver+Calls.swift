// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import WebRTC
import SessionUtilitiesKit
import SessionSnodeKit

extension MessageReceiver {
    public static func handleCallMessage(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: CallMessage,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        // Only support calls from contact threads
        guard threadVariant == .contact else { return }
        
        switch message.kind {
            case .preOffer: try MessageReceiver.handleNewCallMessage(db, message: message, using: dependencies)
            case .offer: MessageReceiver.handleOfferCallMessage(db, message: message, using: dependencies)
            case .answer: MessageReceiver.handleAnswerCallMessage(db, message: message, using: dependencies)
            case .provisionalAnswer: break // TODO: Implement
                
            case let .iceCandidates(sdpMLineIndexes, sdpMids):
                guard let currentWebRTCSession = WebRTCSession.current, currentWebRTCSession.uuid == message.uuid else {
                    return
                }
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
                
            case .endCall: MessageReceiver.handleEndCallMessage(db, message: message, using: dependencies)
        }
    }
    
    // MARK: - Specific Handling
    
    private static func handleNewCallMessage(
        _ db: Database,
        message: CallMessage,
        using dependencies: Dependencies
    ) throws {
        SNLog("[Calls] Received pre-offer message.")
        
        // Determine whether the app is active based on the prefs rather than the UIApplication state to avoid
        // requiring main-thread execution
        let isMainAppActive: Bool = dependencies[defaults: .appGroup, key: .isMainAppActive]
        
        // It is enough just ignoring the pre offers, other call messages
        // for this call would be dropped because of no Session call instance
        guard
            dependencies.hasInitialised(singleton: .appContext),
            dependencies[singleton: .appContext].isMainApp,
            let sender: String = message.sender,
            (try? Contact
                .filter(id: sender)
                .select(.isApproved)
                .asRequest(of: Bool.self)
                .fetchOne(db))
                .defaulting(to: false)
        else { return }
        guard let timestamp = message.sentTimestamp, TimestampUtils.isWithinOneMinute(timestamp: timestamp) else {
            // Add missed call message for call offer messages from more than one minute
            if let interaction: Interaction = try MessageReceiver.insertCallInfoMessage(db, for: message, state: .missed) {
                let thread: SessionThread = try SessionThread.fetchOrCreate(
                    db,
                    id: sender,
                    variant: .contact,
                    shouldBeVisible: nil,
                    calledFromConfigHandling: false
                )
                
                if !interaction.wasRead {
                    dependencies[singleton: .notificationsManager].notifyUser(
                        db,
                        forIncomingCall: interaction,
                        in: thread,
                        applicationState: (isMainAppActive ? .active : .background)
                    )
                }
            }
            return
        }
        
        guard db[.areCallsEnabled] else {
            if let interaction: Interaction = try MessageReceiver.insertCallInfoMessage(db, for: message, state: .permissionDenied) {
                let thread: SessionThread = try SessionThread.fetchOrCreate(
                    db,
                    id: sender,
                    variant: .contact,
                    shouldBeVisible: nil,
                    calledFromConfigHandling: false
                )
                
                if !interaction.wasRead {
                    dependencies[singleton: .notificationsManager].notifyUser(
                        db,
                        forIncomingCall: interaction,
                        in: thread,
                        applicationState: (isMainAppActive ? .active : .background)
                    )
                }
                
                // Trigger the missed call UI if needed
                NotificationCenter.default.post(
                    name: .missedCall,
                    object: nil,
                    userInfo: [ Notification.Key.senderId.rawValue: sender ]
                )
            }
            return
        }
        
        // Ignore pre offer message after the same call instance has been generated
        if let currentCall: CurrentCallProtocol = dependencies[singleton: .callManager].currentCall, currentCall.uuid == message.uuid {
            return
        }
        
        guard dependencies[singleton: .callManager].currentCall == nil else {
            try MessageReceiver.handleIncomingCallOfferInBusyState(db, message: message)
            return
        }
        
        let interaction: Interaction? = try MessageReceiver.insertCallInfoMessage(db, for: message)
        
        // Handle UI
        dependencies[singleton: .callManager].showCallUIForCall(
            caller: sender,
            uuid: message.uuid,
            mode: .answer,
            interactionId: interaction?.id
        )
    }
    
    private static func handleOfferCallMessage(_ db: Database, message: CallMessage, using dependencies: Dependencies) {
        SNLog("[Calls] Received offer message.")
        
        // Ensure we have a call manager before continuing
        guard
            let currentCall: CurrentCallProtocol = dependencies[singleton: .callManager].currentCall,
            currentCall.uuid == message.uuid,
            let sdp: String = message.sdps.first
        else { return }
        
        let sdpDescription: RTCSessionDescription = RTCSessionDescription(type: .offer, sdp: sdp)
        currentCall.didReceiveRemoteSDP(sdp: sdpDescription)
    }
    
    private static func handleAnswerCallMessage(
        _ db: Database,
        message: CallMessage,
        using dependencies: Dependencies
    ) {
        SNLog("[Calls] Received answer message.")
        
        guard
            let currentWebRTCSession: WebRTCSession = WebRTCSession.current,
            currentWebRTCSession.uuid == message.uuid,
            var currentCall: CurrentCallProtocol = dependencies[singleton: .callManager].currentCall,
            currentCall.uuid == message.uuid,
            let sender: String = message.sender
        else { return }
        
        guard sender != getUserSessionId(db, using: dependencies).hexString else {
            guard !currentCall.hasStartedConnecting else { return }
            
            dependencies[singleton: .callManager].dismissAllCallUI()
            dependencies[singleton: .callManager].reportCurrentCallEnded(reason: .answeredElsewhere)
            return
        }
        guard let sdp: String = message.sdps.first else { return }
        
        let sdpDescription: RTCSessionDescription = RTCSessionDescription(type: .answer, sdp: sdp)
        currentCall.hasStartedConnecting = true
        currentCall.didReceiveRemoteSDP(sdp: sdpDescription)
        dependencies[singleton: .callManager].handleAnswerMessage(message)
    }
    
    private static func handleEndCallMessage(
        _ db: Database,
        message: CallMessage,
        using dependencies: Dependencies
    ) {
        SNLog("[Calls] Received end call message.")
        
        guard
            WebRTCSession.current?.uuid == message.uuid,
            let currentCall: CurrentCallProtocol = dependencies[singleton: .callManager].currentCall,
            currentCall.uuid == message.uuid,
            let sender: String = message.sender
        else { return }
        
        dependencies[singleton: .callManager].dismissAllCallUI()
        dependencies[singleton: .callManager].reportCurrentCallEnded(
            reason: (sender == getUserSessionId(db, using: dependencies).hexString ?
                .declinedElsewhere :
                .remoteEnded
            )
        )
    }
    
    // MARK: - Convenience
    
    public static func handleIncomingCallOfferInBusyState(
        _ db: Database,
        message: CallMessage,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        let messageInfo: CallMessage.MessageInfo = CallMessage.MessageInfo(state: .missed)
        
        guard
            let caller: String = message.sender,
            let messageInfoData: Data = try? JSONEncoder(using: dependencies).encode(messageInfo),
            !SessionThread.isMessageRequest(db, threadId: caller, userSessionId: getUserSessionId(db, using: dependencies)),
            let thread: SessionThread = try SessionThread.fetchOne(db, id: caller)
        else { return }
        
        SNLog("[Calls] Sending end call message because there is an ongoing call.")
        
        let messageSentTimestamp: Int64 = (
            message.sentTimestamp.map { Int64($0) } ??
            SnodeAPI.currentOffsetTimestampMs()
        )
        _ = try Interaction(
            serverHash: message.serverHash,
            messageUuid: message.uuid,
            threadId: thread.id,
            authorId: caller,
            variant: .infoCall,
            body: String(data: messageInfoData, encoding: .utf8),
            timestampMs: messageSentTimestamp,
            wasRead: LibSession.timestampAlreadyRead(
                threadId: thread.id,
                threadVariant: thread.variant,
                timestampMs: (messageSentTimestamp * 1000),
                userSessionId: getUserSessionId(db, using: dependencies),
                openGroup: nil,
                using: dependencies
            )
        )
        .inserted(db)
        
        try MessageSender
            .preparedSend(
                db,
                message: CallMessage(
                    uuid: message.uuid,
                    kind: .endCall,
                    sdps: [],
                    sentTimestampMs: nil // Explicitly nil as it's a separate message from above
                ),
                to: try Message.Destination.from(db, threadId: thread.id, threadVariant: thread.variant),
                namespace: try Message.Destination
                    .from(db, threadId: thread.id, threadVariant: thread.variant)
                    .defaultNamespace,
                interactionId: nil,      // Explicitly nil as it's a separate message from above
                fileIds: [],
                using: dependencies
            )
            .send(using: dependencies)
            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
            .sinkUntilComplete()
    }
    
    @discardableResult public static func insertCallInfoMessage(
        _ db: Database,
        for message: CallMessage,
        state: CallMessage.MessageInfo.State? = nil,
        using dependencies: Dependencies = Dependencies()
    ) throws -> Interaction? {
        guard
            (try? Interaction
                .filter(Interaction.Columns.variant == Interaction.Variant.infoCall)
                .filter(Interaction.Columns.messageUuid == message.uuid)
                .isEmpty(db))
                .defaulting(to: false),
            let sender: String = message.sender,
            !SessionThread.isMessageRequest(db, threadId: sender, userSessionId: getUserSessionId(db, using: dependencies)),
            let thread: SessionThread = try SessionThread.fetchOne(db, id: sender)
        else { return nil }
        
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        let messageInfo: CallMessage.MessageInfo = CallMessage.MessageInfo(
            state: state.defaulting(
                to: (sender == userSessionId.hexString ?
                    .outgoing :
                    .incoming
                )
            )
        )
        let timestampMs: Int64 = (
            message.sentTimestamp.map { Int64($0) } ??
            SnodeAPI.currentOffsetTimestampMs(using: dependencies)
        )
        
        guard let messageInfoData: Data = try? JSONEncoder(using: dependencies).encode(messageInfo) else {
            return nil
        }
        
        return try Interaction(
            serverHash: message.serverHash,
            messageUuid: message.uuid,
            threadId: thread.id,
            authorId: sender,
            variant: .infoCall,
            body: String(data: messageInfoData, encoding: .utf8),
            timestampMs: timestampMs,
            wasRead: LibSession.timestampAlreadyRead(
                threadId: thread.id,
                threadVariant: thread.variant,
                timestampMs: (timestampMs * 1000),
                userSessionId: userSessionId,
                openGroup: nil,
                using: dependencies
            ),
            expiresInSeconds: message.expiresInSeconds,
            expiresStartedAtMs: message.expiresStartedAtMs
        ).inserted(db)
    }
}
