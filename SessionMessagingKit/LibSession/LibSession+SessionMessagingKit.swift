// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtil
import SessionUtilitiesKit

// MARK: - LibSession

public extension LibSession {
    // MARK: - Variables
    
    internal static func syncDedupeId(_ sessionIdHexString: String) -> String {
        return "EnqueueConfigurationSyncJob-\(sessionIdHexString)"   // stringlint:disable
    }    
    
    // MARK: - Loading
    
    static func clearMemoryState(using dependencies: Dependencies) {
        dependencies.mutate(cache: .libSession) { cache in
            cache.removeAll()
        }
    }
    
    static func loadState(_ db: Database, using dependencies: Dependencies) {
        // Ensure we have the ed25519 key and that we haven't already loaded the state before
        // we continue
        guard
            let ed25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db, using: dependencies),
            dependencies[cache: .libSession].isEmpty
        else { return SNLog("[LibSession] Ignoring loadState due to existing state") }
        
        // Retrieve the existing dumps from the database
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        let existingDumps: [ConfigDump] = ((try? ConfigDump.fetchSet(db)) ?? [])
            .sorted { lhs, rhs in lhs.variant.loadOrder < rhs.variant.loadOrder }
        let existingDumpVariants: Set<ConfigDump.Variant> = existingDumps
            .map { $0.variant }
            .asSet()
        let missingRequiredVariants: Set<ConfigDump.Variant> = ConfigDump.Variant.userVariants
            .subtracting(existingDumpVariants)
        let groupsByKey: [String: ClosedGroup] = (try? ClosedGroup
            .filter(ClosedGroup.Columns.threadId.like("\(SessionId.Prefix.group.rawValue)%"))
            .fetchAll(db)
            .reduce(into: [:]) { result, next in result[next.threadId] = next })
            .defaulting(to: [:])
        let groupsWithNoDumps: [ClosedGroup] = groupsByKey
            .values
            .filter { group in !existingDumps.contains(where: { $0.sessionId.hexString == group.id }) }
        
        // Create the config records for each dump
        dependencies.mutate(cache: .libSession) { cache in
            existingDumps.forEach { dump in
                cache.setConfig(
                    for: dump.variant,
                    sessionId: dump.sessionId,
                    to: try? LibSession
                        .loadState(
                            for: dump.variant,
                            sessionId: dump.sessionId,
                            userEd25519SecretKey: ed25519KeyPair.secretKey,
                            groupEd25519SecretKey: groupsByKey[dump.sessionId.hexString]?
                                .groupIdentityPrivateKey
                                .map { Array($0) },
                            cachedData: dump.data,
                            cache: cache
                        )
                        .addingLogger()
                )
            }
            
            /// It's possible for there to not be dumps for all of the user configs so we load any missing ones to ensure funcitonality
            /// works smoothly
            missingRequiredVariants.forEach { variant in
                cache.setConfig(
                    for: variant,
                    sessionId: userSessionId,
                    to: try? LibSession
                        .loadState(
                            for: variant,
                            sessionId: userSessionId,
                            userEd25519SecretKey: ed25519KeyPair.secretKey,
                            groupEd25519SecretKey: nil,
                            cachedData: nil,
                            cache: cache
                        )
                        .addingLogger()
                )
            }
        }
        
        /// It's possible for a group to get created but for a dump to not be created (eg. when a crash happens at the right time), to
        /// handle this we also load the state of any groups which don't have dumps if they aren't in the `invited` state (those in
        /// the `invited` state will have their state loaded if the invite is accepted)
        groupsWithNoDumps
            .filter { $0.invited != true }
            .forEach { group in
                _ = try? LibSession.createGroupState(
                    groupSessionId: SessionId(.group, hex: group.id),
                    userED25519KeyPair: ed25519KeyPair,
                    groupIdentityPrivateKey: group.groupIdentityPrivateKey,
                    shouldLoadState: true,
                    using: dependencies
                )
            }
        
        SNLog("[LibSession] Completed loadState")
    }
    
    private static func loadState(
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        userEd25519SecretKey: [UInt8],
        groupEd25519SecretKey: [UInt8]?,
        cachedData: Data?,
        cache: LibSessionCacheType
    ) throws -> Config {
        // Setup initial variables (including getting the memory address for any cached data)
        var conf: UnsafeMutablePointer<config_object>? = nil
        var keysConf: UnsafeMutablePointer<config_group_keys>? = nil
        var secretKey: [UInt8] = userEd25519SecretKey
        var error: [CChar] = [CChar](repeating: 0, count: 256)
        let cachedDump: (data: UnsafePointer<UInt8>, length: Int)? = cachedData?.withUnsafeBytes { unsafeBytes in
            return unsafeBytes.baseAddress.map {
                (
                    $0.assumingMemoryBound(to: UInt8.self),
                    unsafeBytes.count
                )
            }
        }
        let userConfigInitCalls: [ConfigDump.Variant: UserConfigInitialiser] = [
            .userProfile: user_profile_init,
            .contacts: contacts_init,
            .convoInfoVolatile: convo_info_volatile_init,
            .userGroups: user_groups_init
        ]
        let groupConfigInitCalls: [ConfigDump.Variant: GroupConfigInitialiser] = [
            .groupInfo: groups_info_init,
            .groupMembers: groups_members_init
        ]
        
        switch (variant, groupEd25519SecretKey) {
            case (.invalid, _):
                SNLog("[LibSession Error] Unable to create \(variant.rawValue) config object")
                throw LibSessionError.unableToCreateConfigObject
                
            case (.userProfile, _), (.contacts, _), (.convoInfoVolatile, _), (.userGroups, _):
                return try (userConfigInitCalls[variant]?(
                    &conf,
                    &secretKey,
                    cachedDump?.data,
                    (cachedDump?.length ?? 0),
                    &error
                ))
                .toConfig(conf, variant: variant, error: error)
                
            case (.groupInfo, .some(var adminSecretKey)), (.groupMembers, .some(var adminSecretKey)):
                var identityPublicKey: [UInt8] = sessionId.publicKey
                
                return try (groupConfigInitCalls[variant]?(
                    &conf,
                    &identityPublicKey,
                    &adminSecretKey,
                    cachedDump?.data,
                    (cachedDump?.length ?? 0),
                    &error
                ))
                .toConfig(conf, variant: variant, error: error)
                
            case (.groupKeys, .some(var adminSecretKey)):
                var identityPublicKey: [UInt8] = sessionId.publicKey
                let infoConfig: Config? = cache.config(for: .groupInfo, sessionId: sessionId).wrappedValue
                let membersConfig: Config? = cache.config(for: .groupMembers, sessionId: sessionId).wrappedValue
                
                guard
                    case .object(let infoConf) = infoConfig,
                    case .object(let membersConf) = membersConfig
                else {
                    SNLog("[LibSession Error] Unable to create \(variant.rawValue) config object: Group info and member config states not loaded")
                    throw LibSessionError.unableToCreateConfigObject
                }
                
                return try groups_keys_init(
                    &keysConf,
                    &secretKey,
                    &identityPublicKey,
                    &adminSecretKey,
                    infoConf,
                    membersConf,
                    cachedDump?.data,
                    (cachedDump?.length ?? 0),
                    &error
                )
                .toConfig(keysConf, info: infoConf, members: membersConf, variant: variant, error: error)
                
            // It looks like C doesn't deal will passing pointers to null variables well so we need
            // to explicitly pass 'nil' for the admin key in this case
            case (.groupInfo, .none), (.groupMembers, .none):
                var identityPublicKey: [UInt8] = sessionId.publicKey
                
                return try (groupConfigInitCalls[variant]?(
                    &conf,
                    &identityPublicKey,
                    nil,
                    cachedDump?.data,
                    (cachedDump?.length ?? 0),
                    &error
                ))
                .toConfig(conf, variant: variant, error: error)
                
            // It looks like C doesn't deal will passing pointers to null variables well so we need
            // to explicitly pass 'nil' for the admin key in this case
            case (.groupKeys, .none):
                var identityPublicKey: [UInt8] = sessionId.publicKey
                let infoConfig: Config? = cache.config(for: .groupInfo, sessionId: sessionId).wrappedValue
                let membersConfig: Config? = cache.config(for: .groupMembers, sessionId: sessionId).wrappedValue
                
                guard
                    case .object(let infoConf) = infoConfig,
                    case .object(let membersConf) = membersConfig
                else {
                    SNLog("[LibSession Error] Unable to create \(variant.rawValue) config object: Group info and member config states not loaded")
                    throw LibSessionError.unableToCreateConfigObject
                }
                
                return try groups_keys_init(
                    &keysConf,
                    &secretKey,
                    &identityPublicKey,
                    nil,
                    infoConf,
                    membersConf,
                    cachedDump?.data,
                    (cachedDump?.length ?? 0),
                    &error
                )
                .toConfig(keysConf, info: infoConf, members: membersConf, variant: variant, error: error)
        }
    }
    
    internal static func createDump(
        config: Config?,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        timestampMs: Int64,
        using dependencies: Dependencies
    ) throws -> ConfigDump? {
        // If it doesn't need a dump then do nothing
        guard
            config.needsDump(using: dependencies),
            let dumpData: Data = try config?.dump()
        else { return nil }
        
        return ConfigDump(
            variant: variant,
            sessionId: sessionId.hexString,
            data: dumpData,
            timestampMs: timestampMs
        )
    }
    
    // MARK: - Pushes
    
    static func pendingChanges(
        _ db: Database,
        sessionIdHexString: String,
        using dependencies: Dependencies
    ) throws -> [PushData] {
        guard Identity.userExists(db, using: dependencies) else { throw LibSessionError.userDoesNotExist }
        
        // Get a list of the different config variants for the provided publicKey
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        let targetVariants: [(sessionId: SessionId, variant: ConfigDump.Variant)] = {
            switch (sessionIdHexString, try? SessionId(from: sessionIdHexString)) {
                case (userSessionId.hexString, _):
                    return ConfigDump.Variant.userVariants.map { (userSessionId, $0) }
                    
                case (_, .some(let sessionId)) where sessionId.prefix == .group:
                    return ConfigDump.Variant.groupVariants.map { (sessionId, $0) }
                    
                default: return []
            }
        }()
        
        // Extract any pending changes from the cached config entry for each variant
        return try targetVariants
            .sorted { (lhs: (SessionId, ConfigDump.Variant), rhs: (SessionId, ConfigDump.Variant)) in
                lhs.1.sendOrder < rhs.1.sendOrder
            }
            .compactMap { sessionId, variant -> PushData? in
                try dependencies[cache: .libSession]
                    .config(for: variant, sessionId: sessionId)
                    .wrappedValue
                    .map { config -> PushData? in
                        // Check if the config needs to be pushed
                        guard config.needsPush else { return nil }
                        
                        return try Result(config.push(variant: variant))
                            .onFailure { error in
                                let configCountInfo: String = config.count(for: variant)
                                
                                SNLog("[LibSession] Failed to generate push data for \(variant) config data, size: \(configCountInfo), error: \(error)")
                            }
                            .successOrThrow()
                    }
            }
    }
    
    static func markingAsPushed(
        seqNo: Int64,
        serverHash: String,
        sentTimestamp: Int64,
        variant: ConfigDump.Variant,
        sessionIdHexString: String,
        using dependencies: Dependencies
    ) -> ConfigDump? {
        let sessionId: SessionId = SessionId(hex: sessionIdHexString, dumpVariant: variant)
        
        return dependencies[cache: .libSession]
            .config(for: variant, sessionId: sessionId)
            .mutate { config -> ConfigDump? in
                guard config != nil else { return nil }
                
                // Mark the config as pushed
                config?.confirmPushed(seqNo: seqNo, hash: serverHash)
                
                // Update the result to indicate whether the config needs to be dumped
                guard config.needsPush else { return nil }
                
                return try? LibSession.createDump(
                    config: config,
                    for: variant,
                    sessionId: sessionId,
                    timestampMs: sentTimestamp,
                    using: dependencies
                )
            }
    }
    
    static func configHashes(
        for sessionIdHexString: String,
        using dependencies: Dependencies
    ) -> [String] {
        return dependencies[singleton: .storage]
            .read { db -> Set<ConfigDump.Variant> in
                guard Identity.userExists(db) else { return [] }
                
                return try ConfigDump
                    .select(.variant)
                    .filter(ConfigDump.Columns.publicKey == sessionIdHexString)
                    .asRequest(of: ConfigDump.Variant.self)
                    .fetchSet(db)
            }
            .defaulting(to: [])
            .map { variant -> [String] in
                /// Extract all existing hashes for any dumps associated with the given `sessionIdHexString`
                dependencies[cache: .libSession]
                    .config(for: variant, sessionId: SessionId(hex: sessionIdHexString, dumpVariant: variant))
                    .wrappedValue
                    .map { $0.currentHashes() }
                    .defaulting(to: [])
            }
            .reduce([], +)
    }
    
    // MARK: - Receiving
    
    static func handleConfigMessages(
        _ db: Database,
        sessionIdHexString: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo],
        using dependencies: Dependencies = Dependencies()
    ) throws {
        guard !messages.isEmpty else { return }
        
        let groupedMessages: [ConfigDump.Variant: [ConfigMessageReceiveJob.Details.MessageInfo]] = messages
            .grouped(by: { ConfigDump.Variant(namespace: $0.namespace) })
        
        let needsPush: Bool = try groupedMessages
            .sorted { lhs, rhs in lhs.key.namespace.processingOrder < rhs.key.namespace.processingOrder }
            .reduce(false) { prevNeedsPush, next -> Bool in
                let sessionId: SessionId = SessionId(hex: sessionIdHexString, dumpVariant: next.key)
                let needsPush: Bool = try dependencies[cache: .libSession]
                    .config(for: next.key, sessionId: sessionId)
                    .mutate { config in
                        do {
                            // Merge the messages (if it doesn't merge anything then don't bother trying
                            // to handle the result)
                            guard let latestServerTimestampMs: Int64 = try config?.merge(next.value) else {
                                return config.needsPush
                            }
                            
                            // Apply the updated states to the database
                            switch next.key {
                                case .userProfile:
                                    try LibSession.handleUserProfileUpdate(
                                        db,
                                        in: config,
                                        serverTimestampMs: latestServerTimestampMs,
                                        using: dependencies
                                    )
                                    
                                case .contacts:
                                    try LibSession.handleContactsUpdate(
                                        db,
                                        in: config,
                                        serverTimestampMs: latestServerTimestampMs,
                                        using: dependencies
                                    )
                                    
                                case .convoInfoVolatile:
                                    try LibSession.handleConvoInfoVolatileUpdate(
                                        db,
                                        in: config,
                                        using: dependencies
                                    )
                                    
                                case .userGroups:
                                    try LibSession.handleUserGroupsUpdate(
                                        db,
                                        in: config,
                                        serverTimestampMs: latestServerTimestampMs,
                                        using: dependencies
                                    )
                                    
                                case .groupInfo:
                                    try LibSession.handleGroupInfoUpdate(
                                        db,
                                        in: config,
                                        groupSessionId: sessionId,
                                        serverTimestampMs: latestServerTimestampMs,
                                        using: dependencies
                                    )
                                    
                                case .groupMembers:
                                    try LibSession.handleGroupMembersUpdate(
                                        db,
                                        in: config,
                                        groupSessionId: sessionId,
                                        serverTimestampMs: latestServerTimestampMs,
                                        using: dependencies
                                    )
                                    
                                case .groupKeys:
                                    try LibSession.handleGroupKeysUpdate(
                                        db,
                                        in: config,
                                        groupSessionId: sessionId,
                                        using: dependencies
                                    )
                                    
                                case .invalid: SNLog("[libSession] Failed to process merge of invalid config namespace")
                            }
                            
                            // Need to check if the config needs to be dumped (this might have changed
                            // after handling the merge changes)
                            guard config.needsDump(using: dependencies) else {
                                try ConfigDump
                                    .filter(
                                        ConfigDump.Columns.variant == next.key &&
                                        ConfigDump.Columns.publicKey == sessionId.hexString
                                    )
                                    .updateAll(
                                        db,
                                        ConfigDump.Columns.timestampMs.set(to: latestServerTimestampMs)
                                    )
                                
                                return config.needsPush
                            }
                            
                            try LibSession.createDump(
                                config: config,
                                for: next.key,
                                sessionId: sessionId,
                                timestampMs: latestServerTimestampMs,
                                using: dependencies
                            )?.upsert(db)
                        }
                        catch {
                            SNLog("[LibSession] Failed to process merge of \(next.key) config data")
                            throw error
                        }
                
                        return config.needsPush
                    }
                
                // Update the 'needsPush' state as needed
                return (prevNeedsPush || needsPush)
            }
        
        // Now that the local state has been updated, schedule a config sync if needed (this will
        // push any pending updates and properly update the state)
        guard needsPush else { return }
        
        db.afterNextTransactionNestedOnce(dedupeId: LibSession.syncDedupeId(sessionIdHexString)) { db in
            ConfigurationSyncJob.enqueue(db, sessionIdHexString: sessionIdHexString)
        }
    }
}

// MARK: - Convenience

public extension LibSession {
    static func parseCommunity(url: String) -> (room: String, server: String, publicKey: String)? {
        var cFullUrl: [CChar] = url.cArray.nullTerminated()
        var cBaseUrl: [CChar] = [CChar](repeating: 0, count: LibSession.sizeMaxCommunityBaseUrlBytes)
        var cRoom: [CChar] = [CChar](repeating: 0, count: LibSession.sizeMaxCommunityRoomBytes)
        var cPubkey: [UInt8] = [UInt8](repeating: 0, count: LibSession.sizeCommunityPubkeyBytes)
        
        guard
            community_parse_full_url(&cFullUrl, &cBaseUrl, &cRoom, &cPubkey) &&
            !String(cString: cRoom).isEmpty &&
            !String(cString: cBaseUrl).isEmpty &&
            cPubkey.contains(where: { $0 != 0 })
        else { return nil }
        
        // Note: Need to store them in variables instead of returning directly to ensure they
        // don't get freed from memory early (was seeing this happen intermittently during
        // unit tests...)
        let room: String = String(cString: cRoom)
        let baseUrl: String = String(cString: cBaseUrl)
        let pubkeyHex: String = Data(cPubkey).toHexString()
        
        return (room, baseUrl, pubkeyHex)
    }
    
    static func communityUrlFor(server: String, roomToken: String, publicKey: String) -> String {
        var cBaseUrl: [CChar] = server.cArray.nullTerminated()
        var cRoom: [CChar] = roomToken.cArray.nullTerminated()
        var cPubkey: [UInt8] = Data(hex: publicKey).cArray
        var cFullUrl: [CChar] = [CChar](repeating: 0, count: COMMUNITY_FULL_URL_MAX_LENGTH)
        community_make_full_url(&cBaseUrl, &cRoom, &cPubkey, &cFullUrl)
        
        return String(cString: cFullUrl)
    }
}

// MARK: - Convenience

private extension Optional where Wrapped == Int32 {
    func toConfig(
        _ maybeConf: UnsafeMutablePointer<config_object>?,
        variant: ConfigDump.Variant,
        error: [CChar]
    ) throws -> LibSession.Config {
        guard self == 0, let conf: UnsafeMutablePointer<config_object> = maybeConf else {
            SNLog("[LibSession Error] Unable to create \(variant.rawValue) config object: \(String(cString: error))")
            throw LibSessionError.unableToCreateConfigObject
        }
        
        switch variant {
            case .userProfile, .contacts, .convoInfoVolatile,
                .userGroups, .groupInfo, .groupMembers:
                return .object(conf)
            
            case .groupKeys, .invalid: throw LibSessionError.unableToCreateConfigObject
        }
    }
}

private extension Int32 {
    func toConfig(
        _ maybeConf: UnsafeMutablePointer<config_group_keys>?,
        info: UnsafeMutablePointer<config_object>,
        members: UnsafeMutablePointer<config_object>,
        variant: ConfigDump.Variant,
        error: [CChar]
    ) throws -> LibSession.Config {
        guard self == 0, let conf: UnsafeMutablePointer<config_group_keys> = maybeConf else {
            SNLog("[LibSession Error] Unable to create \(variant.rawValue) config object: \(String(cString: error))")
            throw LibSessionError.unableToCreateConfigObject
        }

        switch variant {
            case .groupKeys: return .groupKeys(conf, info: info, members: members)
            default: throw LibSessionError.unableToCreateConfigObject
        }
    }
}

private extension SessionId {
    init(hex: String, dumpVariant: ConfigDump.Variant) {
        switch (try? SessionId(from: hex), dumpVariant) {
            case (.some(let sessionId), _): self = sessionId
            case (_, .userProfile), (_, .contacts), (_, .convoInfoVolatile), (_, .userGroups):
                self = SessionId(.standard, hex: hex)
                
            case (_, .groupInfo), (_, .groupMembers), (_, .groupKeys):
                self = SessionId(.group, hex: hex)
                
            case (_, .invalid): self = SessionId.invalid
        }
    }
}

// MARK: - LibSession Cache

public extension LibSession {
    class Cache: LibSessionCacheType {
        public struct Key: Hashable {
            let variant: ConfigDump.Variant
            let sessionId: SessionId
        }
        
        private var configStore: [LibSession.Cache.Key: Atomic<LibSession.Config?>] = [:]
        
        public var isEmpty: Bool { configStore.isEmpty }
        
        /// Returns `true` if there is a config which needs to be pushed, but returns `false` if the configs are all up to date or haven't been
        /// loaded yet (eg. fresh install)
        public var needsSync: Bool { configStore.contains { _, atomicConf in atomicConf.needsPush } }
        
        // MARK: - Functions
        
        public func setConfig(for variant: ConfigDump.Variant, sessionId: SessionId, to config: LibSession.Config?) {
            configStore[Key(variant: variant, sessionId: sessionId)] = config.map { Atomic($0) }
        }
        
        public func config(
            for variant: ConfigDump.Variant,
            sessionId: SessionId
        ) -> Atomic<Config?> {
            return (
                configStore[Key(variant: variant, sessionId: sessionId)] ??
                Atomic(nil)
            )
        }
        
        public func removeAll() {
            configStore.removeAll()
        }
    }
}

public extension Cache {
    static let libSession: CacheConfig<LibSessionCacheType, LibSessionImmutableCacheType> = Dependencies.create(
        identifier: "libSession",
        createInstance: { _ in LibSession.Cache() },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - LibSessionCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol LibSessionImmutableCacheType: ImmutableCacheType {
    var isEmpty: Bool { get }
    var needsSync: Bool { get }
    
    func config(for variant: ConfigDump.Variant, sessionId: SessionId) -> Atomic<LibSession.Config?>
}

public protocol LibSessionCacheType: LibSessionImmutableCacheType, MutableCacheType {
    var isEmpty: Bool { get }
    var needsSync: Bool { get }
    
    func setConfig(for variant: ConfigDump.Variant, sessionId: SessionId, to config: LibSession.Config?)
    func config(for variant: ConfigDump.Variant, sessionId: SessionId) -> Atomic<LibSession.Config?>
    func removeAll()
}
