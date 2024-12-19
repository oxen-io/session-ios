// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import WebRTC
import Foundation
import SessionMessagingKit
import SessionUtilitiesKit

extension WebRTCSession: RTCDataChannelDelegate {
    // stringlint:ignore_contents
    internal func createDataChannel() -> RTCDataChannel? {
        let dataChannelConfiguration = RTCDataChannelConfiguration()
        dataChannelConfiguration.isOrdered = true
        dataChannelConfiguration.isNegotiated = true
        dataChannelConfiguration.channelId = 548
        guard let dataChannel = peerConnection?.dataChannel(forLabel: "CONTROL", configuration: dataChannelConfiguration) else {
            Log.error(.calls, "Couldn't create data channel.")
            return nil
        }
        return dataChannel
    }
    
    public func sendJSON(_ json: [String: Any]) {
        if let dataChannel = self.dataChannel, let jsonAsData = try? JSONSerialization.data(withJSONObject: json, options: [ .fragmentsAllowed ]) {
            Log.info(.calls, "Send json to data channel")
            let dataBuffer = RTCDataBuffer(data: jsonAsData, isBinary: false)
            dataChannel.sendData(dataBuffer)
        }
    }
    
    // MARK: Data channel delegate
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Log.info(.calls, "Data channel did change to \(dataChannel.readyState.rawValue)")
        if dataChannel.readyState == .open {
            delegate?.dataChannelDidOpen()
        }
    }
    
    // stringlint:ignore_contents
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        if let json: [String: Any] = try? JSONSerialization.jsonObject(with: buffer.data, options: [ .fragmentsAllowed ]) as? [String: Any] {
            Log.info(.calls, "Data channel did receive data: \(json)")
            if let isRemoteVideoEnabled = json["video"] as? Bool {
                delegate?.isRemoteVideoDidChange(isEnabled: isRemoteVideoEnabled)
            }
            if let _ = json["hangup"] {
                delegate?.didReceiveHangUpSignal()
            }
        }
    }
}
