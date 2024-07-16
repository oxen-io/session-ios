// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionSnodeKit
import SessionUtilitiesKit

public extension LibSession {
    typealias UserConfigInitialiser = (
        UnsafeMutablePointer<UnsafeMutablePointer<config_object>?>?,    // conf
        UnsafePointer<UInt8>?,                                          // ed25519_secretkey
        UnsafePointer<UInt8>?,                                          // dump
        Int,                                                            // dumplen
        UnsafeMutablePointer<CChar>?                                    // error
    ) -> Int32
    typealias GroupConfigInitialiser = (
        UnsafeMutablePointer<UnsafeMutablePointer<config_object>?>?,    // conf
        UnsafePointer<UInt8>?,                                          // ed25519_pubkey
        UnsafePointer<UInt8>?,                                          // ed25519_secretkey
        UnsafePointer<UInt8>?,                                          // dump
        Int,                                                            // dumplen
        UnsafeMutablePointer<CChar>?                                    // error
    ) -> Int32
    typealias ConfigSizeInfo = (UnsafePointer<config_object>?) -> Int
    
    // MARK: - Config
    
    enum Config {
        case invalid
        case object(UnsafeMutablePointer<config_object>)
        case groupKeys(
            UnsafeMutablePointer<config_group_keys>,
            info: UnsafeMutablePointer<config_object>,
            members: UnsafeMutablePointer<config_object>
        )
        
        // MARK: - Variables
        
        var needsPush: Bool {
            switch self {
                case .invalid: return false
                case .object(let conf): return config_needs_push(conf)
                
                case .groupKeys(let conf, _, _):
                    var pushResult: UnsafePointer<UInt8>? = nil
                    var pushResultLen: Int = 0
                    
                    return groups_keys_pending_config(conf, &pushResult, &pushResultLen)
            }
        }
        
        var lastError: LibSessionError? {
            let maybeErrorString: String? = {
                switch self {
                    case .invalid: return "Invalid"
                    case .object(let conf):
                        guard conf.pointee.last_error != nil else { return nil }
                        
                        return String(cString: conf.pointee.last_error)
                        
                    case .groupKeys(let conf, _, _):
                        guard conf.pointee.last_error != nil else { return nil }
                        
                        return String(cString: conf.pointee.last_error)
                }
            }()
            
            guard let errorString: String = maybeErrorString, !errorString.isEmpty else { return nil }
            
            return LibSessionError.libSessionError(errorString)
        }
        
        // MARK: - Functions
        
        func needsDump(using dependencies: Dependencies) -> Bool {
            return dependencies.mockableValue(
                key: "needsDump",
                {
                    switch self {
                        case .invalid: return false
                        case .object(let conf): return config_needs_dump(conf)
                        case .groupKeys(let conf, _, _): return groups_keys_needs_dump(conf)
                    }
                }()
            )
        }
        
        func push(variant: ConfigDump.Variant) -> PendingChanges.PushData? {
            switch self {
                case .invalid: return nil
                case .object(let conf):
                    let cPushData: UnsafeMutablePointer<config_push_data> = config_push(conf)
                    let pushData: Data = Data(
                        bytes: cPushData.pointee.config,
                        count: cPushData.pointee.config_len
                    )
                    let seqNo: Int64 = cPushData.pointee.seqno
                    cPushData.deallocate()
                    
                    return PendingChanges.PushData(
                        data: pushData,
                        seqNo: seqNo,
                        variant: variant
                    )
                    
                case .groupKeys(let conf, _, _):
                    var pushResult: UnsafePointer<UInt8>!
                    var pushResultLen: Int = 0
                    
                    guard groups_keys_pending_config(conf, &pushResult, &pushResultLen) else { return nil }
                    
                    return PendingChanges.PushData(
                        data: Data(bytes: pushResult, count: pushResultLen),
                        seqNo: 0,
                        variant: variant
                    )
            }
        }
        
        func confirmPushed(
            seqNo: Int64,
            hash: String
        ) {
            guard let cHash: [CChar] = hash.cString(using: .ascii) else { return }
            
            switch self {
                case .invalid: return
                case .object(let conf): return config_confirm_pushed(conf, seqNo, cHash)
                case .groupKeys: return // No need to do anything here
            }
        }
        
        func dump() throws -> Data? {
            var dumpResult: UnsafeMutablePointer<UInt8>? = nil
            var dumpResultLen: Int = 0
            
            switch self {
                case .invalid: throw LibSessionError.invalidConfigObject
                case .object(let conf): config_dump(conf, &dumpResult, &dumpResultLen)
                case .groupKeys(let conf, _, _): groups_keys_dump(conf, &dumpResult, &dumpResultLen)
            }
            
            // If we got an error then throw it
            try LibSessionError.throwIfNeeded(self)
            
            guard let dumpResult: UnsafeMutablePointer<UInt8> = dumpResult else { return nil }
            
            let dumpData: Data = Data(bytes: dumpResult, count: dumpResultLen)
            dumpResult.deallocate()
            
            return dumpData
        }
        
        func currentHashes() -> [String] {
            switch self {
                case .invalid: return []
                case .object(let conf):
                    guard let hashList: UnsafeMutablePointer<config_string_list> = config_current_hashes(conf) else {
                        return []
                    }
                    
                    let result: [String] = [String](
                        pointer: hashList.pointee.value,
                        count: hashList.pointee.len,
                        defaultValue: []
                    )
                    hashList.deallocate()
                    
                    return result
                    
                case .groupKeys(let conf, _, _):
                    guard let hashList: UnsafeMutablePointer<config_string_list> = groups_keys_current_hashes(conf) else {
                        return []
                    }
                    
                    let result: [String] = [String](
                        pointer: hashList.pointee.value,
                        count: hashList.pointee.len,
                        defaultValue: []
                    )
                    hashList.deallocate()
                    
                    return result
            }
        }
        
        func obsoleteHashes() -> [String] {
            switch self {
                case .invalid, .groupKeys: return []
                case .object(let conf):
                    guard let hashList: UnsafeMutablePointer<config_string_list> = config_old_hashes(conf) else {
                        return []
                    }
                    
                    let result: [String] = [String](
                        pointer: hashList.pointee.value,
                        count: hashList.pointee.len,
                        defaultValue: []
                    )
                    hashList.deallocate()
                    
                    return result
            }
        }
        
        func merge(_ messages: [ConfigMessageReceiveJob.Details.MessageInfo]) throws -> Int64? {
            switch self {
                case .invalid: throw LibSessionError.invalidConfigObject
                case .object(let conf):
                    var mergeHashes: [UnsafePointer<CChar>?] = (try? (messages
                        .compactMap { message in message.serverHash.cString(using: .utf8) }
                        .unsafeCopyCStringArray()))
                        .defaulting(to: [])
                    var mergeData: [UnsafePointer<UInt8>?] = (try? (messages
                        .map { message -> [UInt8] in Array(message.data) }
                        .unsafeCopyUInt8Array()))
                        .defaulting(to: [])
                    defer {
                        mergeHashes.forEach { $0?.deallocate() }
                        mergeData.forEach { $0?.deallocate() }
                    }
                    
                    guard
                        mergeHashes.count == messages.count,
                        mergeData.count == messages.count,
                        mergeHashes.allSatisfy({ $0 != nil }),
                        mergeData.allSatisfy({ $0 != nil })
                    else {
                        Log.error("[LibSession] Failed to correctly allocate merge data")
                        return nil
                    }
                    
                    var mergeSize: [size_t] = messages.map { size_t($0.data.count) }
                    let mergedHashesPtr: UnsafeMutablePointer<config_string_list>? = config_merge(
                        conf,
                        &mergeHashes,
                        &mergeData,
                        &mergeSize,
                        messages.count
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
                    mergedHashesPtr?.deallocate()
                    
                    if mergedHashes.count != messages.count {
                        Log.warn("[LibSession] Unable to merge \(messages[0].namespace) messages (\(mergedHashes.count)/\(messages.count))")
                    }
                    
                    return messages
                        .filter { mergedHashes.contains($0.serverHash) }
                        .map { $0.serverTimestampMs }
                        .sorted()
                        .last
                    
                case .groupKeys(let conf, let infoConf, let membersConf):
                    let successfulMergeTimestamps: [Int64] = try messages
                        .map { message -> (Bool, Int64) in
                            var data: [UInt8] = Array(message.data)
                            var cServerHash: [CChar] = try message.serverHash.cString(using: .utf8) ?? {
                                throw LibSessionError.invalidCConversion
                            }()
                            
                            let result: Bool = groups_keys_load_message(
                                conf,
                                &cServerHash,
                                &data,
                                data.count,
                                message.serverTimestampMs,
                                infoConf,
                                membersConf
                            )
                            
                            // If we got an error then throw it
                            try LibSessionError.throwIfNeeded(conf)
                            
                            return (result, message.serverTimestampMs)
                        }
                        .filter { success, _ in success }
                        .map { _, serverTimestampMs in serverTimestampMs }
                        .sorted()
                    
                    if successfulMergeTimestamps.count != messages.count {
                        Log.warn("[LibSession] Unable to merge \(SnodeAPI.Namespace.configGroupKeys) messages (\(successfulMergeTimestamps.count)/\(messages.count))")
                    }
                    
                    return successfulMergeTimestamps.last
            }
        }
        
        func count(for variant: ConfigDump.Variant) -> String {
            let funcMap: [ConfigDump.Variant: (info: String, size: ConfigSizeInfo)] = [
                .userProfile: ("profile", { _ in 1 }),
                .contacts: ("contacts", contacts_size),
                .userGroups: ("group conversations", user_groups_size),
                .convoInfoVolatile: ("volatile conversations", convo_info_volatile_size),
                .groupInfo: ("group info", { _ in 1 }),
                .groupMembers: ("group members", groups_members_size)
            ]
            
            switch self {
                case .invalid: return "Invalid"
                case .groupKeys(let conf, _, _): return "\(groups_keys_size(conf)) group keys"
                case .object(let conf):
                    return funcMap[variant]
                        .map { "\($0.size(conf)) \($0.info)" }
                        .defaulting(to: "Invalid")
            }
        }
    }
}

// MARK: - PendingChanges

internal extension LibSession {
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
            
            if !hashes.isEmpty {
                obsoleteHashes.insert(contentsOf: Set(hashes))
            }
        }
    }
}

// MARK: - Optional Convenience

public extension Optional where Wrapped == LibSession.Config {
    // MARK: - Variables
    
    var needsPush: Bool {
        switch self {
            case .some(let config): return config.needsPush
            case .none: return false
        }
    }
    
    var lastError: LibSessionError? {
        switch self {
            case .some(let config): return config.lastError
            case .none: return LibSessionError.invalidConfigObject
        }
    }
    
    // MARK: - Functions
    
    func needsDump(using dependencies: Dependencies) -> Bool {
        switch self {
            case .some(let config): return config.needsDump(using: dependencies)
            case .none: return false
        }
    }
    
    func confirmPushed(seqNo: Int64, hash: String) {
        switch self {
            case .some(let config): return config.confirmPushed(seqNo: seqNo, hash: hash)
            case .none: return
        }
    }
    
    func dump() throws -> Data? {
        switch self {
            case .some(let config): return try config.dump()
            case .none: return nil
        }
    }
    
    func currentHashes() -> [String] {
        switch self {
            case .some(let config): return config.currentHashes()
            case .none: return []
        }
    }
}

// MARK: - Atomic Convenience

public extension Atomic where Value == Optional<LibSession.Config> {
    var needsPush: Bool { return wrappedValue.needsPush }
    
    func needsDump(using dependencies: Dependencies) -> Bool { return wrappedValue.needsDump(using: dependencies) }
}

// MARK: - LibSessionError Convenience

public extension LibSessionError {
    init(
        _ config: LibSession.Config?,
        fallbackError: LibSessionError,
        logMessage: String? = nil
    ) {
        switch config {
            case .none, .invalid:
                self = fallbackError
                
                if let logMessage: String = logMessage {
                    Log.error("\(logMessage): \(self)")
                }
                
            case .object(let conf): self = LibSessionError(conf, fallbackError: fallbackError, logMessage: logMessage)
            case .groupKeys(let conf, _, _): self = LibSessionError(conf, fallbackError: fallbackError, logMessage: logMessage)
        }
    }
    
    static func throwIfNeeded(_ config: LibSession.Config?) throws {
        switch config {
            case .none: return
            case .invalid: throw LibSessionError.invalidConfigObject
            case .object(let conf): try LibSessionError.throwIfNeeded(conf)
            case .groupKeys(let conf, _, _): try LibSessionError.throwIfNeeded(conf)
        }
    }
}

// MARK: - Formatting

public extension String.StringInterpolation {
    mutating func appendInterpolation(_ error: LibSessionError?) {
        appendLiteral(error.map { "\($0)" } ?? "Unknown Error") // stringlint:disable
    }
}
