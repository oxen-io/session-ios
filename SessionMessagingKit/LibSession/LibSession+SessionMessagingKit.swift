// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtil
import SessionUtilitiesKit

// MARK: - Cache

public extension Cache {
    static let libSession: CacheConfig<LibSessionCacheType, LibSessionImmutableCacheType> = Dependencies.create(
        identifier: "libSession",
        createInstance: { dependencies in NoopLibSessionCache(using: dependencies) },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - LibSession

public extension LibSession {
    internal static func syncDedupeId(_ swarmPublicKey: String) -> String {
        return "EnqueueConfigurationSyncJob-\(swarmPublicKey)"   // stringlint:ignore
    }
}

// MARK: - Convenience

public extension LibSession {
    static func parseCommunity(url: String) -> (room: String, server: String, publicKey: String)? {
        var cBaseUrl: [CChar] = [CChar](repeating: 0, count: COMMUNITY_BASE_URL_MAX_LENGTH)
        var cRoom: [CChar] = [CChar](repeating: 0, count: COMMUNITY_ROOM_MAX_LENGTH)
        var cPubkey: [UInt8] = [UInt8](repeating: 0, count: OpenGroup.pubkeyByteLength)
        
        guard
            var cFullUrl: [CChar] = url.cString(using: .utf8),
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
    
    static func communityUrlFor(server: String?, roomToken: String?, publicKey: String?) -> String? {
        guard
            var cBaseUrl: [CChar] = server?.cString(using: .utf8),
            var cRoom: [CChar] = roomToken?.cString(using: .utf8),
            let publicKey: String = publicKey
        else { return nil }
        
        var cPubkey: [UInt8] = Array(Data(hex: publicKey))
        var cFullUrl: [CChar] = [CChar](repeating: 0, count: COMMUNITY_FULL_URL_MAX_LENGTH)
        community_make_full_url(&cBaseUrl, &cRoom, &cPubkey, &cFullUrl)
        
        return String(cString: cFullUrl)
    }
}

// MARK: - ConfigStore

private class ConfigStore {
    private struct Key: Hashable {
        let sessionId: SessionId
        let variant: ConfigDump.Variant
        
        init(sessionId: SessionId, variant: ConfigDump.Variant) {
            self.sessionId = sessionId
            self.variant = variant
        }
    }
    
    private var store: [Key: LibSession.Config] = [:]
    public var isEmpty: Bool { store.isEmpty }
    public var needsSync: Bool { store.contains { _, config in config.needsPush } }
    
    subscript (sessionId: SessionId, variant: ConfigDump.Variant) -> LibSession.Config? {
        get { return (store[Key(sessionId: sessionId, variant: variant)] ?? nil) }
        set { store[Key(sessionId: sessionId, variant: variant)] = newValue }
    }
    
    subscript (sessionId: SessionId) -> [LibSession.Config] {
        get { return ConfigDump.Variant.allCases.compactMap { store[Key(sessionId: sessionId, variant: $0)] } }
    }
    
    deinit {
        /// Group configs are a little complicated because they contain the info & members confs so we need some special handling to
        /// properly free memory here, firstly we need to retrieve all groupKeys configs
        let groupKeysConfigs: [(key: Key, value: LibSession.Config)] = store
            .filter { _, config in
                switch config {
                    case .groupKeys: return true
                    default: return false
                }
            }
        
        /// Now we remove all configss associated to the same sessionId from the store
        groupKeysConfigs.forEach { key, _ in
            ConfigDump.Variant.allCases.forEach { store.removeValue(forKey: Key(sessionId: key.sessionId, variant: $0)) }
        }
        
        /// Then free the group configs
        groupKeysConfigs.forEach { _, config in
            switch config {
                case .groupKeys(let keysConf, let infoConf, let membersConf):
                    groups_keys_free(keysConf)
                    config_free(infoConf)
                    config_free(membersConf)
                    
                default: break
            }
        }
        
        /// Finally we free any remaining configs
        store.forEach { _, config in
            switch config {
                case .groupKeys: break    // Shouldn't happen
                case .userProfile(let conf), .contacts(let conf),
                    .convoInfoVolatile(let conf), .userGroups(let conf),
                    .groupInfo(let conf), .groupMembers(let conf):
                    config_free(conf)
            }
        }
        store.removeAll()
    }
}
                                                                     
// MARK: - SessionUtil Cache

public extension LibSession {
    class Cache: LibSessionCacheType {
        private var configStore: ConfigStore = ConfigStore()
        
        public let dependencies: Dependencies
        public let userSessionId: SessionId
        public var isEmpty: Bool { configStore.isEmpty }
        
        /// Returns `true` if there is a config which needs to be pushed, but returns `false` if the configs are all up to date or haven't been
        /// loaded yet (eg. fresh install)
        public var needsSync: Bool { configStore.needsSync }
        
        // MARK: - Initialization
        
        public init(userSessionId: SessionId, using dependencies: Dependencies) {
            self.userSessionId = userSessionId
            self.dependencies = dependencies
        }
        
        // MARK: - State Management
        
        public func loadState(_ db: Database) {
            // Ensure we have the ed25519 key and that we haven't already loaded the state before
            // we continue
            guard
                configStore.isEmpty,
                let ed25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db)
            else { return Log.warn(.libSession, "Ignoring loadState due to existing state") }
            
            // Retrieve the existing dumps from the database
            let existingDumps: [ConfigDump] = ((try? ConfigDump.fetchSet(db)) ?? [])
                .sorted { lhs, rhs in lhs.variant.loadOrder < rhs.variant.loadOrder }
            let existingDumpVariants: Set<ConfigDump.Variant> = existingDumps
                .map { $0.variant }
                .asSet()
            let missingRequiredVariants: Set<ConfigDump.Variant> = ConfigDump.Variant.userVariants
                .subtracting(existingDumpVariants)
            let groupsByKey: [String: ClosedGroup] = (try? ClosedGroup
                .filter(
                    ClosedGroup.Columns.threadId > SessionId.Prefix.group.rawValue &&
                    ClosedGroup.Columns.threadId < SessionId.Prefix.group.endOfRangeString
                )
                .fetchAll(db)
                .reduce(into: [:]) { result, next in result[next.threadId] = next })
                .defaulting(to: [:])
            let groupsWithNoDumps: [ClosedGroup] = groupsByKey
                .values
                .filter { group in !existingDumps.contains(where: { $0.sessionId.hexString == group.id }) }
            
            // Create the config records for each dump
            existingDumps.forEach { dump in
                configStore[dump.sessionId, dump.variant] = try? loadState(
                    for: dump.variant,
                    sessionId: dump.sessionId,
                    userEd25519SecretKey: ed25519KeyPair.secretKey,
                    groupEd25519SecretKey: groupsByKey[dump.sessionId.hexString]?
                        .groupIdentityPrivateKey
                        .map { Array($0) },
                    cachedData: dump.data
                )
            }
            
            /// It's possible for there to not be dumps for all of the configs so we load any missing ones to ensure functionality
            /// works smoothly
            ///
            /// It's also possible for a group to get created but for a dump to not be created (eg. when a crash happens at the right time), to
            /// handle this we also load the state of any groups which don't have dumps if they aren't in the `invited` state (those in
            /// the `invited` state will have their state loaded if the invite is accepted)
            loadDefaultStatesFor(
                userConfigVariants: missingRequiredVariants,
                groups: groupsWithNoDumps,
                userSessionId: userSessionId,
                userEd25519KeyPair: ed25519KeyPair
            )
            Log.info(.libSession, "Completed loadState")
        }
        
        public func loadDefaultStatesFor(
            userConfigVariants: Set<ConfigDump.Variant>,
            groups: [ClosedGroup],
            userSessionId: SessionId,
            userEd25519KeyPair: KeyPair
        ) {
            /// Create an empty state for the specified user config variants
            userConfigVariants.forEach { variant in
                configStore[userSessionId, variant] = try? loadState(
                    for: variant,
                    sessionId: userSessionId,
                    userEd25519SecretKey: userEd25519KeyPair.secretKey,
                    groupEd25519SecretKey: nil,
                    cachedData: nil
                )
            }
            
            /// Create empty group states for the provided groups
            groups
                .filter { $0.invited != true }
                .forEach { group in
                    _ = try? createAndLoadGroupState(
                        groupSessionId: SessionId(.group, hex: group.id),
                        userED25519KeyPair: userEd25519KeyPair,
                        groupIdentityPrivateKey: group.groupIdentityPrivateKey
                    )
                }
        }
        
        private func loadState(
            for variant: ConfigDump.Variant,
            sessionId: SessionId,
            userEd25519SecretKey: [UInt8],
            groupEd25519SecretKey: [UInt8]?,
            cachedData: Data?
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
                    throw LibSessionError.unableToCreateConfigObject
                        .logging("Unable to create \(variant.rawValue) config object")
                    
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
                    
                    guard
                        case .groupInfo(let infoConf) = configStore[sessionId, .groupInfo],
                        case .groupMembers(let membersConf) = configStore[sessionId, .groupMembers]
                    else {
                        throw LibSessionError.unableToCreateConfigObject
                            .logging("Unable to create \(variant.rawValue) config object: Group info and member config states not loaded")
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
                    
                    guard
                        case .groupInfo(let infoConf) = configStore[sessionId, .groupInfo],
                        case .groupMembers(let membersConf) = configStore[sessionId, .groupMembers]
                    else {
                        throw LibSessionError.unableToCreateConfigObject
                            .logging("Unable to create \(variant.rawValue) config object: Group info and member config states not loaded")
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
        
        public func hasConfig(for variant: ConfigDump.Variant, sessionId: SessionId) -> Bool {
            return (configStore[sessionId, variant] != nil)
        }
        
        public func config(for variant: ConfigDump.Variant, sessionId: SessionId) -> Config? {
            return configStore[sessionId, variant]
        }
        
        public func setConfig(for variant: ConfigDump.Variant, sessionId: SessionId, to config: Config) {
            configStore[sessionId, variant] = config
        }
        
        public func removeConfigs(for sessionId: SessionId) {
            // First retrieve the configs stored for the sessionId
            let configs: [LibSession.Config] = configStore[sessionId]
            let keysConfig: LibSession.Config? = configs.first { config in
                switch config {
                    case .groupKeys: return true
                    default: return false
                }
            }
            
            // Then remove them from the ConfigStore (can't have something else accessing them)
            ConfigDump.Variant.allCases.forEach { configStore[sessionId, $0] = nil }
            
            // Finally we need to free them (if we got a `groupKeys` config then that includes
            // the other confs for that sessionId so we can free them all at once, otherwise loop
            // and freee everything
            switch keysConfig {
                case .groupKeys(let keysConf, let infoConf, let membersConf):
                    groups_keys_free(keysConf)
                    config_free(infoConf)
                    config_free(membersConf)
                
                default:
                    configs.forEach { config in
                        switch config {
                            case .groupKeys: break    // Should be handled above
                            case .userProfile(let conf), .contacts(let conf),
                                .convoInfoVolatile(let conf), .userGroups(let conf),
                                .groupInfo(let conf), .groupMembers(let conf):
                                config_free(conf)
                        }
                    }
            }
        }
        
        public func createDump(
            config: Config?,
            for variant: ConfigDump.Variant,
            sessionId: SessionId,
            timestampMs: Int64
        ) throws -> ConfigDump? {
            // If it doesn't need a dump then do nothing
            guard
                configNeedsDump(config),
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
        
        public func performAndPushChange(
            _ db: Database,
            for variant: ConfigDump.Variant,
            sessionId: SessionId,
            change: (Config?) throws -> ()
        ) throws {
            // To prevent crashes by trying to make an invalid change due to incorrect state being
            // provided by a client, if we want to change one of the group configs then check if we
            // are a group admin first
            switch variant {
                case .groupInfo, .groupMembers, .groupKeys:
                    guard isAdmin(groupSessionId: sessionId) else {
                        throw LibSessionError.attemptedToModifyGroupWithoutAdminKey
                    }

                    
                default: break
            }
            
            guard let config: Config = configStore[sessionId, variant] else { return }
            
            do {
                // Peform the change
                try change(config)
                
                // If an error occurred during the change then actually throw it to prevent
                // any database change from completing
                try LibSessionError.throwIfNeeded(config)

                // Only create a config dump if we need to
                if configNeedsDump(config) {
                    try createDump(
                        config: config,
                        for: variant,
                        sessionId: sessionId,
                        timestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                    )?.upsert(db)
                }
            }
            catch {
                Log.error(.libSession, "Failed to update/dump updated \(variant) config data due to error: \(error)")
                throw error
            }
            
            // Make sure we need a push before scheduling one
            guard config.needsPush else { return }
            
            db.afterNextTransactionNestedOnce(dedupeId: LibSession.syncDedupeId(sessionId.hexString), using: dependencies) { [dependencies] db in
                ConfigurationSyncJob.enqueue(db, swarmPublicKey: sessionId.hexString, using: dependencies)
            }
        }
        
        public func pendingChanges(
            _ db: Database,
            swarmPubkey: String
        ) throws -> PendingChanges {
            guard Identity.userExists(db, using: dependencies) else { throw LibSessionError.userDoesNotExist }
            
            // Get a list of the different config variants for the provided publicKey
            let userSessionId: SessionId = dependencies[cache: .general].sessionId
            let targetVariants: [(sessionId: SessionId, variant: ConfigDump.Variant)] = {
                switch (swarmPubkey, try? SessionId(from: swarmPubkey)) {
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
                .reduce(into: PendingChanges()) { result, info in
                    guard let config: Config = configStore[info.sessionId, info.variant] else { return }
                    
                    // Add any obsolete hashes to be removed (want to do this even if there isn't a pending push
                    // to ensure we clean things up)
                    result.append(hashes: config.obsoleteHashes())
                    
                    // Only generate the push data if we need to do a push
                    guard config.needsPush else { return }
                    
                    guard let data: PendingChanges.PushData = config.push(variant: info.variant) else {
                        let configCountInfo: String = config.count(for: info.variant)
                        
                        throw LibSessionError(
                            config,
                            fallbackError: .unableToGeneratePushData,
                            logMessage: "Failed to generate push data for \(info.variant) config data, size: \(configCountInfo), error"
                        )
                    }
                    
                    result.append(data: data)
                }
        }
        
        public func markingAsPushed(
            seqNo: Int64,
            serverHash: String,
            sentTimestamp: Int64,
            variant: ConfigDump.Variant,
            swarmPublicKey: String
        ) -> ConfigDump? {
            let sessionId: SessionId = SessionId(hex: swarmPublicKey, dumpVariant: variant)
            
            guard let config: Config = configStore[sessionId, variant] else { return nil }
            
            // Mark the config as pushed
            config.confirmPushed(seqNo: seqNo, hash: serverHash)
            
            // Update the result to indicate whether the config needs to be dumped
            guard config.needsPush else { return nil }
            
            return try? createDump(
                config: config,
                for: variant,
                sessionId: sessionId,
                timestampMs: sentTimestamp
            )
        }
        
        // MARK: - Config Message Handling
        
        public func configNeedsDump(_ config: LibSession.Config?) -> Bool {
            switch config {
                case .none: return false
                case .userProfile(let conf), .contacts(let conf),
                    .convoInfoVolatile(let conf), .userGroups(let conf),
                    .groupInfo(let conf), .groupMembers(let conf):
                    return config_needs_dump(conf)
                case .groupKeys(let conf, _, _): return groups_keys_needs_dump(conf)
            }
        }
        
        public func configHashes(for swarmPublicKey: String) -> [String] {
            guard let sessionId: SessionId = try? SessionId(from: swarmPublicKey) else { return [] }
            
            /// We `mutate` because `libSession` isn't thread safe and we don't want to worry about another thread messing
            /// with the hashes while we retrieve them
            return configStore[sessionId]
                .compactMap { config in config.currentHashes() }
                .reduce([], +)
        }
        
        public func handleConfigMessages(
            _ db: Database,
            swarmPublicKey: String,
            messages: [ConfigMessageReceiveJob.Details.MessageInfo]
        ) throws {
            guard !messages.isEmpty else { return }
            guard !swarmPublicKey.isEmpty else { throw MessageReceiverError.noThread }
            
            let groupedMessages: [ConfigDump.Variant: [ConfigMessageReceiveJob.Details.MessageInfo]] = messages
                .grouped(by: { ConfigDump.Variant(namespace: $0.namespace) })
            
            try groupedMessages
                .sorted { lhs, rhs in lhs.key.namespace.processingOrder < rhs.key.namespace.processingOrder }
                .forEach { variant, message in
                    let sessionId: SessionId = SessionId(hex: swarmPublicKey, dumpVariant: variant)
                    let config: Config? = configStore[sessionId, variant]
                    
                    do {
                        // Merge the messages (if it doesn't merge anything then don't bother trying
                        // to handle the result)
                        guard let latestServerTimestampMs: Int64 = try config?.merge(message) else { return }
                        
                        // Apply the updated states to the database
                        switch variant {
                            case .userProfile:
                                try handleUserProfileUpdate(
                                    db,
                                    in: config,
                                    serverTimestampMs: latestServerTimestampMs
                                )
                                
                            case .contacts:
                                try handleContactsUpdate(
                                    db,
                                    in: config,
                                    serverTimestampMs: latestServerTimestampMs
                                )
                                
                            case .convoInfoVolatile:
                                try handleConvoInfoVolatileUpdate(
                                    db,
                                    in: config
                                )
                                
                            case .userGroups:
                                try handleUserGroupsUpdate(
                                    db,
                                    in: config,
                                    serverTimestampMs: latestServerTimestampMs
                                )
                                
                            case .groupInfo:
                                try handleGroupInfoUpdate(
                                    db,
                                    in: config,
                                    groupSessionId: sessionId,
                                    serverTimestampMs: latestServerTimestampMs
                                )
                                
                            case .groupMembers:
                                try handleGroupMembersUpdate(
                                    db,
                                    in: config,
                                    groupSessionId: sessionId,
                                    serverTimestampMs: latestServerTimestampMs
                                )
                                
                            case .groupKeys:
                                try handleGroupKeysUpdate(
                                    db,
                                    in: config,
                                    groupSessionId: sessionId
                                )
                            
                            case .invalid: Log.error(.libSession, "Failed to process merge of invalid config namespace")
                        }
                        
                        // Need to check if the config needs to be dumped (this might have changed
                        // after handling the merge changes)
                        guard configNeedsDump(config) else {
                            try ConfigDump
                                .filter(
                                    ConfigDump.Columns.variant == variant &&
                                    ConfigDump.Columns.publicKey == sessionId.hexString
                                )
                                .updateAll(
                                    db,
                                    ConfigDump.Columns.timestampMs.set(to: latestServerTimestampMs)
                                )
                            
                            return
                        }
                        
                        try createDump(
                            config: config,
                            for: variant,
                            sessionId: sessionId,
                            timestampMs: latestServerTimestampMs
                        )?.upsert(db)
                    }
                    catch {
                        Log.error(.libSession, "Failed to process merge of \(variant) config data")
                        throw error
                    }
                }
            
            // Now that the local state has been updated, schedule a config sync if needed (this will
            // push any pending updates and properly update the state)
            db.afterNextTransactionNestedOnce(dedupeId: LibSession.syncDedupeId(swarmPublicKey), using: dependencies) { [dependencies] db in
                ConfigurationSyncJob.enqueue(db, swarmPublicKey: swarmPublicKey, using: dependencies)
            }
        }
        
        public func unsafeDirectMergeConfigMessage(
            swarmPublicKey: String,
            messages: [ConfigMessageReceiveJob.Details.MessageInfo]
        ) throws {
            guard !messages.isEmpty else { return }
            
            let groupedMessages: [ConfigDump.Variant: [ConfigMessageReceiveJob.Details.MessageInfo]] = messages
                .grouped(by: { ConfigDump.Variant(namespace: $0.namespace) })
            
            try groupedMessages
                .sorted { lhs, rhs in lhs.key.namespace.processingOrder < rhs.key.namespace.processingOrder }
                .forEach { [configStore] variant, message in
                    let sessionId: SessionId = SessionId(hex: swarmPublicKey, dumpVariant: variant)
                    _ = try configStore[sessionId, variant]?.merge(message)
                }
        }
        
        // MARK: - Value Access
        
        public func pinnedPriority(
            _ db: Database,
            threadId: String,
            threadVariant: SessionThread.Variant
        ) -> Int32? {
            let userSessionId: SessionId = dependencies[cache: .general].sessionId
            
            switch threadVariant {
                case .contact where threadId == userSessionId.hexString:
                    return configStore[userSessionId, .userProfile]?.pinnedPriority(
                        db,
                        threadId: threadId,
                        threadVariant: threadVariant
                    )
                    
                case .contact:
                    return configStore[userSessionId, .contacts]?.pinnedPriority(
                        db,
                        threadId: threadId,
                        threadVariant: threadVariant
                    )
                    
                case .community, .group, .legacyGroup:
                    return configStore[userSessionId, .userGroups]?.pinnedPriority(
                        db,
                        threadId: threadId,
                        threadVariant: threadVariant
                    )
            }
        }
        
        public func disappearingMessagesConfig(
            threadId: String,
            threadVariant: SessionThread.Variant
        ) -> DisappearingMessagesConfiguration? {
            let userSessionId: SessionId = dependencies[cache: .general].sessionId
            
            switch threadVariant {
                case .contact where threadId == userSessionId.hexString:
                    return configStore[userSessionId, .userProfile]?.disappearingMessagesConfig(
                        threadId: threadId,
                        threadVariant: threadVariant
                    )
                    
                case .contact:
                    return configStore[userSessionId, .contacts]?.disappearingMessagesConfig(
                        threadId: threadId,
                        threadVariant: threadVariant
                    )
                    
                case .community, .group, .legacyGroup:
                    return configStore[userSessionId, .userGroups]?.disappearingMessagesConfig(
                        threadId: threadId,
                        threadVariant: threadVariant
                    )
            }
        }
        
        public func isAdmin(groupSessionId: SessionId) -> Bool {
            guard case .groupKeys(let conf, _, _) = configStore[groupSessionId, .groupKeys] else {
                return false
            }
            
            return groups_keys_is_admin(conf)
        }
    }
}

// MARK: - SessionUtilCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol LibSessionImmutableCacheType: ImmutableCacheType {
    var userSessionId: SessionId { get }
    var isEmpty: Bool { get }
    
    func hasConfig(for variant: ConfigDump.Variant, sessionId: SessionId) -> Bool
}

/// The majority `libSession` functions can only be accessed via the mutable cache because `libSession` isn't thread safe so if we try
/// to read/write values while another thread is touching the same data then the app can crash due to bad memory issues
public protocol LibSessionCacheType: LibSessionImmutableCacheType, MutableCacheType {
    var dependencies: Dependencies { get }
    var userSessionId: SessionId { get }
    var isEmpty: Bool { get }
    var needsSync: Bool { get }
    
    // MARK: - State Management
    
    func loadState(_ db: Database)
    func loadDefaultStatesFor(
        userConfigVariants: Set<ConfigDump.Variant>,
        groups: [ClosedGroup],
        userSessionId: SessionId,
        userEd25519KeyPair: KeyPair
    )
    func hasConfig(for variant: ConfigDump.Variant, sessionId: SessionId) -> Bool
    func config(for variant: ConfigDump.Variant, sessionId: SessionId) -> LibSession.Config?
    func setConfig(for variant: ConfigDump.Variant, sessionId: SessionId, to config: LibSession.Config)
    func removeConfigs(for sessionId: SessionId)
    func createDump(
        config: LibSession.Config?,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        timestampMs: Int64
    ) throws -> ConfigDump?
    
    // MARK: - Pushes
    
    func performAndPushChange(
        _ db: Database,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        change: @escaping (LibSession.Config?) throws -> ()
    ) throws
    func pendingChanges(_ db: Database, swarmPubkey: String) throws -> LibSession.PendingChanges
    func markingAsPushed(
        seqNo: Int64,
        serverHash: String,
        sentTimestamp: Int64,
        variant: ConfigDump.Variant,
        swarmPublicKey: String
    ) -> ConfigDump?
    
    // MARK: - Config Message Handling
    
    func configNeedsDump(_ config: LibSession.Config?) -> Bool
    func configHashes(for swarmPubkey: String) -> [String]
    
    func handleConfigMessages(
        _ db: Database,
        swarmPublicKey: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo]
    ) throws
    
    /// This function takes config messages and just triggers the merge into `libSession`
    ///
    /// **Note:** This function should only be used in a situation where we want to retrieve the data from a config message as using it
    /// elsewhere will result in the database getting out of sync with the config state
    func unsafeDirectMergeConfigMessage(
        swarmPublicKey: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo]
    ) throws
    
    // MARK: - Value Access
    
    func pinnedPriority(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> Int32?
    func disappearingMessagesConfig(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> DisappearingMessagesConfiguration?
    func isAdmin(groupSessionId: SessionId) -> Bool
}

private final class NoopLibSessionCache: LibSessionCacheType {
    let dependencies: Dependencies
    let userSessionId: SessionId = .invalid
    let isEmpty: Bool = true
    let needsSync: Bool = false
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - State Management
    
    func loadState(_ db: Database) {}
    func loadDefaultStatesFor(
        userConfigVariants: Set<ConfigDump.Variant>,
        groups: [ClosedGroup],
        userSessionId: SessionId,
        userEd25519KeyPair: KeyPair
    ) {}
    func hasConfig(for variant: ConfigDump.Variant, sessionId: SessionId) -> Bool { return false }
    func config(for variant: ConfigDump.Variant, sessionId: SessionId) -> LibSession.Config? { return nil }
    func setConfig(for variant: ConfigDump.Variant, sessionId: SessionId, to config: LibSession.Config) {}
    func removeConfigs(for sessionId: SessionId) {}
    func createDump(
        config: LibSession.Config?,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        timestampMs: Int64
    ) throws -> ConfigDump? {
        return nil
    }
    
    // MARK: - Pushes
    
    func performAndPushChange(
        _ db: Database,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        change: (LibSession.Config?) throws -> ()
    ) throws {}
    
    func pendingChanges(_ db: GRDB.Database, swarmPubkey: String) throws -> LibSession.PendingChanges {
        return LibSession.PendingChanges()
    }
    
    func markingAsPushed(seqNo: Int64, serverHash: String, sentTimestamp: Int64, variant: ConfigDump.Variant, swarmPublicKey: String) -> ConfigDump? {
        return nil
    }
    
    // MARK: - Config Message Handling
    
    func configNeedsDump(_ config: LibSession.Config?) -> Bool { return false }
    func configHashes(for swarmPubkey: String) -> [String] { return [] }
    func handleConfigMessages(
        _ db: Database,
        swarmPublicKey: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo]
    ) throws {}
    func unsafeDirectMergeConfigMessage(
        swarmPublicKey: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo]
    ) throws {}
    
    // MARK: - Value Access
    
    func pinnedPriority(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> Int32? { return nil }
    func disappearingMessagesConfig(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> DisappearingMessagesConfiguration? { return nil }
    func isAdmin(groupSessionId: SessionId) -> Bool { return false }
}

// MARK: - Convenience

private extension Optional where Wrapped == Int32 {
    func toConfig(
        _ maybeConf: UnsafeMutablePointer<config_object>?,
        variant: ConfigDump.Variant,
        error: [CChar]
    ) throws -> LibSession.Config {
        guard self == 0, let conf: UnsafeMutablePointer<config_object> = maybeConf else {
            throw LibSessionError.unableToCreateConfigObject
                .logging("Unable to create \(variant.rawValue) config object: \(String(cString: error))")
        }
        
        switch variant {
            case .userProfile: return .userProfile(conf)
            case .contacts: return .contacts(conf)
            case .convoInfoVolatile: return .convoInfoVolatile(conf)
            case .userGroups: return .userGroups(conf)
            case .groupInfo: return .groupInfo(conf)
            case .groupMembers: return .groupMembers(conf)
            
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
            throw LibSessionError.unableToCreateConfigObject
                .logging("Unable to create \(variant.rawValue) config object: \(String(cString: error))")
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
