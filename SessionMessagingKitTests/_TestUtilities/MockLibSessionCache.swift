// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit
import GRDB

@testable import SessionMessagingKit

class MockLibSessionCache: Mock<LibSessionCacheType>, LibSessionCacheType {
    var userSessionId: SessionId { mock() }
    var isEmpty: Bool { mock() }
    var needsSync: Bool { mock() }
    
    // MARK: - State Management
    
    func loadState(_ db: Database) { mockNoReturn(untrackedArgs: [db]) }
    func loadDefaultStatesFor(
        userConfigVariants: Set<ConfigDump.Variant>,
        groups: [ClosedGroup],
        userSessionId: SessionId,
        userEd25519KeyPair: KeyPair
    ) {
        mockNoReturn(args: [userConfigVariants, groups, userSessionId, userEd25519KeyPair])
    }
    
    func config(for variant: ConfigDump.Variant, sessionId: SessionId) -> Atomic<LibSession.Config?> {
        return mock(args: [variant, sessionId])
    }
    
    func setConfig(for variant: ConfigDump.Variant, sessionId: SessionId, to config: LibSession.Config?) {
        mockNoReturn(args: [variant, sessionId, config])
    }
    
    func createDump(
        config: LibSession.Config?,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        timestampMs: Int64
    ) throws -> ConfigDump? {
        return try mockThrowing(args: [config, variant, sessionId, timestampMs])
    }
    
    // MARK: - Pushes
    
    func pendingChanges(_ db: Database, swarmPubkey: String) throws -> LibSession.PendingChanges {
        return mock(args: [swarmPubkey], untrackedArgs: [db])
    }
    
    func markingAsPushed(
        seqNo: Int64,
        serverHash: String,
        sentTimestamp: Int64,
        variant: ConfigDump.Variant,
        swarmPublicKey: String
    ) -> ConfigDump? {
        return mock(args: [seqNo, serverHash, sentTimestamp, variant, swarmPublicKey])
    }

    // MARK: - Config Message Handling
    
    func configNeedsDump(_ config: LibSession.Config?) -> Bool {
        return mock(args: [config])
    }
    
    func configHashes(for swarmPubkey: String) -> [String] {
        return mock(args: [swarmPubkey])
    }

    func handleConfigMessages(
        _ db: Database,
        swarmPublicKey: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo]
    ) throws {
        try mockThrowingNoReturn(args: [swarmPublicKey, messages], untrackedArgs: [db])
    }
    
    func unsafeDirectMergeConfigMessage(
        swarmPublicKey: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo]
    ) throws {
        try mockThrowingNoReturn(args: [swarmPublicKey, messages])
    }
}
