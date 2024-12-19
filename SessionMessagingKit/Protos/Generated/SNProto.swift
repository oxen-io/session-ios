//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation

// WARNING: This code is generated. Only edit within the markers.

public enum SNProtoError: Error {
    case invalidProtobuf(description: String)
}

// MARK: - SNProtoEnvelope

@objc public class SNProtoEnvelope: NSObject {

    // MARK: - SNProtoEnvelopeType

    @objc public enum SNProtoEnvelopeType: Int32 {
        case sessionMessage = 6
        case closedGroupMessage = 7
    }

    private class func SNProtoEnvelopeTypeWrap(_ value: SessionProtos_Envelope.TypeEnum) -> SNProtoEnvelopeType {
        switch value {
        case .sessionMessage: return .sessionMessage
        case .closedGroupMessage: return .closedGroupMessage
        }
    }

    private class func SNProtoEnvelopeTypeUnwrap(_ value: SNProtoEnvelopeType) -> SessionProtos_Envelope.TypeEnum {
        switch value {
        case .sessionMessage: return .sessionMessage
        case .closedGroupMessage: return .closedGroupMessage
        }
    }

    // MARK: - SNProtoEnvelopeBuilder

    @objc public class func builder(type: SNProtoEnvelopeType, timestamp: UInt64) -> SNProtoEnvelopeBuilder {
        return SNProtoEnvelopeBuilder(type: type, timestamp: timestamp)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoEnvelopeBuilder {
        let builder = SNProtoEnvelopeBuilder(type: type, timestamp: timestamp)
        if let _value = source {
            builder.setSource(_value)
        }
        if hasSourceDevice {
            builder.setSourceDevice(sourceDevice)
        }
        if let _value = content {
            builder.setContent(_value)
        }
        if hasServerTimestamp {
            builder.setServerTimestamp(serverTimestamp)
        }
        return builder
    }

    @objc public class SNProtoEnvelopeBuilder: NSObject {

        private var proto = SessionProtos_Envelope()

        @objc fileprivate override init() {}

        @objc fileprivate init(type: SNProtoEnvelopeType, timestamp: UInt64) {
            super.init()

            setType(type)
            setTimestamp(timestamp)
        }

        @objc public func setType(_ valueParam: SNProtoEnvelopeType) {
            proto.type = SNProtoEnvelopeTypeUnwrap(valueParam)
        }

        @objc public func setSource(_ valueParam: String) {
            proto.source = valueParam
        }

        @objc public func setSourceDevice(_ valueParam: UInt32) {
            proto.sourceDevice = valueParam
        }

        @objc public func setTimestamp(_ valueParam: UInt64) {
            proto.timestamp = valueParam
        }

        @objc public func setContent(_ valueParam: Data) {
            proto.content = valueParam
        }

        @objc public func setServerTimestamp(_ valueParam: UInt64) {
            proto.serverTimestamp = valueParam
        }

        @objc public func build() throws -> SNProtoEnvelope {
            return try SNProtoEnvelope.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoEnvelope.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_Envelope

    @objc public let type: SNProtoEnvelopeType

    @objc public let timestamp: UInt64

    @objc public var source: String? {
        guard proto.hasSource else {
            return nil
        }
        return proto.source
    }
    @objc public var hasSource: Bool {
        return proto.hasSource
    }

    @objc public var sourceDevice: UInt32 {
        return proto.sourceDevice
    }
    @objc public var hasSourceDevice: Bool {
        return proto.hasSourceDevice
    }

    @objc public var content: Data? {
        guard proto.hasContent else {
            return nil
        }
        return proto.content
    }
    @objc public var hasContent: Bool {
        return proto.hasContent
    }

    @objc public var serverTimestamp: UInt64 {
        return proto.serverTimestamp
    }
    @objc public var hasServerTimestamp: Bool {
        return proto.hasServerTimestamp
    }

    private init(proto: SessionProtos_Envelope,
                 type: SNProtoEnvelopeType,
                 timestamp: UInt64) {
        self.proto = proto
        self.type = type
        self.timestamp = timestamp
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoEnvelope {
        let proto = try SessionProtos_Envelope(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_Envelope) throws -> SNProtoEnvelope {
        guard proto.hasType else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: type")
        }
        let type = SNProtoEnvelopeTypeWrap(proto.type)

        guard proto.hasTimestamp else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: timestamp")
        }
        let timestamp = proto.timestamp

        // MARK: - Begin Validation Logic for SNProtoEnvelope -

        // MARK: - End Validation Logic for SNProtoEnvelope -

        let result = SNProtoEnvelope(proto: proto,
                                     type: type,
                                     timestamp: timestamp)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoEnvelope {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoEnvelope.SNProtoEnvelopeBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoEnvelope? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoTypingMessage

@objc public class SNProtoTypingMessage: NSObject {

    // MARK: - SNProtoTypingMessageAction

    @objc public enum SNProtoTypingMessageAction: Int32 {
        case started = 0
        case stopped = 1
    }

    private class func SNProtoTypingMessageActionWrap(_ value: SessionProtos_TypingMessage.Action) -> SNProtoTypingMessageAction {
        switch value {
        case .started: return .started
        case .stopped: return .stopped
        }
    }

    private class func SNProtoTypingMessageActionUnwrap(_ value: SNProtoTypingMessageAction) -> SessionProtos_TypingMessage.Action {
        switch value {
        case .started: return .started
        case .stopped: return .stopped
        }
    }

    // MARK: - SNProtoTypingMessageBuilder

    @objc public class func builder(timestamp: UInt64, action: SNProtoTypingMessageAction) -> SNProtoTypingMessageBuilder {
        return SNProtoTypingMessageBuilder(timestamp: timestamp, action: action)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoTypingMessageBuilder {
        let builder = SNProtoTypingMessageBuilder(timestamp: timestamp, action: action)
        return builder
    }

    @objc public class SNProtoTypingMessageBuilder: NSObject {

        private var proto = SessionProtos_TypingMessage()

        @objc fileprivate override init() {}

        @objc fileprivate init(timestamp: UInt64, action: SNProtoTypingMessageAction) {
            super.init()

            setTimestamp(timestamp)
            setAction(action)
        }

        @objc public func setTimestamp(_ valueParam: UInt64) {
            proto.timestamp = valueParam
        }

        @objc public func setAction(_ valueParam: SNProtoTypingMessageAction) {
            proto.action = SNProtoTypingMessageActionUnwrap(valueParam)
        }

        @objc public func build() throws -> SNProtoTypingMessage {
            return try SNProtoTypingMessage.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoTypingMessage.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_TypingMessage

    @objc public let timestamp: UInt64

    @objc public let action: SNProtoTypingMessageAction

    private init(proto: SessionProtos_TypingMessage,
                 timestamp: UInt64,
                 action: SNProtoTypingMessageAction) {
        self.proto = proto
        self.timestamp = timestamp
        self.action = action
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoTypingMessage {
        let proto = try SessionProtos_TypingMessage(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_TypingMessage) throws -> SNProtoTypingMessage {
        guard proto.hasTimestamp else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: timestamp")
        }
        let timestamp = proto.timestamp

        guard proto.hasAction else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: action")
        }
        let action = SNProtoTypingMessageActionWrap(proto.action)

        // MARK: - Begin Validation Logic for SNProtoTypingMessage -

        // MARK: - End Validation Logic for SNProtoTypingMessage -

        let result = SNProtoTypingMessage(proto: proto,
                                          timestamp: timestamp,
                                          action: action)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoTypingMessage {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoTypingMessage.SNProtoTypingMessageBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoTypingMessage? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoUnsendRequest

@objc public class SNProtoUnsendRequest: NSObject {

    // MARK: - SNProtoUnsendRequestBuilder

    @objc public class func builder(timestamp: UInt64, author: String) -> SNProtoUnsendRequestBuilder {
        return SNProtoUnsendRequestBuilder(timestamp: timestamp, author: author)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoUnsendRequestBuilder {
        let builder = SNProtoUnsendRequestBuilder(timestamp: timestamp, author: author)
        return builder
    }

    @objc public class SNProtoUnsendRequestBuilder: NSObject {

        private var proto = SessionProtos_UnsendRequest()

        @objc fileprivate override init() {}

        @objc fileprivate init(timestamp: UInt64, author: String) {
            super.init()

            setTimestamp(timestamp)
            setAuthor(author)
        }

        @objc public func setTimestamp(_ valueParam: UInt64) {
            proto.timestamp = valueParam
        }

        @objc public func setAuthor(_ valueParam: String) {
            proto.author = valueParam
        }

        @objc public func build() throws -> SNProtoUnsendRequest {
            return try SNProtoUnsendRequest.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoUnsendRequest.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_UnsendRequest

    @objc public let timestamp: UInt64

    @objc public let author: String

    private init(proto: SessionProtos_UnsendRequest,
                 timestamp: UInt64,
                 author: String) {
        self.proto = proto
        self.timestamp = timestamp
        self.author = author
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoUnsendRequest {
        let proto = try SessionProtos_UnsendRequest(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_UnsendRequest) throws -> SNProtoUnsendRequest {
        guard proto.hasTimestamp else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: timestamp")
        }
        let timestamp = proto.timestamp

        guard proto.hasAuthor else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: author")
        }
        let author = proto.author

        // MARK: - Begin Validation Logic for SNProtoUnsendRequest -

        // MARK: - End Validation Logic for SNProtoUnsendRequest -

        let result = SNProtoUnsendRequest(proto: proto,
                                          timestamp: timestamp,
                                          author: author)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoUnsendRequest {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoUnsendRequest.SNProtoUnsendRequestBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoUnsendRequest? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoMessageRequestResponse

@objc public class SNProtoMessageRequestResponse: NSObject {

    // MARK: - SNProtoMessageRequestResponseBuilder

    @objc public class func builder(isApproved: Bool) -> SNProtoMessageRequestResponseBuilder {
        return SNProtoMessageRequestResponseBuilder(isApproved: isApproved)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoMessageRequestResponseBuilder {
        let builder = SNProtoMessageRequestResponseBuilder(isApproved: isApproved)
        if let _value = profileKey {
            builder.setProfileKey(_value)
        }
        if let _value = profile {
            builder.setProfile(_value)
        }
        return builder
    }

    @objc public class SNProtoMessageRequestResponseBuilder: NSObject {

        private var proto = SessionProtos_MessageRequestResponse()

        @objc fileprivate override init() {}

        @objc fileprivate init(isApproved: Bool) {
            super.init()

            setIsApproved(isApproved)
        }

        @objc public func setIsApproved(_ valueParam: Bool) {
            proto.isApproved = valueParam
        }

        @objc public func setProfileKey(_ valueParam: Data) {
            proto.profileKey = valueParam
        }

        @objc public func setProfile(_ valueParam: SNProtoLokiProfile) {
            proto.profile = valueParam.proto
        }

        @objc public func build() throws -> SNProtoMessageRequestResponse {
            return try SNProtoMessageRequestResponse.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoMessageRequestResponse.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_MessageRequestResponse

    @objc public let isApproved: Bool

    @objc public let profile: SNProtoLokiProfile?

    @objc public var profileKey: Data? {
        guard proto.hasProfileKey else {
            return nil
        }
        return proto.profileKey
    }
    @objc public var hasProfileKey: Bool {
        return proto.hasProfileKey
    }

    private init(proto: SessionProtos_MessageRequestResponse,
                 isApproved: Bool,
                 profile: SNProtoLokiProfile?) {
        self.proto = proto
        self.isApproved = isApproved
        self.profile = profile
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoMessageRequestResponse {
        let proto = try SessionProtos_MessageRequestResponse(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_MessageRequestResponse) throws -> SNProtoMessageRequestResponse {
        guard proto.hasIsApproved else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: isApproved")
        }
        let isApproved = proto.isApproved

        var profile: SNProtoLokiProfile? = nil
        if proto.hasProfile {
            profile = try SNProtoLokiProfile.parseProto(proto.profile)
        }

        // MARK: - Begin Validation Logic for SNProtoMessageRequestResponse -

        // MARK: - End Validation Logic for SNProtoMessageRequestResponse -

        let result = SNProtoMessageRequestResponse(proto: proto,
                                                   isApproved: isApproved,
                                                   profile: profile)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoMessageRequestResponse {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoMessageRequestResponse.SNProtoMessageRequestResponseBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoMessageRequestResponse? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoContent

@objc public class SNProtoContent: NSObject {

    // MARK: - SNProtoContentExpirationType

    @objc public enum SNProtoContentExpirationType: Int32 {
        case unknown = 0
        case deleteAfterRead = 1
        case deleteAfterSend = 2
    }

    private class func SNProtoContentExpirationTypeWrap(_ value: SessionProtos_Content.ExpirationType) -> SNProtoContentExpirationType {
        switch value {
        case .unknown: return .unknown
        case .deleteAfterRead: return .deleteAfterRead
        case .deleteAfterSend: return .deleteAfterSend
        }
    }

    private class func SNProtoContentExpirationTypeUnwrap(_ value: SNProtoContentExpirationType) -> SessionProtos_Content.ExpirationType {
        switch value {
        case .unknown: return .unknown
        case .deleteAfterRead: return .deleteAfterRead
        case .deleteAfterSend: return .deleteAfterSend
        }
    }

    // MARK: - SNProtoContentBuilder

    @objc public class func builder() -> SNProtoContentBuilder {
        return SNProtoContentBuilder()
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoContentBuilder {
        let builder = SNProtoContentBuilder()
        if let _value = dataMessage {
            builder.setDataMessage(_value)
        }
        if let _value = callMessage {
            builder.setCallMessage(_value)
        }
        if let _value = receiptMessage {
            builder.setReceiptMessage(_value)
        }
        if let _value = typingMessage {
            builder.setTypingMessage(_value)
        }
        if let _value = dataExtractionNotification {
            builder.setDataExtractionNotification(_value)
        }
        if let _value = unsendRequest {
            builder.setUnsendRequest(_value)
        }
        if let _value = messageRequestResponse {
            builder.setMessageRequestResponse(_value)
        }
        if hasExpirationType {
            builder.setExpirationType(expirationType)
        }
        if hasExpirationTimer {
            builder.setExpirationTimer(expirationTimer)
        }
        return builder
    }

    @objc public class SNProtoContentBuilder: NSObject {

        private var proto = SessionProtos_Content()

        @objc fileprivate override init() {}

        @objc public func setDataMessage(_ valueParam: SNProtoDataMessage) {
            proto.dataMessage = valueParam.proto
        }

        @objc public func setCallMessage(_ valueParam: SNProtoCallMessage) {
            proto.callMessage = valueParam.proto
        }

        @objc public func setReceiptMessage(_ valueParam: SNProtoReceiptMessage) {
            proto.receiptMessage = valueParam.proto
        }

        @objc public func setTypingMessage(_ valueParam: SNProtoTypingMessage) {
            proto.typingMessage = valueParam.proto
        }

        @objc public func setDataExtractionNotification(_ valueParam: SNProtoDataExtractionNotification) {
            proto.dataExtractionNotification = valueParam.proto
        }

        @objc public func setUnsendRequest(_ valueParam: SNProtoUnsendRequest) {
            proto.unsendRequest = valueParam.proto
        }

        @objc public func setMessageRequestResponse(_ valueParam: SNProtoMessageRequestResponse) {
            proto.messageRequestResponse = valueParam.proto
        }

        @objc public func setExpirationType(_ valueParam: SNProtoContentExpirationType) {
            proto.expirationType = SNProtoContentExpirationTypeUnwrap(valueParam)
        }

        @objc public func setExpirationTimer(_ valueParam: UInt32) {
            proto.expirationTimer = valueParam
        }

        @objc public func build() throws -> SNProtoContent {
            return try SNProtoContent.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoContent.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_Content

    @objc public let dataMessage: SNProtoDataMessage?

    @objc public let callMessage: SNProtoCallMessage?

    @objc public let receiptMessage: SNProtoReceiptMessage?

    @objc public let typingMessage: SNProtoTypingMessage?

    @objc public let dataExtractionNotification: SNProtoDataExtractionNotification?

    @objc public let unsendRequest: SNProtoUnsendRequest?

    @objc public let messageRequestResponse: SNProtoMessageRequestResponse?

    @objc public var expirationType: SNProtoContentExpirationType {
        return SNProtoContent.SNProtoContentExpirationTypeWrap(proto.expirationType)
    }
    @objc public var hasExpirationType: Bool {
        return proto.hasExpirationType
    }

    @objc public var expirationTimer: UInt32 {
        return proto.expirationTimer
    }
    @objc public var hasExpirationTimer: Bool {
        return proto.hasExpirationTimer
    }

    private init(proto: SessionProtos_Content,
                 dataMessage: SNProtoDataMessage?,
                 callMessage: SNProtoCallMessage?,
                 receiptMessage: SNProtoReceiptMessage?,
                 typingMessage: SNProtoTypingMessage?,
                 dataExtractionNotification: SNProtoDataExtractionNotification?,
                 unsendRequest: SNProtoUnsendRequest?,
                 messageRequestResponse: SNProtoMessageRequestResponse?) {
        self.proto = proto
        self.dataMessage = dataMessage
        self.callMessage = callMessage
        self.receiptMessage = receiptMessage
        self.typingMessage = typingMessage
        self.dataExtractionNotification = dataExtractionNotification
        self.unsendRequest = unsendRequest
        self.messageRequestResponse = messageRequestResponse
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoContent {
        let proto = try SessionProtos_Content(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_Content) throws -> SNProtoContent {
        var dataMessage: SNProtoDataMessage? = nil
        if proto.hasDataMessage {
            dataMessage = try SNProtoDataMessage.parseProto(proto.dataMessage)
        }

        var callMessage: SNProtoCallMessage? = nil
        if proto.hasCallMessage {
            callMessage = try SNProtoCallMessage.parseProto(proto.callMessage)
        }

        var receiptMessage: SNProtoReceiptMessage? = nil
        if proto.hasReceiptMessage {
            receiptMessage = try SNProtoReceiptMessage.parseProto(proto.receiptMessage)
        }

        var typingMessage: SNProtoTypingMessage? = nil
        if proto.hasTypingMessage {
            typingMessage = try SNProtoTypingMessage.parseProto(proto.typingMessage)
        }

        var dataExtractionNotification: SNProtoDataExtractionNotification? = nil
        if proto.hasDataExtractionNotification {
            dataExtractionNotification = try SNProtoDataExtractionNotification.parseProto(proto.dataExtractionNotification)
        }

        var unsendRequest: SNProtoUnsendRequest? = nil
        if proto.hasUnsendRequest {
            unsendRequest = try SNProtoUnsendRequest.parseProto(proto.unsendRequest)
        }

        var messageRequestResponse: SNProtoMessageRequestResponse? = nil
        if proto.hasMessageRequestResponse {
            messageRequestResponse = try SNProtoMessageRequestResponse.parseProto(proto.messageRequestResponse)
        }

        // MARK: - Begin Validation Logic for SNProtoContent -

        // MARK: - End Validation Logic for SNProtoContent -

        let result = SNProtoContent(proto: proto,
                                    dataMessage: dataMessage,
                                    callMessage: callMessage,
                                    receiptMessage: receiptMessage,
                                    typingMessage: typingMessage,
                                    dataExtractionNotification: dataExtractionNotification,
                                    unsendRequest: unsendRequest,
                                    messageRequestResponse: messageRequestResponse)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoContent {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoContent.SNProtoContentBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoContent? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoCallMessage

@objc public class SNProtoCallMessage: NSObject {

    // MARK: - SNProtoCallMessageType

    @objc public enum SNProtoCallMessageType: Int32 {
        case offer = 1
        case answer = 2
        case provisionalAnswer = 3
        case iceCandidates = 4
        case endCall = 5
        case preOffer = 6
    }

    private class func SNProtoCallMessageTypeWrap(_ value: SessionProtos_CallMessage.TypeEnum) -> SNProtoCallMessageType {
        switch value {
        case .offer: return .offer
        case .answer: return .answer
        case .provisionalAnswer: return .provisionalAnswer
        case .iceCandidates: return .iceCandidates
        case .endCall: return .endCall
        case .preOffer: return .preOffer
        }
    }

    private class func SNProtoCallMessageTypeUnwrap(_ value: SNProtoCallMessageType) -> SessionProtos_CallMessage.TypeEnum {
        switch value {
        case .offer: return .offer
        case .answer: return .answer
        case .provisionalAnswer: return .provisionalAnswer
        case .iceCandidates: return .iceCandidates
        case .endCall: return .endCall
        case .preOffer: return .preOffer
        }
    }

    // MARK: - SNProtoCallMessageBuilder

    @objc public class func builder(type: SNProtoCallMessageType, uuid: String) -> SNProtoCallMessageBuilder {
        return SNProtoCallMessageBuilder(type: type, uuid: uuid)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoCallMessageBuilder {
        let builder = SNProtoCallMessageBuilder(type: type, uuid: uuid)
        builder.setSdps(sdps)
        builder.setSdpMlineIndexes(sdpMlineIndexes)
        builder.setSdpMids(sdpMids)
        return builder
    }

    @objc public class SNProtoCallMessageBuilder: NSObject {

        private var proto = SessionProtos_CallMessage()

        @objc fileprivate override init() {}

        @objc fileprivate init(type: SNProtoCallMessageType, uuid: String) {
            super.init()

            setType(type)
            setUuid(uuid)
        }

        @objc public func setType(_ valueParam: SNProtoCallMessageType) {
            proto.type = SNProtoCallMessageTypeUnwrap(valueParam)
        }

        @objc public func addSdps(_ valueParam: String) {
            var items = proto.sdps
            items.append(valueParam)
            proto.sdps = items
        }

        @objc public func setSdps(_ wrappedItems: [String]) {
            proto.sdps = wrappedItems
        }

        @objc public func addSdpMlineIndexes(_ valueParam: UInt32) {
            var items = proto.sdpMlineIndexes
            items.append(valueParam)
            proto.sdpMlineIndexes = items
        }

        @objc public func setSdpMlineIndexes(_ wrappedItems: [UInt32]) {
            proto.sdpMlineIndexes = wrappedItems
        }

        @objc public func addSdpMids(_ valueParam: String) {
            var items = proto.sdpMids
            items.append(valueParam)
            proto.sdpMids = items
        }

        @objc public func setSdpMids(_ wrappedItems: [String]) {
            proto.sdpMids = wrappedItems
        }

        @objc public func setUuid(_ valueParam: String) {
            proto.uuid = valueParam
        }

        @objc public func build() throws -> SNProtoCallMessage {
            return try SNProtoCallMessage.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoCallMessage.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_CallMessage

    @objc public let type: SNProtoCallMessageType

    @objc public let uuid: String

    @objc public var sdps: [String] {
        return proto.sdps
    }

    @objc public var sdpMlineIndexes: [UInt32] {
        return proto.sdpMlineIndexes
    }

    @objc public var sdpMids: [String] {
        return proto.sdpMids
    }

    private init(proto: SessionProtos_CallMessage,
                 type: SNProtoCallMessageType,
                 uuid: String) {
        self.proto = proto
        self.type = type
        self.uuid = uuid
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoCallMessage {
        let proto = try SessionProtos_CallMessage(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_CallMessage) throws -> SNProtoCallMessage {
        guard proto.hasType else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: type")
        }
        let type = SNProtoCallMessageTypeWrap(proto.type)

        guard proto.hasUuid else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: uuid")
        }
        let uuid = proto.uuid

        // MARK: - Begin Validation Logic for SNProtoCallMessage -

        // MARK: - End Validation Logic for SNProtoCallMessage -

        let result = SNProtoCallMessage(proto: proto,
                                        type: type,
                                        uuid: uuid)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoCallMessage {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoCallMessage.SNProtoCallMessageBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoCallMessage? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoKeyPair

@objc public class SNProtoKeyPair: NSObject {

    // MARK: - SNProtoKeyPairBuilder

    @objc public class func builder(publicKey: Data, privateKey: Data) -> SNProtoKeyPairBuilder {
        return SNProtoKeyPairBuilder(publicKey: publicKey, privateKey: privateKey)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoKeyPairBuilder {
        let builder = SNProtoKeyPairBuilder(publicKey: publicKey, privateKey: privateKey)
        return builder
    }

    @objc public class SNProtoKeyPairBuilder: NSObject {

        private var proto = SessionProtos_KeyPair()

        @objc fileprivate override init() {}

        @objc fileprivate init(publicKey: Data, privateKey: Data) {
            super.init()

            setPublicKey(publicKey)
            setPrivateKey(privateKey)
        }

        @objc public func setPublicKey(_ valueParam: Data) {
            proto.publicKey = valueParam
        }

        @objc public func setPrivateKey(_ valueParam: Data) {
            proto.privateKey = valueParam
        }

        @objc public func build() throws -> SNProtoKeyPair {
            return try SNProtoKeyPair.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoKeyPair.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_KeyPair

    @objc public let publicKey: Data

    @objc public let privateKey: Data

    private init(proto: SessionProtos_KeyPair,
                 publicKey: Data,
                 privateKey: Data) {
        self.proto = proto
        self.publicKey = publicKey
        self.privateKey = privateKey
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoKeyPair {
        let proto = try SessionProtos_KeyPair(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_KeyPair) throws -> SNProtoKeyPair {
        guard proto.hasPublicKey else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: publicKey")
        }
        let publicKey = proto.publicKey

        guard proto.hasPrivateKey else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: privateKey")
        }
        let privateKey = proto.privateKey

        // MARK: - Begin Validation Logic for SNProtoKeyPair -

        // MARK: - End Validation Logic for SNProtoKeyPair -

        let result = SNProtoKeyPair(proto: proto,
                                    publicKey: publicKey,
                                    privateKey: privateKey)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoKeyPair {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoKeyPair.SNProtoKeyPairBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoKeyPair? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoDataExtractionNotification

@objc public class SNProtoDataExtractionNotification: NSObject {

    // MARK: - SNProtoDataExtractionNotificationType

    @objc public enum SNProtoDataExtractionNotificationType: Int32 {
        case screenshot = 1
        case mediaSaved = 2
    }

    private class func SNProtoDataExtractionNotificationTypeWrap(_ value: SessionProtos_DataExtractionNotification.TypeEnum) -> SNProtoDataExtractionNotificationType {
        switch value {
        case .screenshot: return .screenshot
        case .mediaSaved: return .mediaSaved
        }
    }

    private class func SNProtoDataExtractionNotificationTypeUnwrap(_ value: SNProtoDataExtractionNotificationType) -> SessionProtos_DataExtractionNotification.TypeEnum {
        switch value {
        case .screenshot: return .screenshot
        case .mediaSaved: return .mediaSaved
        }
    }

    // MARK: - SNProtoDataExtractionNotificationBuilder

    @objc public class func builder(type: SNProtoDataExtractionNotificationType) -> SNProtoDataExtractionNotificationBuilder {
        return SNProtoDataExtractionNotificationBuilder(type: type)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoDataExtractionNotificationBuilder {
        let builder = SNProtoDataExtractionNotificationBuilder(type: type)
        if hasTimestamp {
            builder.setTimestamp(timestamp)
        }
        return builder
    }

    @objc public class SNProtoDataExtractionNotificationBuilder: NSObject {

        private var proto = SessionProtos_DataExtractionNotification()

        @objc fileprivate override init() {}

        @objc fileprivate init(type: SNProtoDataExtractionNotificationType) {
            super.init()

            setType(type)
        }

        @objc public func setType(_ valueParam: SNProtoDataExtractionNotificationType) {
            proto.type = SNProtoDataExtractionNotificationTypeUnwrap(valueParam)
        }

        @objc public func setTimestamp(_ valueParam: UInt64) {
            proto.timestamp = valueParam
        }

        @objc public func build() throws -> SNProtoDataExtractionNotification {
            return try SNProtoDataExtractionNotification.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoDataExtractionNotification.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_DataExtractionNotification

    @objc public let type: SNProtoDataExtractionNotificationType

    @objc public var timestamp: UInt64 {
        return proto.timestamp
    }
    @objc public var hasTimestamp: Bool {
        return proto.hasTimestamp
    }

    private init(proto: SessionProtos_DataExtractionNotification,
                 type: SNProtoDataExtractionNotificationType) {
        self.proto = proto
        self.type = type
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoDataExtractionNotification {
        let proto = try SessionProtos_DataExtractionNotification(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_DataExtractionNotification) throws -> SNProtoDataExtractionNotification {
        guard proto.hasType else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: type")
        }
        let type = SNProtoDataExtractionNotificationTypeWrap(proto.type)

        // MARK: - Begin Validation Logic for SNProtoDataExtractionNotification -

        // MARK: - End Validation Logic for SNProtoDataExtractionNotification -

        let result = SNProtoDataExtractionNotification(proto: proto,
                                                       type: type)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoDataExtractionNotification {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoDataExtractionNotification.SNProtoDataExtractionNotificationBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoDataExtractionNotification? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoLokiProfile

@objc public class SNProtoLokiProfile: NSObject {

    // MARK: - SNProtoLokiProfileBuilder

    @objc public class func builder() -> SNProtoLokiProfileBuilder {
        return SNProtoLokiProfileBuilder()
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoLokiProfileBuilder {
        let builder = SNProtoLokiProfileBuilder()
        if let _value = displayName {
            builder.setDisplayName(_value)
        }
        if let _value = profilePicture {
            builder.setProfilePicture(_value)
        }
        return builder
    }

    @objc public class SNProtoLokiProfileBuilder: NSObject {

        private var proto = SessionProtos_LokiProfile()

        @objc fileprivate override init() {}

        @objc public func setDisplayName(_ valueParam: String) {
            proto.displayName = valueParam
        }

        @objc public func setProfilePicture(_ valueParam: String) {
            proto.profilePicture = valueParam
        }

        @objc public func build() throws -> SNProtoLokiProfile {
            return try SNProtoLokiProfile.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoLokiProfile.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_LokiProfile

    @objc public var displayName: String? {
        guard proto.hasDisplayName else {
            return nil
        }
        return proto.displayName
    }
    @objc public var hasDisplayName: Bool {
        return proto.hasDisplayName
    }

    @objc public var profilePicture: String? {
        guard proto.hasProfilePicture else {
            return nil
        }
        return proto.profilePicture
    }
    @objc public var hasProfilePicture: Bool {
        return proto.hasProfilePicture
    }

    private init(proto: SessionProtos_LokiProfile) {
        self.proto = proto
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoLokiProfile {
        let proto = try SessionProtos_LokiProfile(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_LokiProfile) throws -> SNProtoLokiProfile {
        // MARK: - Begin Validation Logic for SNProtoLokiProfile -

        // MARK: - End Validation Logic for SNProtoLokiProfile -

        let result = SNProtoLokiProfile(proto: proto)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoLokiProfile {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoLokiProfile.SNProtoLokiProfileBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoLokiProfile? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoDataMessageQuoteQuotedAttachment

@objc public class SNProtoDataMessageQuoteQuotedAttachment: NSObject {

    // MARK: - SNProtoDataMessageQuoteQuotedAttachmentFlags

    @objc public enum SNProtoDataMessageQuoteQuotedAttachmentFlags: Int32 {
        case voiceMessage = 1
    }

    private class func SNProtoDataMessageQuoteQuotedAttachmentFlagsWrap(_ value: SessionProtos_DataMessage.Quote.QuotedAttachment.Flags) -> SNProtoDataMessageQuoteQuotedAttachmentFlags {
        switch value {
        case .voiceMessage: return .voiceMessage
        }
    }

    private class func SNProtoDataMessageQuoteQuotedAttachmentFlagsUnwrap(_ value: SNProtoDataMessageQuoteQuotedAttachmentFlags) -> SessionProtos_DataMessage.Quote.QuotedAttachment.Flags {
        switch value {
        case .voiceMessage: return .voiceMessage
        }
    }

    // MARK: - SNProtoDataMessageQuoteQuotedAttachmentBuilder

    @objc public class func builder() -> SNProtoDataMessageQuoteQuotedAttachmentBuilder {
        return SNProtoDataMessageQuoteQuotedAttachmentBuilder()
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoDataMessageQuoteQuotedAttachmentBuilder {
        let builder = SNProtoDataMessageQuoteQuotedAttachmentBuilder()
        if let _value = contentType {
            builder.setContentType(_value)
        }
        if let _value = fileName {
            builder.setFileName(_value)
        }
        if let _value = thumbnail {
            builder.setThumbnail(_value)
        }
        if hasFlags {
            builder.setFlags(flags)
        }
        return builder
    }

    @objc public class SNProtoDataMessageQuoteQuotedAttachmentBuilder: NSObject {

        private var proto = SessionProtos_DataMessage.Quote.QuotedAttachment()

        @objc fileprivate override init() {}

        @objc public func setContentType(_ valueParam: String) {
            proto.contentType = valueParam
        }

        @objc public func setFileName(_ valueParam: String) {
            proto.fileName = valueParam
        }

        @objc public func setThumbnail(_ valueParam: SNProtoAttachmentPointer) {
            proto.thumbnail = valueParam.proto
        }

        @objc public func setFlags(_ valueParam: UInt32) {
            proto.flags = valueParam
        }

        @objc public func build() throws -> SNProtoDataMessageQuoteQuotedAttachment {
            return try SNProtoDataMessageQuoteQuotedAttachment.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoDataMessageQuoteQuotedAttachment.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_DataMessage.Quote.QuotedAttachment

    @objc public let thumbnail: SNProtoAttachmentPointer?

    @objc public var contentType: String? {
        guard proto.hasContentType else {
            return nil
        }
        return proto.contentType
    }
    @objc public var hasContentType: Bool {
        return proto.hasContentType
    }

    @objc public var fileName: String? {
        guard proto.hasFileName else {
            return nil
        }
        return proto.fileName
    }
    @objc public var hasFileName: Bool {
        return proto.hasFileName
    }

    @objc public var flags: UInt32 {
        return proto.flags
    }
    @objc public var hasFlags: Bool {
        return proto.hasFlags
    }

    private init(proto: SessionProtos_DataMessage.Quote.QuotedAttachment,
                 thumbnail: SNProtoAttachmentPointer?) {
        self.proto = proto
        self.thumbnail = thumbnail
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoDataMessageQuoteQuotedAttachment {
        let proto = try SessionProtos_DataMessage.Quote.QuotedAttachment(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_DataMessage.Quote.QuotedAttachment) throws -> SNProtoDataMessageQuoteQuotedAttachment {
        var thumbnail: SNProtoAttachmentPointer? = nil
        if proto.hasThumbnail {
            thumbnail = try SNProtoAttachmentPointer.parseProto(proto.thumbnail)
        }

        // MARK: - Begin Validation Logic for SNProtoDataMessageQuoteQuotedAttachment -

        // MARK: - End Validation Logic for SNProtoDataMessageQuoteQuotedAttachment -

        let result = SNProtoDataMessageQuoteQuotedAttachment(proto: proto,
                                                             thumbnail: thumbnail)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoDataMessageQuoteQuotedAttachment {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoDataMessageQuoteQuotedAttachment.SNProtoDataMessageQuoteQuotedAttachmentBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoDataMessageQuoteQuotedAttachment? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoDataMessageQuote

@objc public class SNProtoDataMessageQuote: NSObject {

    // MARK: - SNProtoDataMessageQuoteBuilder

    @objc public class func builder(id: UInt64, author: String) -> SNProtoDataMessageQuoteBuilder {
        return SNProtoDataMessageQuoteBuilder(id: id, author: author)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoDataMessageQuoteBuilder {
        let builder = SNProtoDataMessageQuoteBuilder(id: id, author: author)
        if let _value = text {
            builder.setText(_value)
        }
        builder.setAttachments(attachments)
        return builder
    }

    @objc public class SNProtoDataMessageQuoteBuilder: NSObject {

        private var proto = SessionProtos_DataMessage.Quote()

        @objc fileprivate override init() {}

        @objc fileprivate init(id: UInt64, author: String) {
            super.init()

            setId(id)
            setAuthor(author)
        }

        @objc public func setId(_ valueParam: UInt64) {
            proto.id = valueParam
        }

        @objc public func setAuthor(_ valueParam: String) {
            proto.author = valueParam
        }

        @objc public func setText(_ valueParam: String) {
            proto.text = valueParam
        }

        @objc public func addAttachments(_ valueParam: SNProtoDataMessageQuoteQuotedAttachment) {
            var items = proto.attachments
            items.append(valueParam.proto)
            proto.attachments = items
        }

        @objc public func setAttachments(_ wrappedItems: [SNProtoDataMessageQuoteQuotedAttachment]) {
            proto.attachments = wrappedItems.map { $0.proto }
        }

        @objc public func build() throws -> SNProtoDataMessageQuote {
            return try SNProtoDataMessageQuote.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoDataMessageQuote.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_DataMessage.Quote

    @objc public let id: UInt64

    @objc public let author: String

    @objc public let attachments: [SNProtoDataMessageQuoteQuotedAttachment]

    @objc public var text: String? {
        guard proto.hasText else {
            return nil
        }
        return proto.text
    }
    @objc public var hasText: Bool {
        return proto.hasText
    }

    private init(proto: SessionProtos_DataMessage.Quote,
                 id: UInt64,
                 author: String,
                 attachments: [SNProtoDataMessageQuoteQuotedAttachment]) {
        self.proto = proto
        self.id = id
        self.author = author
        self.attachments = attachments
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoDataMessageQuote {
        let proto = try SessionProtos_DataMessage.Quote(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_DataMessage.Quote) throws -> SNProtoDataMessageQuote {
        guard proto.hasID else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: id")
        }
        let id = proto.id

        guard proto.hasAuthor else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: author")
        }
        let author = proto.author

        var attachments: [SNProtoDataMessageQuoteQuotedAttachment] = []
        attachments = try proto.attachments.map { try SNProtoDataMessageQuoteQuotedAttachment.parseProto($0) }

        // MARK: - Begin Validation Logic for SNProtoDataMessageQuote -

        // MARK: - End Validation Logic for SNProtoDataMessageQuote -

        let result = SNProtoDataMessageQuote(proto: proto,
                                             id: id,
                                             author: author,
                                             attachments: attachments)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoDataMessageQuote {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoDataMessageQuote.SNProtoDataMessageQuoteBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoDataMessageQuote? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoDataMessagePreview

@objc public class SNProtoDataMessagePreview: NSObject {

    // MARK: - SNProtoDataMessagePreviewBuilder

    @objc public class func builder(url: String) -> SNProtoDataMessagePreviewBuilder {
        return SNProtoDataMessagePreviewBuilder(url: url)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoDataMessagePreviewBuilder {
        let builder = SNProtoDataMessagePreviewBuilder(url: url)
        if let _value = title {
            builder.setTitle(_value)
        }
        if let _value = image {
            builder.setImage(_value)
        }
        return builder
    }

    @objc public class SNProtoDataMessagePreviewBuilder: NSObject {

        private var proto = SessionProtos_DataMessage.Preview()

        @objc fileprivate override init() {}

        @objc fileprivate init(url: String) {
            super.init()

            setUrl(url)
        }

        @objc public func setUrl(_ valueParam: String) {
            proto.url = valueParam
        }

        @objc public func setTitle(_ valueParam: String) {
            proto.title = valueParam
        }

        @objc public func setImage(_ valueParam: SNProtoAttachmentPointer) {
            proto.image = valueParam.proto
        }

        @objc public func build() throws -> SNProtoDataMessagePreview {
            return try SNProtoDataMessagePreview.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoDataMessagePreview.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_DataMessage.Preview

    @objc public let url: String

    @objc public let image: SNProtoAttachmentPointer?

    @objc public var title: String? {
        guard proto.hasTitle else {
            return nil
        }
        return proto.title
    }
    @objc public var hasTitle: Bool {
        return proto.hasTitle
    }

    private init(proto: SessionProtos_DataMessage.Preview,
                 url: String,
                 image: SNProtoAttachmentPointer?) {
        self.proto = proto
        self.url = url
        self.image = image
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoDataMessagePreview {
        let proto = try SessionProtos_DataMessage.Preview(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_DataMessage.Preview) throws -> SNProtoDataMessagePreview {
        guard proto.hasURL else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: url")
        }
        let url = proto.url

        var image: SNProtoAttachmentPointer? = nil
        if proto.hasImage {
            image = try SNProtoAttachmentPointer.parseProto(proto.image)
        }

        // MARK: - Begin Validation Logic for SNProtoDataMessagePreview -

        // MARK: - End Validation Logic for SNProtoDataMessagePreview -

        let result = SNProtoDataMessagePreview(proto: proto,
                                               url: url,
                                               image: image)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoDataMessagePreview {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoDataMessagePreview.SNProtoDataMessagePreviewBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoDataMessagePreview? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoDataMessageReaction

@objc public class SNProtoDataMessageReaction: NSObject {

    // MARK: - SNProtoDataMessageReactionAction

    @objc public enum SNProtoDataMessageReactionAction: Int32 {
        case react = 0
        case remove = 1
    }

    private class func SNProtoDataMessageReactionActionWrap(_ value: SessionProtos_DataMessage.Reaction.Action) -> SNProtoDataMessageReactionAction {
        switch value {
        case .react: return .react
        case .remove: return .remove
        }
    }

    private class func SNProtoDataMessageReactionActionUnwrap(_ value: SNProtoDataMessageReactionAction) -> SessionProtos_DataMessage.Reaction.Action {
        switch value {
        case .react: return .react
        case .remove: return .remove
        }
    }

    // MARK: - SNProtoDataMessageReactionBuilder

    @objc public class func builder(id: UInt64, author: String, action: SNProtoDataMessageReactionAction) -> SNProtoDataMessageReactionBuilder {
        return SNProtoDataMessageReactionBuilder(id: id, author: author, action: action)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoDataMessageReactionBuilder {
        let builder = SNProtoDataMessageReactionBuilder(id: id, author: author, action: action)
        if let _value = emoji {
            builder.setEmoji(_value)
        }
        return builder
    }

    @objc public class SNProtoDataMessageReactionBuilder: NSObject {

        private var proto = SessionProtos_DataMessage.Reaction()

        @objc fileprivate override init() {}

        @objc fileprivate init(id: UInt64, author: String, action: SNProtoDataMessageReactionAction) {
            super.init()

            setId(id)
            setAuthor(author)
            setAction(action)
        }

        @objc public func setId(_ valueParam: UInt64) {
            proto.id = valueParam
        }

        @objc public func setAuthor(_ valueParam: String) {
            proto.author = valueParam
        }

        @objc public func setEmoji(_ valueParam: String) {
            proto.emoji = valueParam
        }

        @objc public func setAction(_ valueParam: SNProtoDataMessageReactionAction) {
            proto.action = SNProtoDataMessageReactionActionUnwrap(valueParam)
        }

        @objc public func build() throws -> SNProtoDataMessageReaction {
            return try SNProtoDataMessageReaction.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoDataMessageReaction.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_DataMessage.Reaction

    @objc public let id: UInt64

    @objc public let author: String

    @objc public let action: SNProtoDataMessageReactionAction

    @objc public var emoji: String? {
        guard proto.hasEmoji else {
            return nil
        }
        return proto.emoji
    }
    @objc public var hasEmoji: Bool {
        return proto.hasEmoji
    }

    private init(proto: SessionProtos_DataMessage.Reaction,
                 id: UInt64,
                 author: String,
                 action: SNProtoDataMessageReactionAction) {
        self.proto = proto
        self.id = id
        self.author = author
        self.action = action
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoDataMessageReaction {
        let proto = try SessionProtos_DataMessage.Reaction(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_DataMessage.Reaction) throws -> SNProtoDataMessageReaction {
        guard proto.hasID else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: id")
        }
        let id = proto.id

        guard proto.hasAuthor else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: author")
        }
        let author = proto.author

        guard proto.hasAction else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: action")
        }
        let action = SNProtoDataMessageReactionActionWrap(proto.action)

        // MARK: - Begin Validation Logic for SNProtoDataMessageReaction -

        // MARK: - End Validation Logic for SNProtoDataMessageReaction -

        let result = SNProtoDataMessageReaction(proto: proto,
                                                id: id,
                                                author: author,
                                                action: action)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoDataMessageReaction {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoDataMessageReaction.SNProtoDataMessageReactionBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoDataMessageReaction? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoDataMessageOpenGroupInvitation

@objc public class SNProtoDataMessageOpenGroupInvitation: NSObject {

    // MARK: - SNProtoDataMessageOpenGroupInvitationBuilder

    @objc public class func builder(url: String, name: String) -> SNProtoDataMessageOpenGroupInvitationBuilder {
        return SNProtoDataMessageOpenGroupInvitationBuilder(url: url, name: name)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoDataMessageOpenGroupInvitationBuilder {
        let builder = SNProtoDataMessageOpenGroupInvitationBuilder(url: url, name: name)
        return builder
    }

    @objc public class SNProtoDataMessageOpenGroupInvitationBuilder: NSObject {

        private var proto = SessionProtos_DataMessage.OpenGroupInvitation()

        @objc fileprivate override init() {}

        @objc fileprivate init(url: String, name: String) {
            super.init()

            setUrl(url)
            setName(name)
        }

        @objc public func setUrl(_ valueParam: String) {
            proto.url = valueParam
        }

        @objc public func setName(_ valueParam: String) {
            proto.name = valueParam
        }

        @objc public func build() throws -> SNProtoDataMessageOpenGroupInvitation {
            return try SNProtoDataMessageOpenGroupInvitation.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoDataMessageOpenGroupInvitation.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_DataMessage.OpenGroupInvitation

    @objc public let url: String

    @objc public let name: String

    private init(proto: SessionProtos_DataMessage.OpenGroupInvitation,
                 url: String,
                 name: String) {
        self.proto = proto
        self.url = url
        self.name = name
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoDataMessageOpenGroupInvitation {
        let proto = try SessionProtos_DataMessage.OpenGroupInvitation(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_DataMessage.OpenGroupInvitation) throws -> SNProtoDataMessageOpenGroupInvitation {
        guard proto.hasURL else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: url")
        }
        let url = proto.url

        guard proto.hasName else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: name")
        }
        let name = proto.name

        // MARK: - Begin Validation Logic for SNProtoDataMessageOpenGroupInvitation -

        // MARK: - End Validation Logic for SNProtoDataMessageOpenGroupInvitation -

        let result = SNProtoDataMessageOpenGroupInvitation(proto: proto,
                                                           url: url,
                                                           name: name)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoDataMessageOpenGroupInvitation {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoDataMessageOpenGroupInvitation.SNProtoDataMessageOpenGroupInvitationBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoDataMessageOpenGroupInvitation? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper

@objc public class SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper: NSObject {

    // MARK: - SNProtoDataMessageClosedGroupControlMessageKeyPairWrapperBuilder

    @objc public class func builder(publicKey: Data, encryptedKeyPair: Data) -> SNProtoDataMessageClosedGroupControlMessageKeyPairWrapperBuilder {
        return SNProtoDataMessageClosedGroupControlMessageKeyPairWrapperBuilder(publicKey: publicKey, encryptedKeyPair: encryptedKeyPair)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoDataMessageClosedGroupControlMessageKeyPairWrapperBuilder {
        let builder = SNProtoDataMessageClosedGroupControlMessageKeyPairWrapperBuilder(publicKey: publicKey, encryptedKeyPair: encryptedKeyPair)
        return builder
    }

    @objc public class SNProtoDataMessageClosedGroupControlMessageKeyPairWrapperBuilder: NSObject {

        private var proto = SessionProtos_DataMessage.ClosedGroupControlMessage.KeyPairWrapper()

        @objc fileprivate override init() {}

        @objc fileprivate init(publicKey: Data, encryptedKeyPair: Data) {
            super.init()

            setPublicKey(publicKey)
            setEncryptedKeyPair(encryptedKeyPair)
        }

        @objc public func setPublicKey(_ valueParam: Data) {
            proto.publicKey = valueParam
        }

        @objc public func setEncryptedKeyPair(_ valueParam: Data) {
            proto.encryptedKeyPair = valueParam
        }

        @objc public func build() throws -> SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper {
            return try SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_DataMessage.ClosedGroupControlMessage.KeyPairWrapper

    @objc public let publicKey: Data

    @objc public let encryptedKeyPair: Data

    private init(proto: SessionProtos_DataMessage.ClosedGroupControlMessage.KeyPairWrapper,
                 publicKey: Data,
                 encryptedKeyPair: Data) {
        self.proto = proto
        self.publicKey = publicKey
        self.encryptedKeyPair = encryptedKeyPair
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper {
        let proto = try SessionProtos_DataMessage.ClosedGroupControlMessage.KeyPairWrapper(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_DataMessage.ClosedGroupControlMessage.KeyPairWrapper) throws -> SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper {
        guard proto.hasPublicKey else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: publicKey")
        }
        let publicKey = proto.publicKey

        guard proto.hasEncryptedKeyPair else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: encryptedKeyPair")
        }
        let encryptedKeyPair = proto.encryptedKeyPair

        // MARK: - Begin Validation Logic for SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper -

        // MARK: - End Validation Logic for SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper -

        let result = SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper(proto: proto,
                                                                               publicKey: publicKey,
                                                                               encryptedKeyPair: encryptedKeyPair)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper.SNProtoDataMessageClosedGroupControlMessageKeyPairWrapperBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoDataMessageClosedGroupControlMessage

@objc public class SNProtoDataMessageClosedGroupControlMessage: NSObject {

    // MARK: - SNProtoDataMessageClosedGroupControlMessageType

    @objc public enum SNProtoDataMessageClosedGroupControlMessageType: Int32 {
        case new = 1
        case encryptionKeyPair = 3
        case nameChange = 4
        case membersAdded = 5
        case membersRemoved = 6
        case memberLeft = 7
        case encryptionKeyPairRequest = 8
    }

    private class func SNProtoDataMessageClosedGroupControlMessageTypeWrap(_ value: SessionProtos_DataMessage.ClosedGroupControlMessage.TypeEnum) -> SNProtoDataMessageClosedGroupControlMessageType {
        switch value {
        case .new: return .new
        case .encryptionKeyPair: return .encryptionKeyPair
        case .nameChange: return .nameChange
        case .membersAdded: return .membersAdded
        case .membersRemoved: return .membersRemoved
        case .memberLeft: return .memberLeft
        case .encryptionKeyPairRequest: return .encryptionKeyPairRequest
        }
    }

    private class func SNProtoDataMessageClosedGroupControlMessageTypeUnwrap(_ value: SNProtoDataMessageClosedGroupControlMessageType) -> SessionProtos_DataMessage.ClosedGroupControlMessage.TypeEnum {
        switch value {
        case .new: return .new
        case .encryptionKeyPair: return .encryptionKeyPair
        case .nameChange: return .nameChange
        case .membersAdded: return .membersAdded
        case .membersRemoved: return .membersRemoved
        case .memberLeft: return .memberLeft
        case .encryptionKeyPairRequest: return .encryptionKeyPairRequest
        }
    }

    // MARK: - SNProtoDataMessageClosedGroupControlMessageBuilder

    @objc public class func builder(type: SNProtoDataMessageClosedGroupControlMessageType) -> SNProtoDataMessageClosedGroupControlMessageBuilder {
        return SNProtoDataMessageClosedGroupControlMessageBuilder(type: type)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoDataMessageClosedGroupControlMessageBuilder {
        let builder = SNProtoDataMessageClosedGroupControlMessageBuilder(type: type)
        if let _value = publicKey {
            builder.setPublicKey(_value)
        }
        if let _value = name {
            builder.setName(_value)
        }
        if let _value = encryptionKeyPair {
            builder.setEncryptionKeyPair(_value)
        }
        builder.setMembers(members)
        builder.setAdmins(admins)
        builder.setWrappers(wrappers)
        if hasExpirationTimer {
            builder.setExpirationTimer(expirationTimer)
        }
        return builder
    }

    @objc public class SNProtoDataMessageClosedGroupControlMessageBuilder: NSObject {

        private var proto = SessionProtos_DataMessage.ClosedGroupControlMessage()

        @objc fileprivate override init() {}

        @objc fileprivate init(type: SNProtoDataMessageClosedGroupControlMessageType) {
            super.init()

            setType(type)
        }

        @objc public func setType(_ valueParam: SNProtoDataMessageClosedGroupControlMessageType) {
            proto.type = SNProtoDataMessageClosedGroupControlMessageTypeUnwrap(valueParam)
        }

        @objc public func setPublicKey(_ valueParam: Data) {
            proto.publicKey = valueParam
        }

        @objc public func setName(_ valueParam: String) {
            proto.name = valueParam
        }

        @objc public func setEncryptionKeyPair(_ valueParam: SNProtoKeyPair) {
            proto.encryptionKeyPair = valueParam.proto
        }

        @objc public func addMembers(_ valueParam: Data) {
            var items = proto.members
            items.append(valueParam)
            proto.members = items
        }

        @objc public func setMembers(_ wrappedItems: [Data]) {
            proto.members = wrappedItems
        }

        @objc public func addAdmins(_ valueParam: Data) {
            var items = proto.admins
            items.append(valueParam)
            proto.admins = items
        }

        @objc public func setAdmins(_ wrappedItems: [Data]) {
            proto.admins = wrappedItems
        }

        @objc public func addWrappers(_ valueParam: SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper) {
            var items = proto.wrappers
            items.append(valueParam.proto)
            proto.wrappers = items
        }

        @objc public func setWrappers(_ wrappedItems: [SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper]) {
            proto.wrappers = wrappedItems.map { $0.proto }
        }

        @objc public func setExpirationTimer(_ valueParam: UInt32) {
            proto.expirationTimer = valueParam
        }

        @objc public func build() throws -> SNProtoDataMessageClosedGroupControlMessage {
            return try SNProtoDataMessageClosedGroupControlMessage.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoDataMessageClosedGroupControlMessage.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_DataMessage.ClosedGroupControlMessage

    @objc public let type: SNProtoDataMessageClosedGroupControlMessageType

    @objc public let encryptionKeyPair: SNProtoKeyPair?

    @objc public let wrappers: [SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper]

    @objc public var publicKey: Data? {
        guard proto.hasPublicKey else {
            return nil
        }
        return proto.publicKey
    }
    @objc public var hasPublicKey: Bool {
        return proto.hasPublicKey
    }

    @objc public var name: String? {
        guard proto.hasName else {
            return nil
        }
        return proto.name
    }
    @objc public var hasName: Bool {
        return proto.hasName
    }

    @objc public var members: [Data] {
        return proto.members
    }

    @objc public var admins: [Data] {
        return proto.admins
    }

    @objc public var expirationTimer: UInt32 {
        return proto.expirationTimer
    }
    @objc public var hasExpirationTimer: Bool {
        return proto.hasExpirationTimer
    }

    private init(proto: SessionProtos_DataMessage.ClosedGroupControlMessage,
                 type: SNProtoDataMessageClosedGroupControlMessageType,
                 encryptionKeyPair: SNProtoKeyPair?,
                 wrappers: [SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper]) {
        self.proto = proto
        self.type = type
        self.encryptionKeyPair = encryptionKeyPair
        self.wrappers = wrappers
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoDataMessageClosedGroupControlMessage {
        let proto = try SessionProtos_DataMessage.ClosedGroupControlMessage(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_DataMessage.ClosedGroupControlMessage) throws -> SNProtoDataMessageClosedGroupControlMessage {
        guard proto.hasType else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: type")
        }
        let type = SNProtoDataMessageClosedGroupControlMessageTypeWrap(proto.type)

        var encryptionKeyPair: SNProtoKeyPair? = nil
        if proto.hasEncryptionKeyPair {
            encryptionKeyPair = try SNProtoKeyPair.parseProto(proto.encryptionKeyPair)
        }

        var wrappers: [SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper] = []
        wrappers = try proto.wrappers.map { try SNProtoDataMessageClosedGroupControlMessageKeyPairWrapper.parseProto($0) }

        // MARK: - Begin Validation Logic for SNProtoDataMessageClosedGroupControlMessage -

        // MARK: - End Validation Logic for SNProtoDataMessageClosedGroupControlMessage -

        let result = SNProtoDataMessageClosedGroupControlMessage(proto: proto,
                                                                 type: type,
                                                                 encryptionKeyPair: encryptionKeyPair,
                                                                 wrappers: wrappers)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoDataMessageClosedGroupControlMessage {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoDataMessageClosedGroupControlMessage.SNProtoDataMessageClosedGroupControlMessageBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoDataMessageClosedGroupControlMessage? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoDataMessage

@objc public class SNProtoDataMessage: NSObject {

    // MARK: - SNProtoDataMessageFlags

    @objc public enum SNProtoDataMessageFlags: Int32 {
        case expirationTimerUpdate = 2
    }

    private class func SNProtoDataMessageFlagsWrap(_ value: SessionProtos_DataMessage.Flags) -> SNProtoDataMessageFlags {
        switch value {
        case .expirationTimerUpdate: return .expirationTimerUpdate
        }
    }

    private class func SNProtoDataMessageFlagsUnwrap(_ value: SNProtoDataMessageFlags) -> SessionProtos_DataMessage.Flags {
        switch value {
        case .expirationTimerUpdate: return .expirationTimerUpdate
        }
    }

    // MARK: - SNProtoDataMessageBuilder

    @objc public class func builder() -> SNProtoDataMessageBuilder {
        return SNProtoDataMessageBuilder()
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoDataMessageBuilder {
        let builder = SNProtoDataMessageBuilder()
        if let _value = body {
            builder.setBody(_value)
        }
        builder.setAttachments(attachments)
        if hasFlags {
            builder.setFlags(flags)
        }
        if let _value = profileKey {
            builder.setProfileKey(_value)
        }
        if hasTimestamp {
            builder.setTimestamp(timestamp)
        }
        if let _value = quote {
            builder.setQuote(_value)
        }
        builder.setPreview(preview)
        if let _value = reaction {
            builder.setReaction(_value)
        }
        if let _value = profile {
            builder.setProfile(_value)
        }
        if let _value = openGroupInvitation {
            builder.setOpenGroupInvitation(_value)
        }
        if let _value = closedGroupControlMessage {
            builder.setClosedGroupControlMessage(_value)
        }
        if let _value = syncTarget {
            builder.setSyncTarget(_value)
        }
        if hasBlocksCommunityMessageRequests {
            builder.setBlocksCommunityMessageRequests(blocksCommunityMessageRequests)
        }
        if let _value = groupUpdateMessage {
            builder.setGroupUpdateMessage(_value)
        }
        return builder
    }

    @objc public class SNProtoDataMessageBuilder: NSObject {

        private var proto = SessionProtos_DataMessage()

        @objc fileprivate override init() {}

        @objc public func setBody(_ valueParam: String) {
            proto.body = valueParam
        }

        @objc public func addAttachments(_ valueParam: SNProtoAttachmentPointer) {
            var items = proto.attachments
            items.append(valueParam.proto)
            proto.attachments = items
        }

        @objc public func setAttachments(_ wrappedItems: [SNProtoAttachmentPointer]) {
            proto.attachments = wrappedItems.map { $0.proto }
        }

        @objc public func setFlags(_ valueParam: UInt32) {
            proto.flags = valueParam
        }

        @objc public func setProfileKey(_ valueParam: Data) {
            proto.profileKey = valueParam
        }

        @objc public func setTimestamp(_ valueParam: UInt64) {
            proto.timestamp = valueParam
        }

        @objc public func setQuote(_ valueParam: SNProtoDataMessageQuote) {
            proto.quote = valueParam.proto
        }

        @objc public func addPreview(_ valueParam: SNProtoDataMessagePreview) {
            var items = proto.preview
            items.append(valueParam.proto)
            proto.preview = items
        }

        @objc public func setPreview(_ wrappedItems: [SNProtoDataMessagePreview]) {
            proto.preview = wrappedItems.map { $0.proto }
        }

        @objc public func setReaction(_ valueParam: SNProtoDataMessageReaction) {
            proto.reaction = valueParam.proto
        }

        @objc public func setProfile(_ valueParam: SNProtoLokiProfile) {
            proto.profile = valueParam.proto
        }

        @objc public func setOpenGroupInvitation(_ valueParam: SNProtoDataMessageOpenGroupInvitation) {
            proto.openGroupInvitation = valueParam.proto
        }

        @objc public func setClosedGroupControlMessage(_ valueParam: SNProtoDataMessageClosedGroupControlMessage) {
            proto.closedGroupControlMessage = valueParam.proto
        }

        @objc public func setSyncTarget(_ valueParam: String) {
            proto.syncTarget = valueParam
        }

        @objc public func setBlocksCommunityMessageRequests(_ valueParam: Bool) {
            proto.blocksCommunityMessageRequests = valueParam
        }

        @objc public func setGroupUpdateMessage(_ valueParam: SNProtoGroupUpdateMessage) {
            proto.groupUpdateMessage = valueParam.proto
        }

        @objc public func build() throws -> SNProtoDataMessage {
            return try SNProtoDataMessage.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoDataMessage.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_DataMessage

    @objc public let attachments: [SNProtoAttachmentPointer]

    @objc public let quote: SNProtoDataMessageQuote?

    @objc public let preview: [SNProtoDataMessagePreview]

    @objc public let reaction: SNProtoDataMessageReaction?

    @objc public let profile: SNProtoLokiProfile?

    @objc public let openGroupInvitation: SNProtoDataMessageOpenGroupInvitation?

    @objc public let closedGroupControlMessage: SNProtoDataMessageClosedGroupControlMessage?

    @objc public let groupUpdateMessage: SNProtoGroupUpdateMessage?

    @objc public var body: String? {
        guard proto.hasBody else {
            return nil
        }
        return proto.body
    }
    @objc public var hasBody: Bool {
        return proto.hasBody
    }

    @objc public var flags: UInt32 {
        return proto.flags
    }
    @objc public var hasFlags: Bool {
        return proto.hasFlags
    }

    @objc public var profileKey: Data? {
        guard proto.hasProfileKey else {
            return nil
        }
        return proto.profileKey
    }
    @objc public var hasProfileKey: Bool {
        return proto.hasProfileKey
    }

    @objc public var timestamp: UInt64 {
        return proto.timestamp
    }
    @objc public var hasTimestamp: Bool {
        return proto.hasTimestamp
    }

    @objc public var syncTarget: String? {
        guard proto.hasSyncTarget else {
            return nil
        }
        return proto.syncTarget
    }
    @objc public var hasSyncTarget: Bool {
        return proto.hasSyncTarget
    }

    @objc public var blocksCommunityMessageRequests: Bool {
        return proto.blocksCommunityMessageRequests
    }
    @objc public var hasBlocksCommunityMessageRequests: Bool {
        return proto.hasBlocksCommunityMessageRequests
    }

    private init(proto: SessionProtos_DataMessage,
                 attachments: [SNProtoAttachmentPointer],
                 quote: SNProtoDataMessageQuote?,
                 preview: [SNProtoDataMessagePreview],
                 reaction: SNProtoDataMessageReaction?,
                 profile: SNProtoLokiProfile?,
                 openGroupInvitation: SNProtoDataMessageOpenGroupInvitation?,
                 closedGroupControlMessage: SNProtoDataMessageClosedGroupControlMessage?,
                 groupUpdateMessage: SNProtoGroupUpdateMessage?) {
        self.proto = proto
        self.attachments = attachments
        self.quote = quote
        self.preview = preview
        self.reaction = reaction
        self.profile = profile
        self.openGroupInvitation = openGroupInvitation
        self.closedGroupControlMessage = closedGroupControlMessage
        self.groupUpdateMessage = groupUpdateMessage
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoDataMessage {
        let proto = try SessionProtos_DataMessage(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_DataMessage) throws -> SNProtoDataMessage {
        var attachments: [SNProtoAttachmentPointer] = []
        attachments = try proto.attachments.map { try SNProtoAttachmentPointer.parseProto($0) }

        var quote: SNProtoDataMessageQuote? = nil
        if proto.hasQuote {
            quote = try SNProtoDataMessageQuote.parseProto(proto.quote)
        }

        var preview: [SNProtoDataMessagePreview] = []
        preview = try proto.preview.map { try SNProtoDataMessagePreview.parseProto($0) }

        var reaction: SNProtoDataMessageReaction? = nil
        if proto.hasReaction {
            reaction = try SNProtoDataMessageReaction.parseProto(proto.reaction)
        }

        var profile: SNProtoLokiProfile? = nil
        if proto.hasProfile {
            profile = try SNProtoLokiProfile.parseProto(proto.profile)
        }

        var openGroupInvitation: SNProtoDataMessageOpenGroupInvitation? = nil
        if proto.hasOpenGroupInvitation {
            openGroupInvitation = try SNProtoDataMessageOpenGroupInvitation.parseProto(proto.openGroupInvitation)
        }

        var closedGroupControlMessage: SNProtoDataMessageClosedGroupControlMessage? = nil
        if proto.hasClosedGroupControlMessage {
            closedGroupControlMessage = try SNProtoDataMessageClosedGroupControlMessage.parseProto(proto.closedGroupControlMessage)
        }

        var groupUpdateMessage: SNProtoGroupUpdateMessage? = nil
        if proto.hasGroupUpdateMessage {
            groupUpdateMessage = try SNProtoGroupUpdateMessage.parseProto(proto.groupUpdateMessage)
        }

        // MARK: - Begin Validation Logic for SNProtoDataMessage -

        // MARK: - End Validation Logic for SNProtoDataMessage -

        let result = SNProtoDataMessage(proto: proto,
                                        attachments: attachments,
                                        quote: quote,
                                        preview: preview,
                                        reaction: reaction,
                                        profile: profile,
                                        openGroupInvitation: openGroupInvitation,
                                        closedGroupControlMessage: closedGroupControlMessage,
                                        groupUpdateMessage: groupUpdateMessage)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoDataMessage {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoDataMessage.SNProtoDataMessageBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoDataMessage? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoReceiptMessage

@objc public class SNProtoReceiptMessage: NSObject {

    // MARK: - SNProtoReceiptMessageType

    @objc public enum SNProtoReceiptMessageType: Int32 {
        case delivery = 0
        case read = 1
    }

    private class func SNProtoReceiptMessageTypeWrap(_ value: SessionProtos_ReceiptMessage.TypeEnum) -> SNProtoReceiptMessageType {
        switch value {
        case .delivery: return .delivery
        case .read: return .read
        }
    }

    private class func SNProtoReceiptMessageTypeUnwrap(_ value: SNProtoReceiptMessageType) -> SessionProtos_ReceiptMessage.TypeEnum {
        switch value {
        case .delivery: return .delivery
        case .read: return .read
        }
    }

    // MARK: - SNProtoReceiptMessageBuilder

    @objc public class func builder(type: SNProtoReceiptMessageType) -> SNProtoReceiptMessageBuilder {
        return SNProtoReceiptMessageBuilder(type: type)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoReceiptMessageBuilder {
        let builder = SNProtoReceiptMessageBuilder(type: type)
        builder.setTimestamp(timestamp)
        return builder
    }

    @objc public class SNProtoReceiptMessageBuilder: NSObject {

        private var proto = SessionProtos_ReceiptMessage()

        @objc fileprivate override init() {}

        @objc fileprivate init(type: SNProtoReceiptMessageType) {
            super.init()

            setType(type)
        }

        @objc public func setType(_ valueParam: SNProtoReceiptMessageType) {
            proto.type = SNProtoReceiptMessageTypeUnwrap(valueParam)
        }

        @objc public func addTimestamp(_ valueParam: UInt64) {
            var items = proto.timestamp
            items.append(valueParam)
            proto.timestamp = items
        }

        @objc public func setTimestamp(_ wrappedItems: [UInt64]) {
            proto.timestamp = wrappedItems
        }

        @objc public func build() throws -> SNProtoReceiptMessage {
            return try SNProtoReceiptMessage.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoReceiptMessage.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_ReceiptMessage

    @objc public let type: SNProtoReceiptMessageType

    @objc public var timestamp: [UInt64] {
        return proto.timestamp
    }

    private init(proto: SessionProtos_ReceiptMessage,
                 type: SNProtoReceiptMessageType) {
        self.proto = proto
        self.type = type
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoReceiptMessage {
        let proto = try SessionProtos_ReceiptMessage(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_ReceiptMessage) throws -> SNProtoReceiptMessage {
        guard proto.hasType else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: type")
        }
        let type = SNProtoReceiptMessageTypeWrap(proto.type)

        // MARK: - Begin Validation Logic for SNProtoReceiptMessage -

        // MARK: - End Validation Logic for SNProtoReceiptMessage -

        let result = SNProtoReceiptMessage(proto: proto,
                                           type: type)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoReceiptMessage {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoReceiptMessage.SNProtoReceiptMessageBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoReceiptMessage? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoAttachmentPointer

@objc public class SNProtoAttachmentPointer: NSObject {

    // MARK: - SNProtoAttachmentPointerFlags

    @objc public enum SNProtoAttachmentPointerFlags: Int32 {
        case voiceMessage = 1
    }

    private class func SNProtoAttachmentPointerFlagsWrap(_ value: SessionProtos_AttachmentPointer.Flags) -> SNProtoAttachmentPointerFlags {
        switch value {
        case .voiceMessage: return .voiceMessage
        }
    }

    private class func SNProtoAttachmentPointerFlagsUnwrap(_ value: SNProtoAttachmentPointerFlags) -> SessionProtos_AttachmentPointer.Flags {
        switch value {
        case .voiceMessage: return .voiceMessage
        }
    }

    // MARK: - SNProtoAttachmentPointerBuilder

    @objc public class func builder(id: UInt64) -> SNProtoAttachmentPointerBuilder {
        return SNProtoAttachmentPointerBuilder(id: id)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoAttachmentPointerBuilder {
        let builder = SNProtoAttachmentPointerBuilder(id: id)
        if let _value = contentType {
            builder.setContentType(_value)
        }
        if let _value = key {
            builder.setKey(_value)
        }
        if hasSize {
            builder.setSize(size)
        }
        if let _value = thumbnail {
            builder.setThumbnail(_value)
        }
        if let _value = digest {
            builder.setDigest(_value)
        }
        if let _value = fileName {
            builder.setFileName(_value)
        }
        if hasFlags {
            builder.setFlags(flags)
        }
        if hasWidth {
            builder.setWidth(width)
        }
        if hasHeight {
            builder.setHeight(height)
        }
        if let _value = caption {
            builder.setCaption(_value)
        }
        if let _value = url {
            builder.setUrl(_value)
        }
        return builder
    }

    @objc public class SNProtoAttachmentPointerBuilder: NSObject {

        private var proto = SessionProtos_AttachmentPointer()

        @objc fileprivate override init() {}

        @objc fileprivate init(id: UInt64) {
            super.init()

            setId(id)
        }

        @objc public func setId(_ valueParam: UInt64) {
            proto.id = valueParam
        }

        @objc public func setContentType(_ valueParam: String) {
            proto.contentType = valueParam
        }

        @objc public func setKey(_ valueParam: Data) {
            proto.key = valueParam
        }

        @objc public func setSize(_ valueParam: UInt32) {
            proto.size = valueParam
        }

        @objc public func setThumbnail(_ valueParam: Data) {
            proto.thumbnail = valueParam
        }

        @objc public func setDigest(_ valueParam: Data) {
            proto.digest = valueParam
        }

        @objc public func setFileName(_ valueParam: String) {
            proto.fileName = valueParam
        }

        @objc public func setFlags(_ valueParam: UInt32) {
            proto.flags = valueParam
        }

        @objc public func setWidth(_ valueParam: UInt32) {
            proto.width = valueParam
        }

        @objc public func setHeight(_ valueParam: UInt32) {
            proto.height = valueParam
        }

        @objc public func setCaption(_ valueParam: String) {
            proto.caption = valueParam
        }

        @objc public func setUrl(_ valueParam: String) {
            proto.url = valueParam
        }

        @objc public func build() throws -> SNProtoAttachmentPointer {
            return try SNProtoAttachmentPointer.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoAttachmentPointer.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_AttachmentPointer

    @objc public let id: UInt64

    @objc public var contentType: String? {
        guard proto.hasContentType else {
            return nil
        }
        return proto.contentType
    }
    @objc public var hasContentType: Bool {
        return proto.hasContentType
    }

    @objc public var key: Data? {
        guard proto.hasKey else {
            return nil
        }
        return proto.key
    }
    @objc public var hasKey: Bool {
        return proto.hasKey
    }

    @objc public var size: UInt32 {
        return proto.size
    }
    @objc public var hasSize: Bool {
        return proto.hasSize
    }

    @objc public var thumbnail: Data? {
        guard proto.hasThumbnail else {
            return nil
        }
        return proto.thumbnail
    }
    @objc public var hasThumbnail: Bool {
        return proto.hasThumbnail
    }

    @objc public var digest: Data? {
        guard proto.hasDigest else {
            return nil
        }
        return proto.digest
    }
    @objc public var hasDigest: Bool {
        return proto.hasDigest
    }

    @objc public var fileName: String? {
        guard proto.hasFileName else {
            return nil
        }
        return proto.fileName
    }
    @objc public var hasFileName: Bool {
        return proto.hasFileName
    }

    @objc public var flags: UInt32 {
        return proto.flags
    }
    @objc public var hasFlags: Bool {
        return proto.hasFlags
    }

    @objc public var width: UInt32 {
        return proto.width
    }
    @objc public var hasWidth: Bool {
        return proto.hasWidth
    }

    @objc public var height: UInt32 {
        return proto.height
    }
    @objc public var hasHeight: Bool {
        return proto.hasHeight
    }

    @objc public var caption: String? {
        guard proto.hasCaption else {
            return nil
        }
        return proto.caption
    }
    @objc public var hasCaption: Bool {
        return proto.hasCaption
    }

    @objc public var url: String? {
        guard proto.hasURL else {
            return nil
        }
        return proto.url
    }
    @objc public var hasURL: Bool {
        return proto.hasURL
    }

    private init(proto: SessionProtos_AttachmentPointer,
                 id: UInt64) {
        self.proto = proto
        self.id = id
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoAttachmentPointer {
        let proto = try SessionProtos_AttachmentPointer(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_AttachmentPointer) throws -> SNProtoAttachmentPointer {
        guard proto.hasID else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: id")
        }
        let id = proto.id

        // MARK: - Begin Validation Logic for SNProtoAttachmentPointer -

        // MARK: - End Validation Logic for SNProtoAttachmentPointer -

        let result = SNProtoAttachmentPointer(proto: proto,
                                              id: id)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoAttachmentPointer {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoAttachmentPointer.SNProtoAttachmentPointerBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoAttachmentPointer? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoGroupUpdateMessage

@objc public class SNProtoGroupUpdateMessage: NSObject {

    // MARK: - SNProtoGroupUpdateMessageBuilder

    @objc public class func builder() -> SNProtoGroupUpdateMessageBuilder {
        return SNProtoGroupUpdateMessageBuilder()
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoGroupUpdateMessageBuilder {
        let builder = SNProtoGroupUpdateMessageBuilder()
        if let _value = inviteMessage {
            builder.setInviteMessage(_value)
        }
        if let _value = infoChangeMessage {
            builder.setInfoChangeMessage(_value)
        }
        if let _value = memberChangeMessage {
            builder.setMemberChangeMessage(_value)
        }
        if let _value = promoteMessage {
            builder.setPromoteMessage(_value)
        }
        if let _value = memberLeftMessage {
            builder.setMemberLeftMessage(_value)
        }
        if let _value = inviteResponse {
            builder.setInviteResponse(_value)
        }
        if let _value = deleteMemberContent {
            builder.setDeleteMemberContent(_value)
        }
        if let _value = memberLeftNotificationMessage {
            builder.setMemberLeftNotificationMessage(_value)
        }
        return builder
    }

    @objc public class SNProtoGroupUpdateMessageBuilder: NSObject {

        private var proto = SessionProtos_GroupUpdateMessage()

        @objc fileprivate override init() {}

        @objc public func setInviteMessage(_ valueParam: SNProtoGroupUpdateInviteMessage) {
            proto.inviteMessage = valueParam.proto
        }

        @objc public func setInfoChangeMessage(_ valueParam: SNProtoGroupUpdateInfoChangeMessage) {
            proto.infoChangeMessage = valueParam.proto
        }

        @objc public func setMemberChangeMessage(_ valueParam: SNProtoGroupUpdateMemberChangeMessage) {
            proto.memberChangeMessage = valueParam.proto
        }

        @objc public func setPromoteMessage(_ valueParam: SNProtoGroupUpdatePromoteMessage) {
            proto.promoteMessage = valueParam.proto
        }

        @objc public func setMemberLeftMessage(_ valueParam: SNProtoGroupUpdateMemberLeftMessage) {
            proto.memberLeftMessage = valueParam.proto
        }

        @objc public func setInviteResponse(_ valueParam: SNProtoGroupUpdateInviteResponseMessage) {
            proto.inviteResponse = valueParam.proto
        }

        @objc public func setDeleteMemberContent(_ valueParam: SNProtoGroupUpdateDeleteMemberContentMessage) {
            proto.deleteMemberContent = valueParam.proto
        }

        @objc public func setMemberLeftNotificationMessage(_ valueParam: SNProtoGroupUpdateMemberLeftNotificationMessage) {
            proto.memberLeftNotificationMessage = valueParam.proto
        }

        @objc public func build() throws -> SNProtoGroupUpdateMessage {
            return try SNProtoGroupUpdateMessage.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoGroupUpdateMessage.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_GroupUpdateMessage

    @objc public let inviteMessage: SNProtoGroupUpdateInviteMessage?

    @objc public let infoChangeMessage: SNProtoGroupUpdateInfoChangeMessage?

    @objc public let memberChangeMessage: SNProtoGroupUpdateMemberChangeMessage?

    @objc public let promoteMessage: SNProtoGroupUpdatePromoteMessage?

    @objc public let memberLeftMessage: SNProtoGroupUpdateMemberLeftMessage?

    @objc public let inviteResponse: SNProtoGroupUpdateInviteResponseMessage?

    @objc public let deleteMemberContent: SNProtoGroupUpdateDeleteMemberContentMessage?

    @objc public let memberLeftNotificationMessage: SNProtoGroupUpdateMemberLeftNotificationMessage?

    private init(proto: SessionProtos_GroupUpdateMessage,
                 inviteMessage: SNProtoGroupUpdateInviteMessage?,
                 infoChangeMessage: SNProtoGroupUpdateInfoChangeMessage?,
                 memberChangeMessage: SNProtoGroupUpdateMemberChangeMessage?,
                 promoteMessage: SNProtoGroupUpdatePromoteMessage?,
                 memberLeftMessage: SNProtoGroupUpdateMemberLeftMessage?,
                 inviteResponse: SNProtoGroupUpdateInviteResponseMessage?,
                 deleteMemberContent: SNProtoGroupUpdateDeleteMemberContentMessage?,
                 memberLeftNotificationMessage: SNProtoGroupUpdateMemberLeftNotificationMessage?) {
        self.proto = proto
        self.inviteMessage = inviteMessage
        self.infoChangeMessage = infoChangeMessage
        self.memberChangeMessage = memberChangeMessage
        self.promoteMessage = promoteMessage
        self.memberLeftMessage = memberLeftMessage
        self.inviteResponse = inviteResponse
        self.deleteMemberContent = deleteMemberContent
        self.memberLeftNotificationMessage = memberLeftNotificationMessage
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoGroupUpdateMessage {
        let proto = try SessionProtos_GroupUpdateMessage(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_GroupUpdateMessage) throws -> SNProtoGroupUpdateMessage {
        var inviteMessage: SNProtoGroupUpdateInviteMessage? = nil
        if proto.hasInviteMessage {
            inviteMessage = try SNProtoGroupUpdateInviteMessage.parseProto(proto.inviteMessage)
        }

        var infoChangeMessage: SNProtoGroupUpdateInfoChangeMessage? = nil
        if proto.hasInfoChangeMessage {
            infoChangeMessage = try SNProtoGroupUpdateInfoChangeMessage.parseProto(proto.infoChangeMessage)
        }

        var memberChangeMessage: SNProtoGroupUpdateMemberChangeMessage? = nil
        if proto.hasMemberChangeMessage {
            memberChangeMessage = try SNProtoGroupUpdateMemberChangeMessage.parseProto(proto.memberChangeMessage)
        }

        var promoteMessage: SNProtoGroupUpdatePromoteMessage? = nil
        if proto.hasPromoteMessage {
            promoteMessage = try SNProtoGroupUpdatePromoteMessage.parseProto(proto.promoteMessage)
        }

        var memberLeftMessage: SNProtoGroupUpdateMemberLeftMessage? = nil
        if proto.hasMemberLeftMessage {
            memberLeftMessage = try SNProtoGroupUpdateMemberLeftMessage.parseProto(proto.memberLeftMessage)
        }

        var inviteResponse: SNProtoGroupUpdateInviteResponseMessage? = nil
        if proto.hasInviteResponse {
            inviteResponse = try SNProtoGroupUpdateInviteResponseMessage.parseProto(proto.inviteResponse)
        }

        var deleteMemberContent: SNProtoGroupUpdateDeleteMemberContentMessage? = nil
        if proto.hasDeleteMemberContent {
            deleteMemberContent = try SNProtoGroupUpdateDeleteMemberContentMessage.parseProto(proto.deleteMemberContent)
        }

        var memberLeftNotificationMessage: SNProtoGroupUpdateMemberLeftNotificationMessage? = nil
        if proto.hasMemberLeftNotificationMessage {
            memberLeftNotificationMessage = try SNProtoGroupUpdateMemberLeftNotificationMessage.parseProto(proto.memberLeftNotificationMessage)
        }

        // MARK: - Begin Validation Logic for SNProtoGroupUpdateMessage -

        // MARK: - End Validation Logic for SNProtoGroupUpdateMessage -

        let result = SNProtoGroupUpdateMessage(proto: proto,
                                               inviteMessage: inviteMessage,
                                               infoChangeMessage: infoChangeMessage,
                                               memberChangeMessage: memberChangeMessage,
                                               promoteMessage: promoteMessage,
                                               memberLeftMessage: memberLeftMessage,
                                               inviteResponse: inviteResponse,
                                               deleteMemberContent: deleteMemberContent,
                                               memberLeftNotificationMessage: memberLeftNotificationMessage)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoGroupUpdateMessage {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoGroupUpdateMessage.SNProtoGroupUpdateMessageBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoGroupUpdateMessage? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoGroupUpdateInviteMessage

@objc public class SNProtoGroupUpdateInviteMessage: NSObject {

    // MARK: - SNProtoGroupUpdateInviteMessageBuilder

    @objc public class func builder(groupSessionID: String, name: String, memberAuthData: Data, adminSignature: Data) -> SNProtoGroupUpdateInviteMessageBuilder {
        return SNProtoGroupUpdateInviteMessageBuilder(groupSessionID: groupSessionID, name: name, memberAuthData: memberAuthData, adminSignature: adminSignature)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoGroupUpdateInviteMessageBuilder {
        let builder = SNProtoGroupUpdateInviteMessageBuilder(groupSessionID: groupSessionID, name: name, memberAuthData: memberAuthData, adminSignature: adminSignature)
        return builder
    }

    @objc public class SNProtoGroupUpdateInviteMessageBuilder: NSObject {

        private var proto = SessionProtos_GroupUpdateInviteMessage()

        @objc fileprivate override init() {}

        @objc fileprivate init(groupSessionID: String, name: String, memberAuthData: Data, adminSignature: Data) {
            super.init()

            setGroupSessionID(groupSessionID)
            setName(name)
            setMemberAuthData(memberAuthData)
            setAdminSignature(adminSignature)
        }

        @objc public func setGroupSessionID(_ valueParam: String) {
            proto.groupSessionID = valueParam
        }

        @objc public func setName(_ valueParam: String) {
            proto.name = valueParam
        }

        @objc public func setMemberAuthData(_ valueParam: Data) {
            proto.memberAuthData = valueParam
        }

        @objc public func setAdminSignature(_ valueParam: Data) {
            proto.adminSignature = valueParam
        }

        @objc public func build() throws -> SNProtoGroupUpdateInviteMessage {
            return try SNProtoGroupUpdateInviteMessage.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoGroupUpdateInviteMessage.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_GroupUpdateInviteMessage

    @objc public let groupSessionID: String

    @objc public let name: String

    @objc public let memberAuthData: Data

    @objc public let adminSignature: Data

    private init(proto: SessionProtos_GroupUpdateInviteMessage,
                 groupSessionID: String,
                 name: String,
                 memberAuthData: Data,
                 adminSignature: Data) {
        self.proto = proto
        self.groupSessionID = groupSessionID
        self.name = name
        self.memberAuthData = memberAuthData
        self.adminSignature = adminSignature
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoGroupUpdateInviteMessage {
        let proto = try SessionProtos_GroupUpdateInviteMessage(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_GroupUpdateInviteMessage) throws -> SNProtoGroupUpdateInviteMessage {
        guard proto.hasGroupSessionID else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: groupSessionID")
        }
        let groupSessionID = proto.groupSessionID

        guard proto.hasName else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: name")
        }
        let name = proto.name

        guard proto.hasMemberAuthData else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: memberAuthData")
        }
        let memberAuthData = proto.memberAuthData

        guard proto.hasAdminSignature else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: adminSignature")
        }
        let adminSignature = proto.adminSignature

        // MARK: - Begin Validation Logic for SNProtoGroupUpdateInviteMessage -

        // MARK: - End Validation Logic for SNProtoGroupUpdateInviteMessage -

        let result = SNProtoGroupUpdateInviteMessage(proto: proto,
                                                     groupSessionID: groupSessionID,
                                                     name: name,
                                                     memberAuthData: memberAuthData,
                                                     adminSignature: adminSignature)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoGroupUpdateInviteMessage {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoGroupUpdateInviteMessage.SNProtoGroupUpdateInviteMessageBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoGroupUpdateInviteMessage? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoGroupUpdatePromoteMessage

@objc public class SNProtoGroupUpdatePromoteMessage: NSObject {

    // MARK: - SNProtoGroupUpdatePromoteMessageBuilder

    @objc public class func builder(groupIdentitySeed: Data, name: String) -> SNProtoGroupUpdatePromoteMessageBuilder {
        return SNProtoGroupUpdatePromoteMessageBuilder(groupIdentitySeed: groupIdentitySeed, name: name)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoGroupUpdatePromoteMessageBuilder {
        let builder = SNProtoGroupUpdatePromoteMessageBuilder(groupIdentitySeed: groupIdentitySeed, name: name)
        return builder
    }

    @objc public class SNProtoGroupUpdatePromoteMessageBuilder: NSObject {

        private var proto = SessionProtos_GroupUpdatePromoteMessage()

        @objc fileprivate override init() {}

        @objc fileprivate init(groupIdentitySeed: Data, name: String) {
            super.init()

            setGroupIdentitySeed(groupIdentitySeed)
            setName(name)
        }

        @objc public func setGroupIdentitySeed(_ valueParam: Data) {
            proto.groupIdentitySeed = valueParam
        }

        @objc public func setName(_ valueParam: String) {
            proto.name = valueParam
        }

        @objc public func build() throws -> SNProtoGroupUpdatePromoteMessage {
            return try SNProtoGroupUpdatePromoteMessage.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoGroupUpdatePromoteMessage.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_GroupUpdatePromoteMessage

    @objc public let groupIdentitySeed: Data

    @objc public let name: String

    private init(proto: SessionProtos_GroupUpdatePromoteMessage,
                 groupIdentitySeed: Data,
                 name: String) {
        self.proto = proto
        self.groupIdentitySeed = groupIdentitySeed
        self.name = name
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoGroupUpdatePromoteMessage {
        let proto = try SessionProtos_GroupUpdatePromoteMessage(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_GroupUpdatePromoteMessage) throws -> SNProtoGroupUpdatePromoteMessage {
        guard proto.hasGroupIdentitySeed else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: groupIdentitySeed")
        }
        let groupIdentitySeed = proto.groupIdentitySeed

        guard proto.hasName else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: name")
        }
        let name = proto.name

        // MARK: - Begin Validation Logic for SNProtoGroupUpdatePromoteMessage -

        // MARK: - End Validation Logic for SNProtoGroupUpdatePromoteMessage -

        let result = SNProtoGroupUpdatePromoteMessage(proto: proto,
                                                      groupIdentitySeed: groupIdentitySeed,
                                                      name: name)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoGroupUpdatePromoteMessage {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoGroupUpdatePromoteMessage.SNProtoGroupUpdatePromoteMessageBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoGroupUpdatePromoteMessage? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoGroupUpdateInfoChangeMessage

@objc public class SNProtoGroupUpdateInfoChangeMessage: NSObject {

    // MARK: - SNProtoGroupUpdateInfoChangeMessageType

    @objc public enum SNProtoGroupUpdateInfoChangeMessageType: Int32 {
        case name = 1
        case avatar = 2
        case disappearingMessages = 3
    }

    private class func SNProtoGroupUpdateInfoChangeMessageTypeWrap(_ value: SessionProtos_GroupUpdateInfoChangeMessage.TypeEnum) -> SNProtoGroupUpdateInfoChangeMessageType {
        switch value {
        case .name: return .name
        case .avatar: return .avatar
        case .disappearingMessages: return .disappearingMessages
        }
    }

    private class func SNProtoGroupUpdateInfoChangeMessageTypeUnwrap(_ value: SNProtoGroupUpdateInfoChangeMessageType) -> SessionProtos_GroupUpdateInfoChangeMessage.TypeEnum {
        switch value {
        case .name: return .name
        case .avatar: return .avatar
        case .disappearingMessages: return .disappearingMessages
        }
    }

    // MARK: - SNProtoGroupUpdateInfoChangeMessageBuilder

    @objc public class func builder(type: SNProtoGroupUpdateInfoChangeMessageType, adminSignature: Data) -> SNProtoGroupUpdateInfoChangeMessageBuilder {
        return SNProtoGroupUpdateInfoChangeMessageBuilder(type: type, adminSignature: adminSignature)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoGroupUpdateInfoChangeMessageBuilder {
        let builder = SNProtoGroupUpdateInfoChangeMessageBuilder(type: type, adminSignature: adminSignature)
        if let _value = updatedName {
            builder.setUpdatedName(_value)
        }
        if hasUpdatedExpiration {
            builder.setUpdatedExpiration(updatedExpiration)
        }
        return builder
    }

    @objc public class SNProtoGroupUpdateInfoChangeMessageBuilder: NSObject {

        private var proto = SessionProtos_GroupUpdateInfoChangeMessage()

        @objc fileprivate override init() {}

        @objc fileprivate init(type: SNProtoGroupUpdateInfoChangeMessageType, adminSignature: Data) {
            super.init()

            setType(type)
            setAdminSignature(adminSignature)
        }

        @objc public func setType(_ valueParam: SNProtoGroupUpdateInfoChangeMessageType) {
            proto.type = SNProtoGroupUpdateInfoChangeMessageTypeUnwrap(valueParam)
        }

        @objc public func setUpdatedName(_ valueParam: String) {
            proto.updatedName = valueParam
        }

        @objc public func setUpdatedExpiration(_ valueParam: UInt32) {
            proto.updatedExpiration = valueParam
        }

        @objc public func setAdminSignature(_ valueParam: Data) {
            proto.adminSignature = valueParam
        }

        @objc public func build() throws -> SNProtoGroupUpdateInfoChangeMessage {
            return try SNProtoGroupUpdateInfoChangeMessage.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoGroupUpdateInfoChangeMessage.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_GroupUpdateInfoChangeMessage

    @objc public let type: SNProtoGroupUpdateInfoChangeMessageType

    @objc public let adminSignature: Data

    @objc public var updatedName: String? {
        guard proto.hasUpdatedName else {
            return nil
        }
        return proto.updatedName
    }
    @objc public var hasUpdatedName: Bool {
        return proto.hasUpdatedName
    }

    @objc public var updatedExpiration: UInt32 {
        return proto.updatedExpiration
    }
    @objc public var hasUpdatedExpiration: Bool {
        return proto.hasUpdatedExpiration
    }

    private init(proto: SessionProtos_GroupUpdateInfoChangeMessage,
                 type: SNProtoGroupUpdateInfoChangeMessageType,
                 adminSignature: Data) {
        self.proto = proto
        self.type = type
        self.adminSignature = adminSignature
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoGroupUpdateInfoChangeMessage {
        let proto = try SessionProtos_GroupUpdateInfoChangeMessage(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_GroupUpdateInfoChangeMessage) throws -> SNProtoGroupUpdateInfoChangeMessage {
        guard proto.hasType else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: type")
        }
        let type = SNProtoGroupUpdateInfoChangeMessageTypeWrap(proto.type)

        guard proto.hasAdminSignature else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: adminSignature")
        }
        let adminSignature = proto.adminSignature

        // MARK: - Begin Validation Logic for SNProtoGroupUpdateInfoChangeMessage -

        // MARK: - End Validation Logic for SNProtoGroupUpdateInfoChangeMessage -

        let result = SNProtoGroupUpdateInfoChangeMessage(proto: proto,
                                                         type: type,
                                                         adminSignature: adminSignature)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoGroupUpdateInfoChangeMessage {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoGroupUpdateInfoChangeMessage.SNProtoGroupUpdateInfoChangeMessageBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoGroupUpdateInfoChangeMessage? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoGroupUpdateMemberChangeMessage

@objc public class SNProtoGroupUpdateMemberChangeMessage: NSObject {

    // MARK: - SNProtoGroupUpdateMemberChangeMessageType

    @objc public enum SNProtoGroupUpdateMemberChangeMessageType: Int32 {
        case added = 1
        case removed = 2
        case promoted = 3
    }

    private class func SNProtoGroupUpdateMemberChangeMessageTypeWrap(_ value: SessionProtos_GroupUpdateMemberChangeMessage.TypeEnum) -> SNProtoGroupUpdateMemberChangeMessageType {
        switch value {
        case .added: return .added
        case .removed: return .removed
        case .promoted: return .promoted
        }
    }

    private class func SNProtoGroupUpdateMemberChangeMessageTypeUnwrap(_ value: SNProtoGroupUpdateMemberChangeMessageType) -> SessionProtos_GroupUpdateMemberChangeMessage.TypeEnum {
        switch value {
        case .added: return .added
        case .removed: return .removed
        case .promoted: return .promoted
        }
    }

    // MARK: - SNProtoGroupUpdateMemberChangeMessageBuilder

    @objc public class func builder(type: SNProtoGroupUpdateMemberChangeMessageType, adminSignature: Data) -> SNProtoGroupUpdateMemberChangeMessageBuilder {
        return SNProtoGroupUpdateMemberChangeMessageBuilder(type: type, adminSignature: adminSignature)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoGroupUpdateMemberChangeMessageBuilder {
        let builder = SNProtoGroupUpdateMemberChangeMessageBuilder(type: type, adminSignature: adminSignature)
        builder.setMemberSessionIds(memberSessionIds)
        if hasHistoryShared {
            builder.setHistoryShared(historyShared)
        }
        return builder
    }

    @objc public class SNProtoGroupUpdateMemberChangeMessageBuilder: NSObject {

        private var proto = SessionProtos_GroupUpdateMemberChangeMessage()

        @objc fileprivate override init() {}

        @objc fileprivate init(type: SNProtoGroupUpdateMemberChangeMessageType, adminSignature: Data) {
            super.init()

            setType(type)
            setAdminSignature(adminSignature)
        }

        @objc public func setType(_ valueParam: SNProtoGroupUpdateMemberChangeMessageType) {
            proto.type = SNProtoGroupUpdateMemberChangeMessageTypeUnwrap(valueParam)
        }

        @objc public func addMemberSessionIds(_ valueParam: String) {
            var items = proto.memberSessionIds
            items.append(valueParam)
            proto.memberSessionIds = items
        }

        @objc public func setMemberSessionIds(_ wrappedItems: [String]) {
            proto.memberSessionIds = wrappedItems
        }

        @objc public func setHistoryShared(_ valueParam: Bool) {
            proto.historyShared = valueParam
        }

        @objc public func setAdminSignature(_ valueParam: Data) {
            proto.adminSignature = valueParam
        }

        @objc public func build() throws -> SNProtoGroupUpdateMemberChangeMessage {
            return try SNProtoGroupUpdateMemberChangeMessage.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoGroupUpdateMemberChangeMessage.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_GroupUpdateMemberChangeMessage

    @objc public let type: SNProtoGroupUpdateMemberChangeMessageType

    @objc public let adminSignature: Data

    @objc public var memberSessionIds: [String] {
        return proto.memberSessionIds
    }

    @objc public var historyShared: Bool {
        return proto.historyShared
    }
    @objc public var hasHistoryShared: Bool {
        return proto.hasHistoryShared
    }

    private init(proto: SessionProtos_GroupUpdateMemberChangeMessage,
                 type: SNProtoGroupUpdateMemberChangeMessageType,
                 adminSignature: Data) {
        self.proto = proto
        self.type = type
        self.adminSignature = adminSignature
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoGroupUpdateMemberChangeMessage {
        let proto = try SessionProtos_GroupUpdateMemberChangeMessage(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_GroupUpdateMemberChangeMessage) throws -> SNProtoGroupUpdateMemberChangeMessage {
        guard proto.hasType else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: type")
        }
        let type = SNProtoGroupUpdateMemberChangeMessageTypeWrap(proto.type)

        guard proto.hasAdminSignature else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: adminSignature")
        }
        let adminSignature = proto.adminSignature

        // MARK: - Begin Validation Logic for SNProtoGroupUpdateMemberChangeMessage -

        // MARK: - End Validation Logic for SNProtoGroupUpdateMemberChangeMessage -

        let result = SNProtoGroupUpdateMemberChangeMessage(proto: proto,
                                                           type: type,
                                                           adminSignature: adminSignature)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoGroupUpdateMemberChangeMessage {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoGroupUpdateMemberChangeMessage.SNProtoGroupUpdateMemberChangeMessageBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoGroupUpdateMemberChangeMessage? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoGroupUpdateMemberLeftMessage

@objc public class SNProtoGroupUpdateMemberLeftMessage: NSObject {

    // MARK: - SNProtoGroupUpdateMemberLeftMessageBuilder

    @objc public class func builder() -> SNProtoGroupUpdateMemberLeftMessageBuilder {
        return SNProtoGroupUpdateMemberLeftMessageBuilder()
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoGroupUpdateMemberLeftMessageBuilder {
        let builder = SNProtoGroupUpdateMemberLeftMessageBuilder()
        return builder
    }

    @objc public class SNProtoGroupUpdateMemberLeftMessageBuilder: NSObject {

        private var proto = SessionProtos_GroupUpdateMemberLeftMessage()

        @objc fileprivate override init() {}

        @objc public func build() throws -> SNProtoGroupUpdateMemberLeftMessage {
            return try SNProtoGroupUpdateMemberLeftMessage.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoGroupUpdateMemberLeftMessage.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_GroupUpdateMemberLeftMessage

    private init(proto: SessionProtos_GroupUpdateMemberLeftMessage) {
        self.proto = proto
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoGroupUpdateMemberLeftMessage {
        let proto = try SessionProtos_GroupUpdateMemberLeftMessage(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_GroupUpdateMemberLeftMessage) throws -> SNProtoGroupUpdateMemberLeftMessage {
        // MARK: - Begin Validation Logic for SNProtoGroupUpdateMemberLeftMessage -

        // MARK: - End Validation Logic for SNProtoGroupUpdateMemberLeftMessage -

        let result = SNProtoGroupUpdateMemberLeftMessage(proto: proto)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoGroupUpdateMemberLeftMessage {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoGroupUpdateMemberLeftMessage.SNProtoGroupUpdateMemberLeftMessageBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoGroupUpdateMemberLeftMessage? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoGroupUpdateMemberLeftNotificationMessage

@objc public class SNProtoGroupUpdateMemberLeftNotificationMessage: NSObject {

    // MARK: - SNProtoGroupUpdateMemberLeftNotificationMessageBuilder

    @objc public class func builder() -> SNProtoGroupUpdateMemberLeftNotificationMessageBuilder {
        return SNProtoGroupUpdateMemberLeftNotificationMessageBuilder()
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoGroupUpdateMemberLeftNotificationMessageBuilder {
        let builder = SNProtoGroupUpdateMemberLeftNotificationMessageBuilder()
        return builder
    }

    @objc public class SNProtoGroupUpdateMemberLeftNotificationMessageBuilder: NSObject {

        private var proto = SessionProtos_GroupUpdateMemberLeftNotificationMessage()

        @objc fileprivate override init() {}

        @objc public func build() throws -> SNProtoGroupUpdateMemberLeftNotificationMessage {
            return try SNProtoGroupUpdateMemberLeftNotificationMessage.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoGroupUpdateMemberLeftNotificationMessage.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_GroupUpdateMemberLeftNotificationMessage

    private init(proto: SessionProtos_GroupUpdateMemberLeftNotificationMessage) {
        self.proto = proto
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoGroupUpdateMemberLeftNotificationMessage {
        let proto = try SessionProtos_GroupUpdateMemberLeftNotificationMessage(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_GroupUpdateMemberLeftNotificationMessage) throws -> SNProtoGroupUpdateMemberLeftNotificationMessage {
        // MARK: - Begin Validation Logic for SNProtoGroupUpdateMemberLeftNotificationMessage -

        // MARK: - End Validation Logic for SNProtoGroupUpdateMemberLeftNotificationMessage -

        let result = SNProtoGroupUpdateMemberLeftNotificationMessage(proto: proto)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoGroupUpdateMemberLeftNotificationMessage {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoGroupUpdateMemberLeftNotificationMessage.SNProtoGroupUpdateMemberLeftNotificationMessageBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoGroupUpdateMemberLeftNotificationMessage? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoGroupUpdateInviteResponseMessage

@objc public class SNProtoGroupUpdateInviteResponseMessage: NSObject {

    // MARK: - SNProtoGroupUpdateInviteResponseMessageBuilder

    @objc public class func builder(isApproved: Bool) -> SNProtoGroupUpdateInviteResponseMessageBuilder {
        return SNProtoGroupUpdateInviteResponseMessageBuilder(isApproved: isApproved)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoGroupUpdateInviteResponseMessageBuilder {
        let builder = SNProtoGroupUpdateInviteResponseMessageBuilder(isApproved: isApproved)
        return builder
    }

    @objc public class SNProtoGroupUpdateInviteResponseMessageBuilder: NSObject {

        private var proto = SessionProtos_GroupUpdateInviteResponseMessage()

        @objc fileprivate override init() {}

        @objc fileprivate init(isApproved: Bool) {
            super.init()

            setIsApproved(isApproved)
        }

        @objc public func setIsApproved(_ valueParam: Bool) {
            proto.isApproved = valueParam
        }

        @objc public func build() throws -> SNProtoGroupUpdateInviteResponseMessage {
            return try SNProtoGroupUpdateInviteResponseMessage.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoGroupUpdateInviteResponseMessage.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_GroupUpdateInviteResponseMessage

    @objc public let isApproved: Bool

    private init(proto: SessionProtos_GroupUpdateInviteResponseMessage,
                 isApproved: Bool) {
        self.proto = proto
        self.isApproved = isApproved
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoGroupUpdateInviteResponseMessage {
        let proto = try SessionProtos_GroupUpdateInviteResponseMessage(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_GroupUpdateInviteResponseMessage) throws -> SNProtoGroupUpdateInviteResponseMessage {
        guard proto.hasIsApproved else {
            throw SNProtoError.invalidProtobuf(description: "\(NSStringFromClass(self)) missing required field: isApproved")
        }
        let isApproved = proto.isApproved

        // MARK: - Begin Validation Logic for SNProtoGroupUpdateInviteResponseMessage -

        // MARK: - End Validation Logic for SNProtoGroupUpdateInviteResponseMessage -

        let result = SNProtoGroupUpdateInviteResponseMessage(proto: proto,
                                                             isApproved: isApproved)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoGroupUpdateInviteResponseMessage {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoGroupUpdateInviteResponseMessage.SNProtoGroupUpdateInviteResponseMessageBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoGroupUpdateInviteResponseMessage? {
        return try! self.build()
    }
}

#endif

// MARK: - SNProtoGroupUpdateDeleteMemberContentMessage

@objc public class SNProtoGroupUpdateDeleteMemberContentMessage: NSObject {

    // MARK: - SNProtoGroupUpdateDeleteMemberContentMessageBuilder

    @objc public class func builder() -> SNProtoGroupUpdateDeleteMemberContentMessageBuilder {
        return SNProtoGroupUpdateDeleteMemberContentMessageBuilder()
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SNProtoGroupUpdateDeleteMemberContentMessageBuilder {
        let builder = SNProtoGroupUpdateDeleteMemberContentMessageBuilder()
        builder.setMemberSessionIds(memberSessionIds)
        builder.setMessageHashes(messageHashes)
        if let _value = adminSignature {
            builder.setAdminSignature(_value)
        }
        return builder
    }

    @objc public class SNProtoGroupUpdateDeleteMemberContentMessageBuilder: NSObject {

        private var proto = SessionProtos_GroupUpdateDeleteMemberContentMessage()

        @objc fileprivate override init() {}

        @objc public func addMemberSessionIds(_ valueParam: String) {
            var items = proto.memberSessionIds
            items.append(valueParam)
            proto.memberSessionIds = items
        }

        @objc public func setMemberSessionIds(_ wrappedItems: [String]) {
            proto.memberSessionIds = wrappedItems
        }

        @objc public func addMessageHashes(_ valueParam: String) {
            var items = proto.messageHashes
            items.append(valueParam)
            proto.messageHashes = items
        }

        @objc public func setMessageHashes(_ wrappedItems: [String]) {
            proto.messageHashes = wrappedItems
        }

        @objc public func setAdminSignature(_ valueParam: Data) {
            proto.adminSignature = valueParam
        }

        @objc public func build() throws -> SNProtoGroupUpdateDeleteMemberContentMessage {
            return try SNProtoGroupUpdateDeleteMemberContentMessage.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SNProtoGroupUpdateDeleteMemberContentMessage.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: SessionProtos_GroupUpdateDeleteMemberContentMessage

    @objc public var memberSessionIds: [String] {
        return proto.memberSessionIds
    }

    @objc public var messageHashes: [String] {
        return proto.messageHashes
    }

    @objc public var adminSignature: Data? {
        guard proto.hasAdminSignature else {
            return nil
        }
        return proto.adminSignature
    }
    @objc public var hasAdminSignature: Bool {
        return proto.hasAdminSignature
    }

    private init(proto: SessionProtos_GroupUpdateDeleteMemberContentMessage) {
        self.proto = proto
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SNProtoGroupUpdateDeleteMemberContentMessage {
        let proto = try SessionProtos_GroupUpdateDeleteMemberContentMessage(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: SessionProtos_GroupUpdateDeleteMemberContentMessage) throws -> SNProtoGroupUpdateDeleteMemberContentMessage {
        // MARK: - Begin Validation Logic for SNProtoGroupUpdateDeleteMemberContentMessage -

        // MARK: - End Validation Logic for SNProtoGroupUpdateDeleteMemberContentMessage -

        let result = SNProtoGroupUpdateDeleteMemberContentMessage(proto: proto)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SNProtoGroupUpdateDeleteMemberContentMessage {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SNProtoGroupUpdateDeleteMemberContentMessage.SNProtoGroupUpdateDeleteMemberContentMessageBuilder {
    @objc public func buildIgnoringErrors() -> SNProtoGroupUpdateDeleteMemberContentMessage? {
        return try! self.build()
    }
}

#endif
