// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtil
import SessionUtilitiesKit

// MARK: - LibSession

public extension LibSession {
    struct ConfResult {
        let needsPush: Bool
        let needsDump: Bool
    }
    
    struct IncomingConfResult {
        let needsPush: Bool
        let needsDump: Bool
        let messageHashes: [String]
        let latestSentTimestamp: TimeInterval
        
        var result: ConfResult { ConfResult(needsPush: needsPush, needsDump: needsDump) }
    }
    
    // MARK: - PendingChanges
    
    struct PendingChanges {
        public struct PushData {
            let data: Data
            let seqNo: Int64
            let variant: ConfigDump.Variant
        }
        
        var pushData: [PushData]
        var obsoleteHashes: Set<String>
        
        init(pushData: [PushData] = [], obsoleteHashes: Set<String> = []) {
            self.pushData = pushData
            self.obsoleteHashes = obsoleteHashes
        }
        
        mutating func append(data: PushData? = nil, hashes: [String] = []) {
            if let data: PushData = data {
                pushData.append(data)
            }
            
            obsoleteHashes.insert(contentsOf: Set(hashes))
        }
    }
    
    // MARK: - Configs
    
    // FIXME: This is a temporary work-around for fixing the database unit tests (it's done properly in the Groups Rebuild branch but would require too many changes to pull across properly)
    static func config(for variant: ConfigDump.Variant, publicKey: String) -> Atomic<UnsafeMutablePointer<config_object>?> {
        return LibSession.dependencies.wrappedValue.caches[.libSession]
            .config(for: variant, publicKey: publicKey)
    }
    
    // MARK: - Variables
    
    // FIXME: This is a temporary work-around for fixing the database unit tests (it's done properly in the Groups Rebuild branch but would require too many changes to pull across properly)
    private static var dependencies: Atomic<Dependencies> = Atomic(Dependencies())
    
    internal static func syncDedupeId(_ publicKey: String) -> String {
        return "EnqueueConfigurationSyncJob-\(publicKey)"   // stringlint:disable
    }
    
    static var libSessionVersion: String { String(cString: LIBSESSION_UTIL_VERSION_STR) }
    
    // MARK: - Loading
    
    static func clearMemoryState(using dependencies: Dependencies) {
        dependencies.caches.mutate(cache: .libSession) { $0.removeAll() }
    }
    
    static func loadState(
        _ db: Database? = nil,
        userPublicKey: String,
        ed25519SecretKey: [UInt8]?,
        using dependencies: Dependencies
    ) {
        // Ensure we have the ed25519 key and that we haven't already loaded the state before
        // we continue
        guard
            let secretKey: [UInt8] = ed25519SecretKey,
            dependencies.caches[.libSession].isEmpty
        else { return SNLog("[LibSession] Ignoring loadState for '\(userPublicKey)' due to existing state") }
        
        // If we weren't given a database instance then get one
        guard let db: Database = db else {
            Storage.shared.read { db in
                LibSession.loadState(db, userPublicKey: userPublicKey, ed25519SecretKey: secretKey, using: dependencies)
            }
            return
        }
        
        // FIXME: This is a temporary work-around for fixing the database unit tests (it's done properly in the Groups Rebuild branch but would require too many changes to pull across properly)
        LibSession.dependencies = Atomic(dependencies)
        
        // Retrieve the existing dumps from the database
        let existingDumps: Set<ConfigDump> = ((try? ConfigDump.fetchSet(db)) ?? [])
        let existingDumpVariants: Set<ConfigDump.Variant> = existingDumps
            .map { $0.variant }
            .asSet()
        let missingRequiredVariants: Set<ConfigDump.Variant> = ConfigDump.Variant.userVariants
            .asSet()
            .subtracting(existingDumpVariants)
        
        // Create the 'config_object' records for each dump
        dependencies.caches.mutate(cache: .libSession) { cache in
            existingDumps.forEach { dump in
                cache.setConfig(
                    for: dump.variant,
                    publicKey: dump.publicKey,
                    to: try? LibSession.loadState(
                        for: dump.variant,
                        secretKey: secretKey,
                        cachedData: dump.data
                    )
                )
            }
            
            missingRequiredVariants.forEach { variant in
                cache.setConfig(
                    for: variant,
                    publicKey: userPublicKey,
                    to: try? LibSession.loadState(
                        for: variant,
                        secretKey: secretKey,
                        cachedData: nil
                    )
                )
            }
        }
        
        SNLog("[LibSession] Completed loadState for '\(userPublicKey)'")
    }
    
    private static func loadState(
        for variant: ConfigDump.Variant,
        secretKey ed25519SecretKey: [UInt8],
        cachedData: Data?
    ) throws -> UnsafeMutablePointer<config_object>? {
        // Setup initial variables (including getting the memory address for any cached data)
        var conf: UnsafeMutablePointer<config_object>? = nil
        var error: [CChar] = [CChar](repeating: 0, count: 256)
        let cachedDump: (data: UnsafePointer<UInt8>, length: Int)? = cachedData?.withUnsafeBytes { unsafeBytes in
            return unsafeBytes.baseAddress.map {
                (
                    $0.assumingMemoryBound(to: UInt8.self),
                    unsafeBytes.count
                )
            }
        }
        
        // Try to create the object
        var secretKey: [UInt8] = ed25519SecretKey
        let result: Int32 = try {
            switch variant {
                case .invalid:
                    SNLog("[LibSession Error] Unable to create \(variant.rawValue) config object")
                    throw LibSessionError.unableToCreateConfigObject
                    
                case .userProfile:
                    return user_profile_init(&conf, &secretKey, cachedDump?.data, (cachedDump?.length ?? 0), &error)

                case .contacts:
                    return contacts_init(&conf, &secretKey, cachedDump?.data, (cachedDump?.length ?? 0), &error)

                case .convoInfoVolatile:
                    return convo_info_volatile_init(&conf, &secretKey, cachedDump?.data, (cachedDump?.length ?? 0), &error)

                case .userGroups:
                    return user_groups_init(&conf, &secretKey, cachedDump?.data, (cachedDump?.length ?? 0), &error)
            }
        }()
        
        guard result == 0 else {
            SNLog("[LibSession Error] Unable to create \(variant.rawValue) config object: \(String(cString: error))")
            throw LibSessionError.unableToCreateConfigObject
        }
        
        return conf
    }
    
    internal static func createDump(
        conf: UnsafeMutablePointer<config_object>?,
        for variant: ConfigDump.Variant,
        publicKey: String,
        timestampMs: Int64
    ) throws -> ConfigDump? {
        guard conf != nil else { throw LibSessionError.nilConfigObject }
        
        // If it doesn't need a dump then do nothing
        guard config_needs_dump(conf) else { return nil }
        
        var dumpResult: UnsafeMutablePointer<UInt8>? = nil
        var dumpResultLen: Int = 0
        config_dump(conf, &dumpResult, &dumpResultLen)
        
        // If we got an error then throw it
        try LibSessionError.throwIfNeeded(conf)
        
        guard let dumpResult: UnsafeMutablePointer<UInt8> = dumpResult else { return nil }
        
        let dumpData: Data = Data(bytes: dumpResult, count: dumpResultLen)
        dumpResult.deallocate()
        
        return ConfigDump(
            variant: variant,
            publicKey: publicKey,
            data: dumpData,
            timestampMs: timestampMs
        )
    }
    
    // MARK: - Pushes
    
    static func pendingChanges(
        _ db: Database,
        publicKey: String
    ) throws -> PendingChanges {
        guard Identity.userExists(db) else { throw LibSessionError.userDoesNotExist }
        
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        var existingDumpVariants: Set<ConfigDump.Variant> = try ConfigDump
            .select(.variant)
            .filter(ConfigDump.Columns.publicKey == publicKey)
            .asRequest(of: ConfigDump.Variant.self)
            .fetchSet(db)
        
        // Ensure we always check the required user config types for changes even if there is no dump
        // data yet (to deal with first launch cases)
        if publicKey == userPublicKey {
            ConfigDump.Variant.userVariants.forEach { existingDumpVariants.insert($0) }
        }
        
        /// Ensure we always check the required user config types for changes even if there is no dump data yet (to deal with first launch cases)
        ///
        /// **Note:** We `mutate` when retrieving the pending changes here because we want to ensure no other threads can modify the
        /// config while we are reading (which could result in crashes)
        return try existingDumpVariants
            .reduce(into: PendingChanges()) { result, variant in
                try LibSession
                    .config(for: variant, publicKey: publicKey)
                    .mutate { conf in
                        guard conf != nil else { return }
                        
                        // Check if the config needs to be pushed
                        guard config_needs_push(conf) else {
                            // If not then try retrieve any obsolete hashes to be removed
                            guard let cObsoletePtr: UnsafeMutablePointer<config_string_list> = config_old_hashes(conf) else {
                                return
                            }
                            
                            let obsoleteHashes: [String] = [String](
                                pointer: cObsoletePtr.pointee.value,
                                count: cObsoletePtr.pointee.len,
                                defaultValue: []
                            )
                            
                            // If there are no obsolete hashes then no need to return anything
                            guard !obsoleteHashes.isEmpty else { return }
                            
                            result.append(hashes: obsoleteHashes)
                            return
                        }
                        
                        guard let cPushData: UnsafeMutablePointer<config_push_data> = config_push(conf) else {
                            let configCountInfo: String = {
                                switch variant {
                                    case .userProfile: return "1 profile"  // stringlint:disable
                                    case .contacts: return "\(contacts_size(conf)) contacts"  // stringlint:disable
                                    case .userGroups: return "\(user_groups_size(conf)) group conversations"  // stringlint:disable
                                    case .convoInfoVolatile: return "\(convo_info_volatile_size(conf)) volatile conversations"  // stringlint:disable
                                    case .invalid: return "Invalid"  // stringlint:disable
                                }
                            }()
                            
                            throw LibSessionError(
                                conf,
                                fallbackError: .unableToGeneratePushData,
                                logMessage: "[LibSession] Failed to generate push data for \(variant) config data, size: \(configCountInfo), error"
                            )
                        }
                    
                        let pushData: Data = Data(
                            bytes: cPushData.pointee.config,
                            count: cPushData.pointee.config_len
                        )
                        let obsoleteHashes: [String] = [String](
                            pointer: cPushData.pointee.obsolete,
                            count: cPushData.pointee.obsolete_len,
                            defaultValue: []
                        )
                        let seqNo: Int64 = cPushData.pointee.seqno
                        cPushData.deallocate()
                        
                        result.append(
                            data: PendingChanges.PushData(
                                data: pushData,
                                seqNo: seqNo,
                                variant: variant
                            ),
                            hashes: obsoleteHashes
                        )
                    }
            }
    }
    
    static func markingAsPushed(
        seqNo: Int64,
        serverHash: String,
        sentTimestamp: Int64,
        variant: ConfigDump.Variant,
        publicKey: String
    ) -> ConfigDump? {
        return LibSession
            .config(for: variant, publicKey: publicKey)
            .mutate { conf in
                guard
                    conf != nil,
                    var cHash: [CChar] = serverHash.cString(using: .utf8)
                else { return nil }
                
                // Mark the config as pushed
                config_confirm_pushed(conf, seqNo, &cHash)
                
                // Update the result to indicate whether the config needs to be dumped
                guard config_needs_dump(conf) else { return nil }
                
                return try? LibSession.createDump(
                    conf: conf,
                    for: variant,
                    publicKey: publicKey,
                    timestampMs: sentTimestamp
                )
            }
    }
    
    static func configHashes(for publicKey: String) -> [String] {
        return Storage.shared
            .read { db -> Set<ConfigDump.Variant> in
                guard Identity.userExists(db) else { return [] }
                
                return try ConfigDump
                    .select(.variant)
                    .filter(ConfigDump.Columns.publicKey == publicKey)
                    .asRequest(of: ConfigDump.Variant.self)
                    .fetchSet(db)
            }
            .defaulting(to: [])
            .map { variant -> [String] in
                /// Extract all existing hashes for any dumps associated with the given `publicKey`
                guard
                    let conf = LibSession
                        .config(for: variant, publicKey: publicKey)
                        .wrappedValue,
                    let hashList: UnsafeMutablePointer<config_string_list> = config_current_hashes(conf)
                else { return [] }
                
                let result: [String] = [String](
                    pointer: hashList.pointee.value,
                    count: hashList.pointee.len,
                    defaultValue: []
                )
                hashList.deallocate()
                
                return result
            }
            .reduce([], +)
    }
    
    // MARK: - Receiving
    
    static func handleConfigMessages(
        _ db: Database,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo],
        publicKey: String
    ) throws {
        guard !messages.isEmpty else { return }
        guard !publicKey.isEmpty else { throw MessageReceiverError.noThread }
        
        let groupedMessages: [ConfigDump.Variant: [ConfigMessageReceiveJob.Details.MessageInfo]] = messages
            .grouped(by: { ConfigDump.Variant(namespace: $0.namespace) })
        
        try groupedMessages
            .sorted { lhs, rhs in lhs.key.namespace.processingOrder < rhs.key.namespace.processingOrder }
            .forEach { key, value in
                try LibSession
                    .config(for: key, publicKey: publicKey)
                    .mutate { conf in
                        // Merge the messages
                        var mergeHashes: [UnsafePointer<CChar>?] = (try? (value
                            .compactMap { message in message.serverHash.cString(using: .utf8) }
                            .unsafeCopyCStringArray()))
                            .defaulting(to: [])
                        var mergeData: [UnsafePointer<UInt8>?] = (try? (value
                            .map { message -> [UInt8] in Array(message.data) }
                            .unsafeCopyUInt8Array()))
                            .defaulting(to: [])
                        defer {
                            mergeHashes.forEach { $0?.deallocate() }
                            mergeData.forEach { $0?.deallocate() }
                        }
                        
                        guard
                            conf != nil,
                            mergeHashes.count == value.count,
                            mergeData.count == value.count,
                            mergeHashes.allSatisfy({ $0 != nil }),
                            mergeData.allSatisfy({ $0 != nil })
                        else { return SNLog("[LibSession] Failed to correctly allocate merge data") }

                        var mergeSize: [size_t] = value.map { size_t($0.data.count) }
                        let mergedHashesPtr: UnsafeMutablePointer<config_string_list>? = config_merge(
                            conf,
                            &mergeHashes,
                            &mergeData,
                            &mergeSize,
                            value.count
                        )
                        
                        // If we got an error then throw it
                        try LibSessionError.throwIfNeeded(conf)
                        
                        // Get the list of hashes from the config (to determine which were successful)
                        let mergedHashes: [String] = mergedHashesPtr
                            .map { ptr in
                                [String](
                                    pointer: ptr.pointee.value,
                                    count: ptr.pointee.len,
                                    defaultValue: []
                                )
                            }
                            .defaulting(to: [])
                        let maybeLatestConfigSentTimestampMs: Int64? = value
                            .filter { mergedHashes.contains($0.serverHash) }
                            .compactMap { $0.serverTimestampMs }
                            .sorted()
                            .last
                        mergedHashesPtr?.deallocate()
                        
                        // If no messages were merged then no need to do anything
                        guard let latestConfigSentTimestampMs: Int64 = maybeLatestConfigSentTimestampMs else {
                            return
                        }
                        
                        // Apply the updated states to the database
                        do {
                            switch key {
                                case .userProfile:
                                    try LibSession.handleUserProfileUpdate(
                                        db,
                                        in: conf,
                                        mergeNeedsDump: config_needs_dump(conf),
                                        latestConfigSentTimestampMs: latestConfigSentTimestampMs
                                    )
                                    
                                case .contacts:
                                    try LibSession.handleContactsUpdate(
                                        db,
                                        in: conf,
                                        mergeNeedsDump: config_needs_dump(conf),
                                        latestConfigSentTimestampMs: latestConfigSentTimestampMs
                                    )
                                    
                                case .convoInfoVolatile:
                                    try LibSession.handleConvoInfoVolatileUpdate(
                                        db,
                                        in: conf,
                                        mergeNeedsDump: config_needs_dump(conf)
                                    )
                                    
                                case .userGroups:
                                    try LibSession.handleGroupsUpdate(
                                        db,
                                        in: conf,
                                        mergeNeedsDump: config_needs_dump(conf),
                                        latestConfigSentTimestampMs: latestConfigSentTimestampMs
                                    )
                                    
                                case .invalid: SNLog("[libSession] Failed to process merge of invalid config namespace")
                            }
                        }
                        catch {
                            SNLog("[LibSession] Failed to process merge of \(key) config data")
                            throw error
                        }
                        
                        // Need to check if the config needs to be dumped (this might have changed
                        // after handling the merge changes)
                        guard config_needs_dump(conf) else {
                            try ConfigDump
                                .filter(
                                    ConfigDump.Columns.variant == key &&
                                    ConfigDump.Columns.publicKey == publicKey
                                )
                                .updateAll(
                                    db,
                                    ConfigDump.Columns.timestampMs.set(to: latestConfigSentTimestampMs)
                                )
                            
                            return
                        }
                        
                        try LibSession.createDump(
                            conf: conf,
                            for: key,
                            publicKey: publicKey,
                            timestampMs: latestConfigSentTimestampMs
                        )?.save(db)
                    }
            }
        
        // Now that the local state has been updated, schedule a config sync (we want to always
        // do this in case there are obsolete hashes we want to clear)
        db.afterNextTransactionNestedOnce(dedupeId: LibSession.syncDedupeId(publicKey)) { db in
            ConfigurationSyncJob.enqueue(db, publicKey: publicKey)
        }
    }
}

// MARK: - Internal Convenience

fileprivate extension LibSession {
    struct ConfigKey: Hashable {
        let variant: ConfigDump.Variant
        let publicKey: String
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

// MARK: - SessionUtil Cache

public extension LibSession {
    class Cache: LibSessionCacheType {
        public struct Key: Hashable {
            let variant: ConfigDump.Variant
            let publicKey: String
        }
        
        private var configStore: [Key: Atomic<UnsafeMutablePointer<config_object>?>] = [:]
        
        public var isEmpty: Bool { configStore.isEmpty }
        
        /// Returns `true` if there is a config which needs to be pushed, but returns `false` if the configs are all up to date or haven't been
        /// loaded yet (eg. fresh install)
        public var needsSync: Bool {
            configStore.contains { _, atomicConf in
                guard atomicConf.wrappedValue != nil else { return false }
                
                return config_needs_push(atomicConf.wrappedValue)
            }
        }
        
        // MARK: - Functions
        
        public func setConfig(for variant: ConfigDump.Variant, publicKey: String, to config: UnsafeMutablePointer<config_object>?) {
            configStore[Key(variant: variant, publicKey: publicKey)] = config.map { Atomic($0) }
        }
        
        public func config(
            for variant: ConfigDump.Variant,
            publicKey: String
        ) -> Atomic<UnsafeMutablePointer<config_object>?> {
            return (
                configStore[Key(variant: variant, publicKey: publicKey)] ??
                Atomic(nil)
            )
        }
        
        public func removeAll() {
            configStore.removeAll()
        }
    }
}

public extension Cache {
    static let libSession: CacheInfo.Config<LibSessionCacheType, LibSessionImmutableCacheType> = CacheInfo.create(
        createInstance: { LibSession.Cache() },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - SessionUtilCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol LibSessionImmutableCacheType: ImmutableCacheType {
    var isEmpty: Bool { get }
    var needsSync: Bool { get }
    
    func config(for variant: ConfigDump.Variant, publicKey: String) -> Atomic<UnsafeMutablePointer<config_object>?>
}

public protocol LibSessionCacheType: LibSessionImmutableCacheType, MutableCacheType {
    var isEmpty: Bool { get }
    var needsSync: Bool { get }
    
    func setConfig(for variant: ConfigDump.Variant, publicKey: String, to config: UnsafeMutablePointer<config_object>?)
    func config(for variant: ConfigDump.Variant, publicKey: String) -> Atomic<UnsafeMutablePointer<config_object>?>
    func removeAll()
}
