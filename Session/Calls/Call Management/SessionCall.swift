// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import YYImage
import Combine
import CallKit
import GRDB
import WebRTC
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit
import SessionSnodeKit

public final class SessionCall: CurrentCallProtocol, WebRTCSessionDelegate {
    @objc static let isEnabled = true
    
    private let dependencies: Dependencies
    
    // MARK: - Metadata Properties
    public let uuid: String
    public let callId: UUID // This is for CallKit
    let sessionId: String
    let mode: CallMode
    var audioMode: AudioMode
    public let webRTCSession: WebRTCSession
    let isOutgoing: Bool
    var remoteSDP: RTCSessionDescription? = nil
    var callInteractionId: Int64?
    var answerCallAction: CXAnswerCallAction? = nil
    
    let contactName: String
    let profilePicture: UIImage
    let animatedProfilePicture: YYImage?
    
    // MARK: - Control
    
    lazy public var videoCapturer: RTCVideoCapturer = {
        return RTCCameraVideoCapturer(delegate: webRTCSession.localVideoSource)
    }()
    
    var isRemoteVideoEnabled = false {
        didSet {
            remoteVideoStateDidChange?(isRemoteVideoEnabled)
        }
    }
    
    var isMuted = false {
        willSet {
            if newValue {
                webRTCSession.mute()
            } else {
                webRTCSession.unmute()
            }
        }
    }
    var isVideoEnabled = false {
        willSet {
            if newValue {
                webRTCSession.turnOnVideo()
            } else {
                webRTCSession.turnOffVideo()
            }
        }
    }
    
    // MARK: - Audio I/O mode
    
    enum AudioMode {
        case earpiece
        case speaker
        case headphone
        case bluetooth
    }
    
    // MARK: - Call State Properties
    
    var connectingDate: Date? {
        didSet {
            stateDidChange?()
            resetTimeoutTimerIfNeeded()
            hasStartedConnectingDidChange?()
        }
    }

    var connectedDate: Date? {
        didSet {
            stateDidChange?()
            hasConnectedDidChange?()
        }
    }

    var endDate: Date? {
        didSet {
            stateDidChange?()
            hasEndedDidChange?()
        }
    }

    // Not yet implemented
    var isOnHold = false {
        didSet {
            stateDidChange?()
        }
    }

    // MARK: - State Change Callbacks
    
    var stateDidChange: (() -> Void)?
    var hasStartedConnectingDidChange: (() -> Void)?
    var hasConnectedDidChange: (() -> Void)?
    var hasEndedDidChange: (() -> Void)?
    var remoteVideoStateDidChange: ((Bool) -> Void)?
    var hasStartedReconnecting: (() -> Void)?
    var hasReconnected: (() -> Void)?
    
    // MARK: - Derived Properties
    
    public var hasStartedConnecting: Bool {
        get { return connectingDate != nil }
        set { connectingDate = newValue ? Date() : nil }
    }

    public var hasConnected: Bool {
        get { return connectedDate != nil }
        set { connectedDate = newValue ? Date() : nil }
    }

    public var hasEnded: Bool {
        get { return endDate != nil }
        set { endDate = newValue ? Date() : nil }
    }
    
    var timeOutTimer: Timer? = nil
    var didTimeout = false

    var duration: TimeInterval {
        guard let connectedDate = connectedDate else {
            return 0
        }
        if let endDate = endDate {
            return endDate.timeIntervalSince(connectedDate)
        }

        return Date().timeIntervalSince(connectedDate)
    }
    
    var reconnectTimer: Timer? = nil
    
    // MARK: - Initialization
    
    init(_ db: Database, for sessionId: String, uuid: String, mode: CallMode, outgoing: Bool = false, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.sessionId = sessionId
        self.uuid = uuid
        self.callId = UUID()
        self.mode = mode
        self.audioMode = .earpiece
        self.webRTCSession = WebRTCSession.current ?? WebRTCSession(for: sessionId, with: uuid)
        self.isOutgoing = outgoing
        
        let avatarData: Data? = DisplayPictureManager.displayPicture(db, id: .user(sessionId))
        self.contactName = Profile.displayName(db, id: sessionId, threadVariant: .contact)
        self.profilePicture = avatarData
            .map { UIImage(data: $0) }
            .defaulting(to: PlaceholderIcon.generate(seed: sessionId, text: self.contactName, size: 300))
        self.animatedProfilePicture = avatarData
            .map { data in
                switch data.guessedImageFormat {
                    case .gif, .webp: return YYImage(data: data)
                    default: return nil
                }
            }
        
        WebRTCSession.current = self.webRTCSession
        self.webRTCSession.delegate = self
        
        if dependencies[singleton: .callManager].currentCall == nil {
            dependencies[singleton: .callManager].setCurrentCall(self)
        }
        else {
            SNLog("[Calls] A call is ongoing.")
        }
    }
    
    func reportIncomingCallIfNeeded(completion: @escaping (Error?) -> Void) {
        guard case .answer = mode else {
            SessionCallManager.reportFakeCall(info: "Call not in answer mode")
            return
        }
        
        setupTimeoutTimer()
        dependencies[singleton: .callManager].reportIncomingCall(self, callerName: contactName) { error in
            completion(error)
        }
    }
    
    public func didReceiveRemoteSDP(sdp: RTCSessionDescription) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.didReceiveRemoteSDP(sdp: sdp)
            }
            return
        }
        
        SNLog("[Calls] Did receive remote sdp.")
        remoteSDP = sdp
        if hasStartedConnecting {
            webRTCSession.handleRemoteSDP(sdp, from: sessionId) // This sends an answer message internally
        }
    }
    
    // MARK: - Actions
    
    public func startSessionCall(_ db: Database) {
        let sessionId: String = self.sessionId
        let messageInfo: CallMessage.MessageInfo = CallMessage.MessageInfo(state: .outgoing)
        
        guard
            case .offer = mode,
            let messageInfoData: Data = try? JSONEncoder().encode(messageInfo),
            let thread: SessionThread = try? SessionThread.fetchOne(db, id: sessionId)
        else { return }
        
        let webRTCSession: WebRTCSession = self.webRTCSession
        let timestampMs: Int64 = SnodeAPI.currentOffsetTimestampMs()
        let message: CallMessage = CallMessage(
            uuid: self.uuid,
            kind: .preOffer,
            sdps: [],
            sentTimestampMs: UInt64(timestampMs)
        )
        let interaction: Interaction? = try? Interaction(
            messageUuid: self.uuid,
            threadId: sessionId,
            authorId: getUserSessionId(db).hexString,
            variant: .infoCall,
            body: String(data: messageInfoData, encoding: .utf8),
            timestampMs: timestampMs
        )
        .inserted(db)
        
        self.callInteractionId = interaction?.id
        
        try? webRTCSession
            .sendPreOffer(
                db,
                message: message,
                interactionId: interaction?.id,
                in: thread
            )
            // Start the timeout timer for the call
            .handleEvents(receiveOutput: { [weak self] _ in self?.setupTimeoutTimer() })
            .flatMap { _ in webRTCSession.sendOffer(to: thread) }
            .sinkUntilComplete()
    }
    
    func answerSessionCall() {
        guard case .answer = mode else { return }
        
        hasStartedConnecting = true
        
        if let sdp = remoteSDP {
            webRTCSession.handleRemoteSDP(sdp, from: sessionId) // This sends an answer message internally
        }
    }
    
    func answerSessionCallInBackground(action: CXAnswerCallAction) {
        answerCallAction = action
        self.answerSessionCall()
    }
    
    func endSessionCall() {
        guard !hasEnded else { return }
        
        let sessionId: String = self.sessionId
        
        webRTCSession.hangUp()
        
        dependencies[singleton: .storage].writeAsync { [weak self] db in
            try self?.webRTCSession.endCall(db, with: sessionId)
        }
        
        hasEnded = true
    }
    
    // MARK: - Call Message Handling
    
    public func updateCallMessage(mode: EndCallMode, using dependencies: Dependencies) {
        guard let callInteractionId: Int64 = callInteractionId else { return }
        
        let duration: TimeInterval = self.duration
        let hasStartedConnecting: Bool = self.hasStartedConnecting
        
        dependencies[singleton: .storage].writeAsync(
            updates: { db in
                guard let interaction: Interaction = try? Interaction.fetchOne(db, id: callInteractionId) else {
                    return
                }
                
                let updateToMissedIfNeeded: () throws -> () = {
                    let missedCallInfo: CallMessage.MessageInfo = CallMessage.MessageInfo(state: .missed)
                    
                    guard
                        let infoMessageData: Data = (interaction.body ?? "").data(using: .utf8),
                        let messageInfo: CallMessage.MessageInfo = try? JSONDecoder(using: dependencies).decode(
                            CallMessage.MessageInfo.self,
                            from: infoMessageData
                        ),
                        messageInfo.state == .incoming,
                        let missedCallInfoData: Data = try? JSONEncoder(using: dependencies)
                            .encode(missedCallInfo)
                    else { return }
                    
                    try interaction
                        .with(body: String(data: missedCallInfoData, encoding: .utf8))
                        .upserted(db)
                }
                let shouldMarkAsRead: Bool = try {
                    if duration > 0 { return true }
                    if hasStartedConnecting { return true }
                    
                    switch mode {
                        case .local:
                            try updateToMissedIfNeeded()
                            return true
                            
                        case .remote, .unanswered:
                            try updateToMissedIfNeeded()
                            return false
                            
                        case .answeredElsewhere: return true
                    }
                }()
                
                guard
                    shouldMarkAsRead,
                    let threadVariant: SessionThread.Variant = try? SessionThread
                        .filter(id: interaction.threadId)
                        .select(.variant)
                        .asRequest(of: SessionThread.Variant.self)
                        .fetchOne(db)
                else { return }
                
                try Interaction.markAsRead(
                    db,
                    interactionId: interaction.id,
                    threadId: interaction.threadId,
                    threadVariant: threadVariant,
                    includingOlder: false,
                    trySendReadReceipt: false,
                    using: dependencies
                )
            },
            completion: { [dependencies] _, _ in
                dependencies[singleton: .callManager].suspendDatabaseIfCallEndedInBackground()
            }
        )
    }
    
    // MARK: - Renderer
    
    func attachRemoteVideoRenderer(_ renderer: RTCVideoRenderer) {
        webRTCSession.attachRemoteRenderer(renderer)
    }
    
    func removeRemoteVideoRenderer(_ renderer: RTCVideoRenderer) {
        webRTCSession.removeRemoteRenderer(renderer)
    }
    
    func attachLocalVideoRenderer(_ renderer: RTCVideoRenderer) {
        webRTCSession.attachLocalRenderer(renderer)
    }
    
    func removeLocalVideoRenderer(_ renderer: RTCVideoRenderer) {
        webRTCSession.removeLocalRenderer(renderer)
    }
    
    // MARK: - Delegate
    
    public func webRTCIsConnected() {
        self.invalidateTimeoutTimer()
        self.reconnectTimer?.invalidate()
        
        guard !self.hasConnected else {
            hasReconnected?()
            return
        }
        
        self.hasConnected = true
        self.answerCallAction?.fulfill()
    }
    
    public func isRemoteVideoDidChange(isEnabled: Bool) {
        isRemoteVideoEnabled = isEnabled
    }
    
    public func didReceiveHangUpSignal() {
        self.hasEnded = true
        DispatchQueue.main.async { [dependencies] in
            if let currentBanner = IncomingCallBanner.current { currentBanner.dismiss() }
            guard dependencies.hasInitialised(singleton: .appContext) else { return }
            if let callVC = dependencies[singleton: .appContext].frontmostViewController as? CallVC { callVC.handleEndCallMessage() }
            if let miniCallView = MiniCallView.current { miniCallView.dismiss() }
            dependencies[singleton: .callManager].reportCurrentCallEnded(reason: .remoteEnded)
        }
    }
    
    public func dataChannelDidOpen() {
        // Send initial video status
        if (isVideoEnabled) {
            webRTCSession.turnOnVideo()
        } else {
            webRTCSession.turnOffVideo()
        }
    }
    
    public func reconnectIfNeeded() {
        setupTimeoutTimer()
        hasStartedReconnecting?()
        guard isOutgoing else { return }
        tryToReconnect()
    }
    
    private func tryToReconnect() {
        reconnectTimer?.invalidate()
        
        guard Environment.shared?.reachabilityManager.isReachable == true else {
            reconnectTimer = Timer.scheduledTimerOnMainThread(withTimeInterval: 5, repeats: false) { _ in
                self.tryToReconnect()
            }
            return
        }
        
        let sessionId: String = self.sessionId
        let webRTCSession: WebRTCSession = self.webRTCSession
        
        guard let thread: SessionThread = dependencies[singleton: .storage].read({ db in try SessionThread.fetchOne(db, id: sessionId) }) else {
            return
        }
        
        webRTCSession
            .sendOffer(to: thread, isRestartingICEConnection: true)
            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
            .sinkUntilComplete()
    }
    
    // MARK: - Timeout
    
    public func setupTimeoutTimer() {
        invalidateTimeoutTimer()
        
        let timeInterval: TimeInterval = 60
        
        timeOutTimer = Timer.scheduledTimerOnMainThread(withTimeInterval: timeInterval, repeats: false) { [weak self, dependencies] _ in
            self?.didTimeout = true
            
            dependencies[singleton: .callManager].endCall(self) { error in
                self?.timeOutTimer = nil
            }
        }
    }
    
    public func resetTimeoutTimerIfNeeded() {
        if self.timeOutTimer == nil { return }
        setupTimeoutTimer()
    }
    
    public func invalidateTimeoutTimer() {
        timeOutTimer?.invalidate()
        timeOutTimer = nil
    }
}
