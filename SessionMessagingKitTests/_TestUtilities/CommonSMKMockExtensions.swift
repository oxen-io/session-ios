// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

@testable import SessionMessagingKit

extension Message.Destination: Mocked {
    static var mock: Message.Destination = .contact(publicKey: "")
}

extension LibSession.Config: Mocked {
    static var mock: LibSession.Config = .invalid
}

extension ConfigDump.Variant: Mocked {
    static var mock: ConfigDump.Variant = .userProfile
}

extension SessionThread: Mocked {
    static var mock: SessionThread = SessionThread(
        id: .mock,
        variant: .contact,
        creationDateTimestamp: nil,
        shouldBeVisible: false,
        isPinned: false,
        messageDraft: nil,
        notificationSound: nil,
        mutedUntilTimestamp: nil,
        onlyNotifyForMentions: false,
        markedAsUnread: nil,
        pinnedPriority: nil,
        using: .any
    )
}

extension Interaction: Mocked {
    static var mock: Interaction = Interaction(
        id: 123456,
        serverHash: .mock,
        messageUuid: nil,
        threadId: .mock,
        authorId: .mock,
        variant: .standardIncoming,
        body: .mock,
        timestampMs: 1234567890,
        receivedAtTimestampMs: 1234567890,
        wasRead: false,
        hasMention: false,
        expiresInSeconds: nil,
        expiresStartedAtMs: nil,
        linkPreviewUrl: nil,
        openGroupServerMessageId: nil,
        openGroupWhisperMods: false,
        openGroupWhisperTo: nil
    )
}
