// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import WebRTC
import SessionUtilitiesKit

public protocol CurrentCallProtocol {
    var uuid: String { get }
    var callId: UUID { get }
    var sessionId: String { get }
    var hasStartedConnecting: Bool { get set }
    var hasEnded: Bool { get set }
    
    func updateCallMessage(mode: EndCallMode, using dependencies: Dependencies)
    func didReceiveRemoteSDP(sdp: RTCSessionDescription)
    func startSessionCall(_ db: Database)
}
